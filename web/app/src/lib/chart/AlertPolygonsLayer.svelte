<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import { GeoJSONSource, FillLayer, LineLayer, FeatureState } from 'svelte-maplibre-gl';
	import { alertStore } from '$lib/alerts/store.svelte';
	import { DAY, NIGHT } from './tokens';

	interface Props {
		onselect?: (id: string) => void;
	}

	let { onselect }: Props = $props();

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
	const AMBER: maplibregl.ExpressionSpecification = [
		'match',
		['global-state', 'theme'],
		'night',
		NIGHT.amber,
		DAY.amber
	];
	const MODERATE: maplibregl.ExpressionSpecification = [
		'match',
		['global-state', 'theme'],
		'night',
		NIGHT.moderate,
		DAY.moderate
	];
	const MINOR: maplibregl.ExpressionSpecification = [
		'match',
		['global-state', 'theme'],
		'night',
		NIGHT.minor,
		DAY.minor
	];
	const INK2: maplibregl.ExpressionSpecification = [
		'match',
		['global-state', 'theme'],
		'night',
		NIGHT['ink-2'],
		DAY['ink-2']
	];

	const SEVERITY_COLOR: maplibregl.ExpressionSpecification = [
		'match',
		['feature-state', 'severity'],
		'Extreme',
		LIGHT,
		'Severe',
		AMBER,
		'Moderate',
		MODERATE,
		'Minor',
		MINOR,
		INK2
	];

	const ALERT_COLOR: maplibregl.ExpressionSpecification = [
		'case',
		['all', ['boolean', ['global-state', 'nws'], false], ['==', ['get', 'source'], 'noaa']],
		['coalesce', ['feature-state', 'nwsColor'], SEVERITY_COLOR],
		SEVERITY_COLOR
	];

	const FILL_OPACITY: maplibregl.ExpressionSpecification = [
		'match',
		['feature-state', 'severity'],
		'Extreme',
		0.55,
		'Severe',
		0.3,
		'Moderate',
		0.2,
		'Minor',
		0.1,
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
		'Minor',
		1,
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

	import { createPolygonFeatureCache, createPolygonStateCache } from './polygonCache';

	const getFeatureCollection = createPolygonFeatureCache();
	const getStateEntries = createPolygonStateCache();

	const featureCollection = $derived.by(() => getFeatureCollection(alertStore.filtered));
	const stateEntries = $derived.by(() =>
		getStateEntries(
			alertStore.filtered,
			alertStore.blink,
			alertStore.stopAll,
			alertStore.reducedMotion
		)
	);

	function handleClick(event: maplibregl.MapLayerMouseEvent): void {
		const id = event.features?.[0]?.properties?.id as string | undefined;
		if (id !== undefined && onselect) onselect(id);
	}
</script>

<!-- Alert polygons are the most specific shapes (event-drawn warning geometry), so this
     mounts after all zone sources (see globe/+page.svelte) and draws on top of them. -->
<GeoJSONSource id="alert-polygons" data={featureCollection} promoteId="id" bind:source>
	<FillLayer
		id="alert-polygons-fill"
		paint={{ 'fill-color': ALERT_COLOR, 'fill-opacity': FILL_OPACITY }}
		layout={{ 'fill-sort-key': SEVERITY_RANK }}
		onclick={handleClick}
	/>
	<LineLayer
		id="alert-polygons-line"
		paint={{ 'line-color': ALERT_COLOR, 'line-width': LINE_WIDTH }}
		layout={{ 'line-sort-key': SEVERITY_RANK }}
	/>
	{#if source}
		{#each stateEntries as entry (entry.id)}
			<FeatureState id={entry.id} state={entry.state} />
		{/each}
	{/if}
</GeoJSONSource>
