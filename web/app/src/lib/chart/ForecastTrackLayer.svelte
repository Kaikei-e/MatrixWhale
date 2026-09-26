<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import { CircleLayer, GeoJSONSource, LineLayer, SymbolLayer } from 'svelte-maplibre-gl';
	import { hazardStore } from '$lib/hazards/store.svelte';
	import { formatTrackLeadLabel, is24HourStep } from '$lib/hazards/wis2';

	interface Props {
		selectedHazardId: string | null;
	}

	let { selectedHazardId }: Props = $props();

	let source = $state<maplibregl.GeoJSONSource | undefined>(undefined);

	const selectedDetail = $derived(
		selectedHazardId ? (hazardStore.details.get(selectedHazardId) ?? null) : null
	);

	const featureCollection = $derived.by(() => {
		const tracks = selectedDetail?.forecast_tracks ?? [];
		if (tracks.length === 0) {
			return { type: 'FeatureCollection' as const, features: [] };
		}

		const features: GeoJSON.Feature[] = [];

		for (const track of tracks) {
			if (!track.points || track.points.length === 0) continue;

			// LineString for the full track
			if (track.points.length >= 2) {
				features.push({
					type: 'Feature',
					properties: {
						id: `track-${track.centre_id}-${track.storm_id}-${track.analysis_time}`,
						kind: 'track_line',
						centre_id: track.centre_id,
						storm_id: track.storm_id
					},
					geometry: {
						type: 'LineString',
						coordinates: track.points.map((p) => [p.lon, p.lat])
					}
				});
			}

			// Points and 24h step labels
			for (const point of track.points) {
				const is24h = is24HourStep(point.lead_hours);
				features.push({
					type: 'Feature',
					properties: {
						id: `point-${track.centre_id}-${point.lead_hours}`,
						kind: 'track_point',
						lead_hours: point.lead_hours,
						is_24h_step: is24h,
						label: formatTrackLeadLabel(point.lead_hours)
					},
					geometry: {
						type: 'Point',
						coordinates: [point.lon, point.lat]
					}
				});
			}
		}

		return {
			type: 'FeatureCollection' as const,
			features
		};
	});

	const LINE_FILTER: maplibregl.FilterSpecification = ['==', ['geometry-type'], 'LineString'];
	const POINT_FILTER: maplibregl.FilterSpecification = ['==', ['geometry-type'], 'Point'];
	const LABEL_FILTER: maplibregl.FilterSpecification = [
		'all',
		['==', ['geometry-type'], 'Point'],
		['==', ['get', 'is_24h_step'], true]
	];
</script>

<GeoJSONSource id="forecast-tracks" data={featureCollection} promoteId="id" bind:source>
	<LineLayer
		id="forecast-tracks-line"
		filter={LINE_FILTER}
		paint={{
			'line-color': '#38bdf8',
			'line-width': 2,
			'line-dasharray': [3, 2],
			'line-opacity': 0.9
		}}
	/>
	<CircleLayer
		id="forecast-tracks-point"
		filter={POINT_FILTER}
		paint={{
			'circle-radius': 3.5,
			'circle-color': '#38bdf8',
			'circle-stroke-color': '#0f172a',
			'circle-stroke-width': 1.5,
			'circle-opacity': 0.95
		}}
	/>
	<SymbolLayer
		id="forecast-tracks-label"
		filter={LABEL_FILTER}
		layout={{
			'text-field': ['get', 'label'],
			'text-size': 11,
			'text-offset': [0.7, -0.7],
			'text-anchor': 'bottom-left',
			'text-allow-overlap': true
		}}
		paint={{
			'text-color': '#ffffff',
			'text-halo-color': '#0f172a',
			'text-halo-width': 1.5
		}}
	/>
</GeoJSONSource>
