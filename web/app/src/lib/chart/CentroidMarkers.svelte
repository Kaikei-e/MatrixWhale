<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import { GeoJSONSource, CircleLayer, FeatureState, Popup } from 'svelte-maplibre-gl';
	import { alertStore } from '$lib/alerts/store.svelte';
	import { RHYTHMS, RHYTHM_KEYS, PULSE_OPACITY, type Rhythm } from '$lib/alerts/blinkBucket';
	import type { BlinkPhase } from '$lib/alerts/blinkEngine.svelte';
	import { DAY, NIGHT } from './tokens';

	interface Props {
		centroids: Record<string, [number, number]>;
		phase: BlinkPhase;
		onselect: (id: string) => void;
	}

	let { centroids, phase, onselect }: Props = $props();

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
	const MARKER_COLOR: maplibregl.ExpressionSpecification = [
		'case',
		['all', ['boolean', ['global-state', 'nws'], false], ['==', ['get', 'source'], 'noaa']],
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
	const UNCLUSTERED_FILTER: maplibregl.FilterSpecification = ['!', ['has', 'point_count']];
	const CLUSTERED_FILTER: maplibregl.FilterSpecification = ['has', 'point_count'];
	const CLUSTER_STROKE_WIDTH: maplibregl.ExpressionSpecification = [
		'match',
		['get', 'severityRank'],
		4,
		3,
		3,
		2,
		1.5
	];
	const CLUSTER_RADIUS: maplibregl.ExpressionSpecification = [
		'step',
		['get', 'point_count'],
		9,
		5,
		12,
		10,
		15
	];
	const CLUSTER_OUTER_RADIUS: maplibregl.ExpressionSpecification = ['+', CLUSTER_RADIUS, 4];
	// Membership in a rhythm is feature-state that selects the pulse ring's
	// stroke width; brightness is that layer's constant stroke opacity (see
	// PulseLayer for why nothing per-frame may reach a feature-state expression).
	const BUCKET: maplibregl.ExpressionSpecification = [
		'coalesce',
		['feature-state', 'blinkBucket'],
		'none'
	];

	function pulseWidthFor(buckets: readonly string[]): maplibregl.ExpressionSpecification {
		return ['match', BUCKET, [...buckets], 2, 0];
	}

	const STILL_PULSE_WIDTH = pulseWidthFor(['still']);
	// 'group' is earthquake-only; alerts never carry that bucket, so this
	// layer stays inert here, but the record must cover every key in RHYTHMS
	// for the shared BlinkEngine/RHYTHM_KEYS iteration to work.
	const PULSE_WIDTH: Record<Rhythm, maplibregl.ExpressionSpecification> = {
		q: pulseWidthFor(RHYTHMS.q.buckets),
		fl2: pulseWidthFor(RHYTHMS.fl2.buckets),
		fl4: pulseWidthFor(RHYTHMS.fl4.buckets),
		group: pulseWidthFor(RHYTHMS.group.buckets)
	};
	const NO_TRANSITION = { duration: 0 };
	import { createMarkerPointCache, createMarkerStateCache } from './markerCache';

	const getMarkerCollection = createMarkerPointCache();
	const getMarkerStateEntries = createMarkerStateCache();

	const points = $derived.by(() => getMarkerCollection(alertStore.filtered, centroids));
	const stateEntries = $derived.by(() =>
		getMarkerStateEntries(
			alertStore.filtered,
			centroids,
			alertStore.blink,
			alertStore.stopAll,
			alertStore.reducedMotion
		)
	);

	let hoveredCluster = $state<{ lon: number; lat: number; count: number } | undefined>(undefined);

	function handleClick(event: maplibregl.MapLayerMouseEvent): void {
		const alertId = event.features?.[0]?.properties?.id as string | undefined;
		if (alertId) onselect(alertId);
	}

	function handleClusterClick(event: maplibregl.MapLayerMouseEvent): void {
		const feature = event.features?.[0];
		const clusterId = feature?.properties?.cluster_id as number | undefined;
		if (!feature || clusterId === undefined || !source || feature.geometry.type !== 'Point') return;
		const [lon, lat] = feature.geometry.coordinates;
		source.getClusterExpansionZoom(clusterId).then((zoom) => {
			event.target.easeTo({ center: [lon, lat], zoom });
		});
	}

	function handleMouseEnter(event: maplibregl.MapLayerMouseEvent): void {
		event.target.getCanvas().style.cursor = 'pointer';
		const feature = event.features?.[0];
		const pointCount = feature?.properties?.point_count as number | undefined;
		if (pointCount === undefined || feature?.geometry.type !== 'Point') return;
		const [lon, lat] = feature.geometry.coordinates;
		hoveredCluster = { lon, lat, count: pointCount };
	}

	function handleMouseLeave(event: maplibregl.MapLayerMouseEvent): void {
		event.target.getCanvas().style.cursor = '';
		hoveredCluster = undefined;
	}
</script>

<GeoJSONSource
	id="alert-centroids"
	data={points}
	promoteId="id"
	cluster
	clusterRadius={22}
	clusterMaxZoom={8}
	clusterProperties={{ severityRank: ['max', ['get', 'severityRank']] }}
	bind:source
>
	<CircleLayer
		id="alert-centroids-ring"
		filter={UNCLUSTERED_FILTER}
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
		id="alert-centroids-pulse-still"
		filter={UNCLUSTERED_FILTER}
		paint={{
			'circle-radius': 6,
			'circle-color': 'transparent',
			'circle-stroke-color': MARKER_COLOR,
			'circle-stroke-width': STILL_PULSE_WIDTH,
			'circle-stroke-opacity': PULSE_OPACITY.still
		}}
	/>
	{#each RHYTHM_KEYS as rhythm (rhythm)}
		<CircleLayer
			id="alert-centroids-pulse-{rhythm}"
			filter={UNCLUSTERED_FILTER}
			paint={{
				'circle-radius': 6,
				'circle-color': 'transparent',
				'circle-stroke-color': MARKER_COLOR,
				'circle-stroke-width': PULSE_WIDTH[rhythm],
				'circle-stroke-opacity': phase[rhythm] ? PULSE_OPACITY.lit : PULSE_OPACITY.dim,
				'circle-stroke-opacity-transition': NO_TRANSITION
			}}
		/>
	{/each}
	<CircleLayer
		id="alert-centroids-cluster-outer"
		filter={CLUSTERED_FILTER}
		paint={{
			'circle-radius': CLUSTER_OUTER_RADIUS,
			'circle-color': 'transparent',
			'circle-stroke-color': LIGHT,
			'circle-stroke-width': 1,
			'circle-stroke-opacity': 0.5
		}}
	/>
	<CircleLayer
		id="alert-centroids-cluster"
		filter={CLUSTERED_FILTER}
		paint={{
			'circle-radius': CLUSTER_RADIUS,
			'circle-color': 'transparent',
			'circle-stroke-color': LIGHT,
			'circle-stroke-width': CLUSTER_STROKE_WIDTH
		}}
		onclick={handleClusterClick}
		onmouseenter={handleMouseEnter}
		onmouseleave={handleMouseLeave}
	/>
	{#if source}
		{#each stateEntries as entry (entry.id)}
			<FeatureState id={entry.id} state={entry.state} />
		{/each}
	{/if}
</GeoJSONSource>
{#if hoveredCluster}
	<Popup
		class="cluster-tooltip"
		lnglat={[hoveredCluster.lon, hoveredCluster.lat]}
		closeButton={false}
		closeOnClick={false}
		open
	>
		{hoveredCluster.count} alerts
	</Popup>
{/if}

<style>
	/* The popup has no interactive content; leaving pointer-events at the
	   library default would let it eat the hover that opened it. */
	:global(.cluster-tooltip .maplibregl-popup-content) {
		pointer-events: none;
	}
</style>
