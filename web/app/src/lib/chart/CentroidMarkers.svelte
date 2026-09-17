<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import { GeoJSONSource, CircleLayer, FeatureState } from 'svelte-maplibre-gl';
	import { alertStore } from '$lib/alerts/store.svelte';
	import { bucketFor, type BlinkBucket } from '$lib/alerts/blinkBucket';
	import { NWS_EVENT_COLORS } from '$lib/alerts/nwsEventStyle';
	import { alertCentroid } from './alertPoints';
	import type { Severity } from '$lib/alerts/types';
	import { DAY, NIGHT } from './tokens';

	interface Props {
		centroids: Record<string, [number, number]>;
		onselect: (id: string) => void;
	}

	let { centroids, onselect }: Props = $props();

	// FeatureState calls setFeatureState as soon as it mounts, which MapLibre
	// rejects until the source has been added to a loaded style.
	let source = $state<maplibregl.GeoJSONSource | undefined>(undefined);

	const DEFAULT_NWS_COLOR = '#B8338F';

	const LIGHT: maplibregl.ExpressionSpecification = [
		'match',
		['global-state', 'theme'],
		'night',
		NIGHT.light,
		DAY.light
	];
	const MARKER_COLOR: maplibregl.ExpressionSpecification = [
		'case',
		['boolean', ['global-state', 'nws'], false],
		['coalesce', ['feature-state', 'nwsColor'], LIGHT],
		LIGHT
	];
	const STROKE_WIDTH: maplibregl.ExpressionSpecification = [
		'match',
		['feature-state', 'severity'],
		'Extreme',
		3,
		'Severe',
		2,
		1.5
	];
	const BUCKET: maplibregl.ExpressionSpecification = [
		'coalesce',
		['feature-state', 'blinkBucket'],
		'none'
	];
	const PERIOD: maplibregl.ExpressionSpecification = [
		'match',
		BUCKET,
		'fl2',
		2000,
		'fl4',
		4000,
		1000
	];
	const DUTY_MS: maplibregl.ExpressionSpecification = [
		'match',
		BUCKET,
		'fl2',
		500,
		'fl4',
		1000,
		300
	];
	const PULSE_OPACITY: maplibregl.ExpressionSpecification = [
		'case',
		['==', BUCKET, 'still'],
		0.6,
		['==', BUCKET, 'none'],
		0,
		['<', ['%', ['global-state', 't'], PERIOD], DUTY_MS],
		1,
		0.12
	];

	interface MarkerEntry {
		alertId: string;
		severity: Severity;
		blinkBucket: BlinkBucket;
		nwsColor: string;
		lon: number;
		lat: number;
	}

	// One ring per alert at its centroid; the zones themselves are painted by
	// ZonesLayer, so a per-zone ring would only duplicate that coverage.
	const entries = $derived.by((): MarkerEntry[] => {
		const result: MarkerEntry[] = [];
		for (const alert of alertStore.sorted) {
			const point = alertCentroid(alert, centroids);
			if (!point) continue;
			result.push({
				alertId: alert.id,
				severity: alert.severity,
				blinkBucket: bucketFor(
					alertStore.blink.get(alert.id),
					alert.severity,
					alertStore.stopAll,
					alertStore.reducedMotion
				),
				nwsColor: NWS_EVENT_COLORS[alert.event] ?? DEFAULT_NWS_COLOR,
				lon: point[0],
				lat: point[1]
			});
		}
		return result;
	});

	const points = $derived({
		type: 'FeatureCollection' as const,
		features: entries.map((entry) => ({
			type: 'Feature' as const,
			properties: { id: entry.alertId, severity: entry.severity },
			geometry: { type: 'Point' as const, coordinates: [entry.lon, entry.lat] }
		}))
	});

	function handleClick(event: maplibregl.MapLayerMouseEvent): void {
		const alertId = event.features?.[0]?.properties?.id as string | undefined;
		if (alertId) onselect(alertId);
	}

	function handleMouseEnter(event: maplibregl.MapLayerMouseEvent): void {
		event.target.getCanvas().style.cursor = 'pointer';
	}

	function handleMouseLeave(event: maplibregl.MapLayerMouseEvent): void {
		event.target.getCanvas().style.cursor = '';
	}
</script>

<GeoJSONSource id="alert-centroids" data={points} promoteId="id" bind:source>
	<CircleLayer
		id="alert-centroids-ring"
		paint={{
			'circle-radius': 6,
			'circle-color': 'transparent',
			'circle-stroke-color': MARKER_COLOR,
			'circle-stroke-width': STROKE_WIDTH
		}}
		onclick={handleClick}
		onmouseenter={handleMouseEnter}
		onmouseleave={handleMouseLeave}
	/>
	<CircleLayer
		id="alert-centroids-pulse"
		paint={{
			'circle-radius': 6,
			'circle-color': 'transparent',
			'circle-stroke-color': MARKER_COLOR,
			'circle-stroke-width': STROKE_WIDTH,
			'circle-stroke-opacity': PULSE_OPACITY,
			'circle-stroke-opacity-transition': { duration: 0 }
		}}
	/>
	{#if source}
		{#each entries as entry (entry.alertId)}
			<FeatureState
				id={entry.alertId}
				state={{
					severity: entry.severity,
					blinkBucket: entry.blinkBucket,
					nwsColor: entry.nwsColor
				}}
			/>
		{/each}
	{/if}
</GeoJSONSource>
