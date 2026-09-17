<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import { LineLayer } from 'svelte-maplibre-gl';
	import { RHYTHMS, RHYTHM_KEYS, PULSE_OPACITY, type Rhythm } from '$lib/alerts/blinkBucket';
	import type { BlinkPhase } from '$lib/alerts/blinkEngine.svelte';
	import { DAY, NIGHT } from './tokens';

	interface Props {
		phase: BlinkPhase;
	}

	let { phase }: Props = $props();

	const LIGHT: maplibregl.ExpressionSpecification = [
		'match',
		['global-state', 'theme'],
		'night',
		NIGHT.light,
		DAY.light
	];

	// Which zone/polygon blinks, and in which rhythm, is feature-state (set once
	// per change) that selects the line width per rhythm layer. The per-frame
	// brightness is that layer's constant line-opacity. MapLibre re-lays out
	// every tile of a source whenever a feature-state-driven paint expression
	// changes (also via global-state), so nothing that ticks may reach one.
	const BUCKET: maplibregl.ExpressionSpecification = [
		'coalesce',
		['feature-state', 'blinkBucket'],
		'none'
	];

	function widthFor(buckets: readonly string[]): maplibregl.ExpressionSpecification {
		return ['match', BUCKET, [...buckets], 3, 0];
	}

	const STILL_WIDTH = widthFor(['still']);
	const WIDTH: Record<Rhythm, maplibregl.ExpressionSpecification> = {
		q: widthFor(RHYTHMS.q.buckets),
		fl2: widthFor(RHYTHMS.fl2.buckets),
		fl4: widthFor(RHYTHMS.fl4.buckets)
	};
	const NO_TRANSITION = { duration: 0 };

	const PULSE_SOURCES = [
		'zones-forecast',
		'zones-county',
		'zones-marine-coastal',
		'zones-marine-offshore',
		'alert-polygons'
	];
</script>

{#each PULSE_SOURCES as sourceId (sourceId)}
	<LineLayer
		id="pulse-{sourceId}-still"
		source={sourceId}
		paint={{ 'line-color': LIGHT, 'line-width': STILL_WIDTH, 'line-opacity': PULSE_OPACITY.still }}
	/>
	{#each RHYTHM_KEYS as rhythm (rhythm)}
		<LineLayer
			id="pulse-{sourceId}-{rhythm}"
			source={sourceId}
			paint={{
				'line-color': LIGHT,
				'line-width': WIDTH[rhythm],
				'line-opacity': phase[rhythm] ? PULSE_OPACITY.lit : PULSE_OPACITY.dim,
				'line-opacity-transition': NO_TRANSITION
			}}
		/>
	{/each}
{/each}
