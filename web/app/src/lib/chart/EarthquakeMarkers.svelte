<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import { CircleLayer, FeatureState, GeoJSONSource } from 'svelte-maplibre-gl';
	import { alertStore } from '$lib/alerts/store.svelte';
	import {
		RHYTHMS,
		RHYTHM_KEYS,
		PULSE_OPACITY,
		type BlinkBucket,
		type Rhythm
	} from '$lib/alerts/blinkBucket';
	import type { BlinkPhase } from '$lib/alerts/blinkEngine.svelte';
	import { earthquakeStore } from '$lib/earthquakes/store.svelte';
	import type { Earthquake } from '$lib/earthquakes/types';
	import { DAY, NIGHT } from './tokens';

	interface Props {
		phase: BlinkPhase;
		onselect: (id: number) => void;
		onready: () => void;
	}

	let { phase, onselect, onready }: Props = $props();

	// FeatureState calls setFeatureState as soon as it mounts, which MapLibre
	// rejects until the source has been added to a loaded style.
	let source = $state<maplibregl.GeoJSONSource | undefined>(undefined);

	const AMBER: maplibregl.ExpressionSpecification = [
		'match',
		['global-state', 'theme'],
		'night',
		NIGHT.amber,
		DAY.amber
	];
	const UNCLUSTERED: maplibregl.FilterSpecification = ['!', ['has', 'point_count']];
	const CLUSTERED: maplibregl.FilterSpecification = ['has', 'point_count'];
	const MAGNITUDE: maplibregl.ExpressionSpecification = ['coalesce', ['get', 'magnitude'], -2];
	const RADIUS: maplibregl.ExpressionSpecification = [
		'interpolate',
		['linear'],
		MAGNITUDE,
		-2,
		3,
		2.5,
		4,
		4.5,
		6,
		6,
		10,
		8,
		16
	];
	const RING_RADIUS: maplibregl.ExpressionSpecification = ['+', RADIUS, 4];
	const CLUSTER_RADIUS: maplibregl.ExpressionSpecification = [
		'interpolate',
		['linear'],
		['coalesce', ['get', 'maxMagnitude'], -2],
		2.5,
		9,
		6,
		14,
		8,
		19
	];
	const NO_TRANSITION = { duration: 0 };

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
	const PULSE_WIDTH: Record<Rhythm, maplibregl.ExpressionSpecification> = {
		q: pulseWidthFor(RHYTHMS.q.buckets),
		fl2: pulseWidthFor(RHYTHMS.fl2.buckets),
		fl4: pulseWidthFor(RHYTHMS.fl4.buckets),
		group: pulseWidthFor(RHYTHMS.group.buckets)
	};

	// Decision-10 mapping: arrival always flashes Q for 5 s (store-owned
	// timing); once persistent, magnitude picks the rhythm. M<2.5 never
	// blinks; M>=6 gets the two-flash "group" rhythm.
	function bucketFor(earthquake: Earthquake): BlinkBucket {
		const state = earthquakeStore.blink.get(earthquake.id);
		if (!state) return 'none';
		const frozen = alertStore.stopAll || alertStore.reducedMotion;
		if (state.mode === 'arrival') return frozen ? 'still' : 'q';
		if (frozen) return 'still';
		const magnitude = earthquake.magnitude ?? Number.NEGATIVE_INFINITY;
		if (magnitude < 2.5) return 'none';
		if (magnitude < 4.5) return 'fl4';
		if (magnitude < 6) return 'fl2';
		return 'group';
	}

	interface MarkerEntry {
		id: number;
		blinkBucket: BlinkBucket;
	}

	// Blink state only drives feature-state (below); it must never reach the
	// GeoJSON source data, or every arrival timeout/freeze toggle would
	// rebuild the whole source (see Fix 1 in the review this addresses).
	const entries = $derived.by((): MarkerEntry[] =>
		earthquakeStore.sorted.map((earthquake) => ({
			id: earthquake.id,
			blinkBucket: bucketFor(earthquake)
		}))
	);

	// Computed independently from `entries` (not derived from it) so blink
	// changes never touch this GeoJSON and never trigger setData.
	const points = $derived({
		type: 'FeatureCollection' as const,
		features: earthquakeStore.sorted.map((earthquake) => ({
			type: 'Feature' as const,
			properties: {
				id: earthquake.id,
				magnitude: earthquake.magnitude
			},
			geometry: {
				type: 'Point' as const,
				coordinates: [earthquake.longitude, earthquake.latitude]
			}
		}))
	});

	$effect(() => {
		if (source) onready();
	});

	function handleClick(event: maplibregl.MapLayerMouseEvent): void {
		const id = event.features?.[0]?.properties?.id as number | undefined;
		if (id !== undefined) onselect(id);
	}

	function handleClusterClick(event: maplibregl.MapLayerMouseEvent): void {
		const feature = event.features?.[0];
		const clusterId = feature?.properties?.cluster_id as number | undefined;
		if (!feature || clusterId === undefined || !source || feature.geometry.type !== 'Point') return;
		const [longitude, latitude] = feature.geometry.coordinates;
		source.getClusterExpansionZoom(clusterId).then((zoom) => {
			event.target.easeTo({ center: [longitude, latitude], zoom });
		});
	}
</script>

<GeoJSONSource
	id="earthquakes"
	data={points}
	promoteId="id"
	cluster
	clusterRadius={24}
	clusterMaxZoom={8}
	clusterProperties={{ maxMagnitude: ['max', MAGNITUDE] }}
	bind:source
>
	<CircleLayer
		id="earthquakes-point"
		filter={UNCLUSTERED}
		paint={{
			'circle-radius': RADIUS,
			'circle-color': AMBER,
			'circle-opacity': 0.82,
			'circle-stroke-color': AMBER,
			'circle-stroke-width': 1.25
		}}
		onclick={handleClick}
	/>
	<CircleLayer
		id="earthquakes-pulse-still"
		filter={UNCLUSTERED}
		paint={{
			'circle-radius': RING_RADIUS,
			'circle-color': 'transparent',
			'circle-stroke-color': AMBER,
			'circle-stroke-width': STILL_PULSE_WIDTH,
			'circle-stroke-opacity': PULSE_OPACITY.still
		}}
	/>
	{#each RHYTHM_KEYS as rhythm (rhythm)}
		<CircleLayer
			id="earthquakes-pulse-{rhythm}"
			filter={UNCLUSTERED}
			paint={{
				'circle-radius': RING_RADIUS,
				'circle-color': 'transparent',
				'circle-stroke-color': AMBER,
				'circle-stroke-width': PULSE_WIDTH[rhythm],
				'circle-stroke-opacity': phase[rhythm] ? PULSE_OPACITY.lit : PULSE_OPACITY.dim,
				'circle-stroke-opacity-transition': NO_TRANSITION
			}}
		/>
	{/each}
	<!-- Clusters are intentionally static: one aggregate point has no single
	     event's arrival or magnitude rhythm to represent faithfully. -->
	<CircleLayer
		id="earthquakes-cluster-outer"
		filter={CLUSTERED}
		paint={{
			'circle-radius': ['+', CLUSTER_RADIUS, 3],
			'circle-color': 'transparent',
			'circle-stroke-color': AMBER,
			'circle-stroke-opacity': 0.55,
			'circle-stroke-width': 1
		}}
		onclick={handleClusterClick}
	/>
	<CircleLayer
		id="earthquakes-cluster"
		filter={CLUSTERED}
		paint={{
			'circle-radius': CLUSTER_RADIUS,
			'circle-color': AMBER,
			'circle-opacity': 0.82,
			'circle-stroke-color': AMBER,
			'circle-stroke-width': 1
		}}
		onclick={handleClusterClick}
	/>
	{#if source}
		{#each entries as entry (entry.id)}
			<FeatureState id={entry.id} state={{ blinkBucket: entry.blinkBucket }} />
		{/each}
	{/if}
</GeoJSONSource>
