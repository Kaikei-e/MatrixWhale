<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import { GeoJSONSource, FillLayer, LineLayer, FeatureState } from 'svelte-maplibre-gl';
	import { alertStore } from '$lib/alerts/store.svelte';
	import { DAY, NIGHT } from './tokens';
	import {
		FORECAST_ZONES,
		COUNTY_ZONES,
		MARINE_COASTAL_ZONES,
		MARINE_OFFSHORE_ZONES
	} from './dataFiles';

	// NWS UGC conventions: forecast zones are `<state>Z<seq>`, counties are
	// `<state>C<seq>`. Marine zone prefixes are not state codes and often also
	// end in Z (e.g. AMZ131), so the marine test is independent rather than an
	// "else" branch — a UGC can legitimately match more than one pattern here,
	// and setting feature-state for a UGC that doesn't exist in a given source
	// is a harmless no-op.
	const FORECAST_UGC = /^[A-Z]{2}Z\d{3}$/;
	const COUNTY_UGC = /^[A-Z]{2}C\d{3}$/;
	const MARINE_UGC = /^[A-Z]{3}\d{3}$/;

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
		['boolean', ['global-state', 'nws'], false],
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
	const LINE_COLOR: maplibregl.ExpressionSpecification = ALERT_COLOR;
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
		'Unknown',
		1,
		0
	];

	import { createZoneStateCache, fetchGeoJson } from './zoneCache';

	const EMPTY_FC: GeoJSON.FeatureCollection = {
		type: 'FeatureCollection',
		features: []
	};

	const getZoneEntries = createZoneStateCache();

	const zoneEntries = $derived.by(() =>
		getZoneEntries(
			alertStore.filtered,
			alertStore.zoneSeverity,
			alertStore.blink,
			alertStore.stopAll,
			alertStore.reducedMotion
		)
	);

	const forecastZones = $derived(zoneEntries.filter((zone) => FORECAST_UGC.test(zone.ugc)));
	const countyZones = $derived(zoneEntries.filter((zone) => COUNTY_UGC.test(zone.ugc)));
	const marineZones = $derived(zoneEntries.filter((zone) => MARINE_UGC.test(zone.ugc)));

	// Draw order: less specific first, so overlapping smaller zones stay visible.
	// Keep sources statically defined so GeoJSONSource props remain reference-stable across
	// alert updates, preventing spurious setData calls and duplicate GeoJSON network fetches.
	const ZONE_SOURCES = [
		{ id: 'zones-forecast', data: FORECAST_ZONES },
		{ id: 'zones-county', data: COUNTY_ZONES },
		{ id: 'zones-marine-offshore', data: MARINE_OFFSHORE_ZONES },
		{ id: 'zones-marine-coastal', data: MARINE_COASTAL_ZONES }
	] as const;

	function getZonesForSource(sourceId: string) {
		switch (sourceId) {
			case 'zones-forecast':
				return forecastZones;
			case 'zones-county':
				return countyZones;
			case 'zones-marine-offshore':
			case 'zones-marine-coastal':
				return marineZones;
			default:
				return [];
		}
	}

	let zoneData = $state.raw<Record<string, GeoJSON.FeatureCollection>>({});

	$effect(() => {
		let active = true;
		for (const src of ZONE_SOURCES) {
			fetchGeoJson(src.data)
				.then((data) => {
					if (active) {
						zoneData = { ...zoneData, [src.id]: data };
					}
				})
				.catch(() => {});
		}
		return () => {
			active = false;
		};
	});

	// FeatureState calls setFeatureState as soon as it mounts, which MapLibre
	// rejects until the source has been added to a loaded style.
	let sourceInstances = $state<Record<string, maplibregl.GeoJSONSource | undefined>>({});

	// No fill-sort-key/line-sort-key here: the per-zone winner is already
	// resolved in zoneSeverity, and severity lives in feature-state, which
	// layout properties (sort keys included) cannot read.
</script>

{#each ZONE_SOURCES as src (src.id)}
	<GeoJSONSource
		id={src.id}
		data={zoneData[src.id] ?? EMPTY_FC}
		promoteId="ugc"
		bind:source={sourceInstances[src.id]}
	>
		<FillLayer
			id="{src.id}-fill"
			paint={{ 'fill-color': ALERT_COLOR, 'fill-opacity': FILL_OPACITY }}
		/>
		<LineLayer id="{src.id}-line" paint={{ 'line-color': LINE_COLOR, 'line-width': LINE_WIDTH }} />
		{#if sourceInstances[src.id]}
			{#each getZonesForSource(src.id) as zone (zone.ugc)}
				<FeatureState id={zone.ugc} state={zone.state} />
			{/each}
		{/if}
	</GeoJSONSource>
{/each}
