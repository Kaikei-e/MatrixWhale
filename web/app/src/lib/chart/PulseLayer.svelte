<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import { LineLayer } from 'svelte-maplibre-gl';
	import { DAY, NIGHT } from './tokens';

	const LIGHT: maplibregl.ExpressionSpecification = [
		'match',
		['global-state', 'theme'],
		'night',
		NIGHT.light,
		DAY.light
	];

	// Which zone/polygon is currently blinking is tracked per-feature via
	// feature-state (set once per change); "how bright right now" is a single
	// global-state tick (`t`, driven by one rAF loop) so we never call
	// setFeatureState in a per-frame loop. line-opacity-transition is pinned to
	// 0 because global-state-driven paint transitions can otherwise get stuck
	// mid-interpolation (see idea1.md notes on this MapLibre bug).
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

	const PULSE_PAINT = {
		'line-color': LIGHT,
		'line-width': 3,
		'line-opacity': PULSE_OPACITY,
		'line-opacity-transition': { duration: 0 }
	};

	const PULSE_SOURCES = [
		'zones-forecast',
		'zones-county',
		'zones-marine-coastal',
		'zones-marine-offshore',
		'alert-polygons'
	];
</script>

{#each PULSE_SOURCES as sourceId (sourceId)}
	<LineLayer id="pulse-{sourceId}" source={sourceId} paint={PULSE_PAINT} />
{/each}
