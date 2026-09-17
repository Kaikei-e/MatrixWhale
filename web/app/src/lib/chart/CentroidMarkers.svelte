<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import { GeoJSONSource, CircleLayer, FeatureState, Popup } from 'svelte-maplibre-gl';
	import { alertStore } from '$lib/alerts/store.svelte';
	import {
		bucketFor,
		RHYTHMS,
		RHYTHM_KEYS,
		PULSE_OPACITY,
		type BlinkBucket,
		type Rhythm
	} from '$lib/alerts/blinkBucket';
	import type { BlinkPhase } from '$lib/alerts/blinkEngine.svelte';
	import { NWS_EVENT_COLORS, DEFAULT_NWS_COLOR } from '$lib/alerts/nwsEventStyle';
	import { alertCentroid } from './alertPoints';
	import type { Severity } from '$lib/alerts/types';
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
	// Severity as a number so clusterProperties can aggregate it with 'max'; style
	// expressions have no access to feature-state (severity is only set there), so
	// clusters key off this plain point property instead.
	const SEVERITY_RANK: Record<Severity, number> = {
		Extreme: 4,
		Severe: 3,
		Moderate: 2,
		Minor: 1,
		Unknown: 0
	};
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
			properties: {
				id: entry.alertId,
				severity: entry.severity,
				severityRank: SEVERITY_RANK[entry.severity]
			},
			geometry: { type: 'Point' as const, coordinates: [entry.lon, entry.lat] }
		}))
	});

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
