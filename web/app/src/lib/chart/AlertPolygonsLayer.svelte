<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import { GeoJSONSource, FillLayer, LineLayer, FeatureState } from 'svelte-maplibre-gl';
	import { alertStore } from '$lib/alerts/store.svelte';
	import { bucketFor, type BlinkBucket } from '$lib/alerts/blinkBucket';
	import { NWS_EVENT_COLORS, DEFAULT_NWS_COLOR } from '$lib/alerts/nwsEventStyle';
	import type { Alert, Severity } from '$lib/alerts/types';
	import { DAY, NIGHT } from './tokens';

	// FeatureState calls setFeatureState as soon as it mounts, which MapLibre
	// rejects until the source has been added to a loaded style.
	let source = $state<maplibregl.GeoJSONSource | undefined>(undefined);

	const LIGHT: maplibregl.ExpressionSpecification = [
		'match',
		['global-state', 'theme'],
		'night',
		NIGHT.light,
		DAY.light
	];
	const ALERT_COLOR: maplibregl.ExpressionSpecification = [
		'case',
		['boolean', ['global-state', 'nws'], false],
		['coalesce', ['feature-state', 'nwsColor'], LIGHT],
		LIGHT
	];
	const FILL_OPACITY: maplibregl.ExpressionSpecification = [
		'match',
		['feature-state', 'severity'],
		'Extreme',
		0.55,
		'Severe',
		0.3,
		0
	];
	const LINE_WIDTH: maplibregl.ExpressionSpecification = [
		'match',
		['feature-state', 'severity'],
		'Extreme',
		2.5,
		'Severe',
		1.5,
		'Moderate',
		1.5,
		1
	];

	// Sort keys are layout properties (get-only, no feature-state), so overlapping
	// alert polygons stack with the most severe one drawn on top.
	const SEVERITY_RANK: maplibregl.ExpressionSpecification = [
		'match',
		['get', 'severity'],
		'Extreme',
		4,
		'Severe',
		3,
		'Moderate',
		2,
		'Minor',
		1,
		0
	];

	interface PolygonEntry {
		id: string;
		severity: Severity;
		blinkBucket: BlinkBucket;
		nwsColor: string;
		geometry: NonNullable<Alert['geometry']>;
	}

	const entries = $derived.by((): PolygonEntry[] => {
		const result: PolygonEntry[] = [];
		for (const alert of alertStore.sorted) {
			if (!alert.geometry) continue;
			const bucket = bucketFor(
				alertStore.blink.get(alert.id),
				alert.severity,
				alertStore.stopAll,
				alertStore.reducedMotion
			);
			result.push({
				id: alert.id,
				severity: alert.severity,
				blinkBucket: bucket,
				nwsColor: NWS_EVENT_COLORS[alert.event] ?? DEFAULT_NWS_COLOR,
				geometry: alert.geometry
			});
		}
		return result;
	});

	const featureCollection = $derived({
		type: 'FeatureCollection' as const,
		features: entries.map((entry) => ({
			type: 'Feature' as const,
			properties: { id: entry.id, severity: entry.severity },
			geometry: entry.geometry
		}))
	});
</script>

<!-- Alert polygons are the most specific shapes (event-drawn warning geometry), so this
     mounts after all zone sources (see globe/+page.svelte) and draws on top of them. -->
<GeoJSONSource id="alert-polygons" data={featureCollection} promoteId="id" bind:source>
	<FillLayer
		id="alert-polygons-fill"
		paint={{ 'fill-color': ALERT_COLOR, 'fill-opacity': FILL_OPACITY }}
		layout={{ 'fill-sort-key': SEVERITY_RANK }}
	/>
	<LineLayer
		id="alert-polygons-line"
		paint={{ 'line-color': ALERT_COLOR, 'line-width': LINE_WIDTH }}
		layout={{ 'line-sort-key': SEVERITY_RANK }}
	/>
	{#if source}
		{#each entries as entry (entry.id)}
			<FeatureState
				id={entry.id}
				state={{
					severity: entry.severity,
					blinkBucket: entry.blinkBucket,
					nwsColor: entry.nwsColor
				}}
			/>
		{/each}
	{/if}
</GeoJSONSource>
