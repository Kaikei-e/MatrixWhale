<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import { SvelteMap } from 'svelte/reactivity';
	import { GeoJSONSource, FillLayer, LineLayer, FeatureState } from 'svelte-maplibre-gl';
	import { alertStore } from '$lib/alerts/store.svelte';
	import { bucketFor, bucketRank, type BlinkBucket } from '$lib/alerts/blinkBucket';
	import { NWS_EVENT_COLORS } from '$lib/alerts/nwsEventStyle';
	import type { Severity } from '$lib/alerts/types';
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

	const DEFAULT_NWS_COLOR = '#B8338F';

	const LIGHT: maplibregl.ExpressionSpecification = [
		'match',
		['global-state', 'theme'],
		'night',
		NIGHT.light,
		DAY.light
	];
	const INK2: maplibregl.ExpressionSpecification = [
		'match',
		['global-state', 'theme'],
		'night',
		NIGHT['ink-2'],
		DAY['ink-2']
	];
	const ALERT_COLOR: maplibregl.ExpressionSpecification = [
		'case',
		['boolean', ['global-state', 'nws'], false],
		['coalesce', ['feature-state', 'nwsColor'], LIGHT],
		LIGHT
	];

	// `line-dasharray` only supports zoom/feature expressions in the MapLibre
	// style spec, not feature-state — so Minor/Unknown zones render as a solid
	// ink-2 line on the map. The Legend still shows the dashed/dotted glyph.
	const FILL_OPACITY: maplibregl.ExpressionSpecification = [
		'match',
		['feature-state', 'severity'],
		'Extreme',
		0.55,
		'Severe',
		0.3,
		0
	];
	const LINE_COLOR: maplibregl.ExpressionSpecification = [
		'match',
		['feature-state', 'severity'],
		'Minor',
		INK2,
		'Unknown',
		INK2,
		ALERT_COLOR
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
		'Unknown',
		1,
		0
	];

	interface ZoneEntry {
		ugc: string;
		severity: Severity;
		blinkBucket: BlinkBucket;
		nwsColor: string;
	}

	const zoneEntries = $derived.by((): ZoneEntry[] => {
		const extras = new SvelteMap<string, { blinkBucket: BlinkBucket; nwsColor: string }>();
		for (const alert of alertStore.sorted) {
			const bucket = bucketFor(
				alertStore.blink.get(alert.id),
				alert.severity,
				alertStore.stopAll,
				alertStore.reducedMotion
			);
			const color = NWS_EVENT_COLORS[alert.event] ?? DEFAULT_NWS_COLOR;
			for (const ugc of alert.ugc) {
				const existing = extras.get(ugc);
				if (!existing) {
					extras.set(ugc, { blinkBucket: bucket, nwsColor: color });
				} else if (bucketRank(bucket) < bucketRank(existing.blinkBucket)) {
					extras.set(ugc, { blinkBucket: bucket, nwsColor: existing.nwsColor });
				}
			}
		}

		return [...alertStore.zoneSeverity.entries()].map(([ugc, severity]) => ({
			ugc,
			severity,
			blinkBucket: extras.get(ugc)?.blinkBucket ?? 'none',
			nwsColor: extras.get(ugc)?.nwsColor ?? DEFAULT_NWS_COLOR
		}));
	});

	const forecastZones = $derived(zoneEntries.filter((zone) => FORECAST_UGC.test(zone.ugc)));
	const countyZones = $derived(zoneEntries.filter((zone) => COUNTY_UGC.test(zone.ugc)));
	const marineZones = $derived(zoneEntries.filter((zone) => MARINE_UGC.test(zone.ugc)));

	const sources = $derived([
		{ id: 'zones-forecast', data: FORECAST_ZONES, zones: forecastZones },
		{ id: 'zones-county', data: COUNTY_ZONES, zones: countyZones },
		{ id: 'zones-marine-coastal', data: MARINE_COASTAL_ZONES, zones: marineZones },
		{ id: 'zones-marine-offshore', data: MARINE_OFFSHORE_ZONES, zones: marineZones }
	]);

	// FeatureState calls setFeatureState as soon as it mounts, which MapLibre
	// rejects until the source has been added to a loaded style.
	let sourceInstances = $state<Record<string, maplibregl.GeoJSONSource | undefined>>({});
</script>

{#each sources as src (src.id)}
	<GeoJSONSource id={src.id} data={src.data} promoteId="ugc" bind:source={sourceInstances[src.id]}>
		<FillLayer
			id="{src.id}-fill"
			paint={{ 'fill-color': ALERT_COLOR, 'fill-opacity': FILL_OPACITY }}
		/>
		<LineLayer id="{src.id}-line" paint={{ 'line-color': LINE_COLOR, 'line-width': LINE_WIDTH }} />
		{#if sourceInstances[src.id]}
			{#each src.zones as zone (zone.ugc)}
				<FeatureState
					id={zone.ugc}
					state={{
						severity: zone.severity,
						blinkBucket: zone.blinkBucket,
						nwsColor: zone.nwsColor
					}}
				/>
			{/each}
		{/if}
	</GeoJSONSource>
{/each}
