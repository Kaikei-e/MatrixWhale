<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import {
		CircleLayer,
		FeatureState,
		FillLayer,
		GeoJSONSource,
		LineLayer
	} from 'svelte-maplibre-gl';
	import { hazardStore } from '$lib/hazards/store.svelte';
	import { ALERT_LEVEL_COLORS } from '$lib/hazards/types';

	interface Props {
		selectedId: string | null;
		onselect: (id: string) => void;
	}

	let { selectedId, onselect }: Props = $props();

	// FeatureState calls setFeatureState as soon as it mounts, which MapLibre
	// rejects until the source has been added to a loaded style.
	let source = $state<maplibregl.GeoJSONSource | undefined>(undefined);

	const LEVEL_COLOR: maplibregl.ExpressionSpecification = [
		'match',
		['get', 'alert_level'],
		'green',
		ALERT_LEVEL_COLORS.green,
		'orange',
		ALERT_LEVEL_COLORS.orange,
		'red',
		ALERT_LEVEL_COLORS.red,
		ALERT_LEVEL_COLORS.green
	];
	const LEVEL_RADIUS: maplibregl.ExpressionSpecification = [
		'match',
		['get', 'alert_level'],
		'green',
		5,
		'orange',
		7,
		'red',
		9,
		5
	];
	const SELECTED: maplibregl.ExpressionSpecification = [
		'boolean',
		['feature-state', 'selected'],
		false
	];
	const CIRCLE_STROKE_WIDTH: maplibregl.ExpressionSpecification = ['case', SELECTED, 3, 1.5];
	const LINE_WIDTH: maplibregl.ExpressionSpecification = ['case', SELECTED, 3, 1.5];
	const POINT_FILTER: maplibregl.FilterSpecification = ['==', ['geometry-type'], 'Point'];
	const POLYGON_FILTER: maplibregl.FilterSpecification = [
		'in',
		['geometry-type'],
		['literal', ['Polygon', 'MultiPolygon']]
	];

	interface HazardEntry {
		id: string;
		alertLevel: string;
	}

	// Built from the store's already-filtered list; feature-state (selection)
	// is set separately below so selecting a hazard never touches this data.
	const entries = $derived.by((): HazardEntry[] =>
		hazardStore.sorted.map((hazard) => ({ id: hazard.id, alertLevel: hazard.alert_level }))
	);

	const featureCollection = $derived({
		type: 'FeatureCollection' as const,
		features: hazardStore.sorted.flatMap((hazard) => {
			const properties = { id: hazard.id, alert_level: hazard.alert_level };
			const centroid = {
				type: 'Feature' as const,
				properties,
				geometry: { type: 'Point' as const, coordinates: [hazard.longitude, hazard.latitude] }
			};
			if (!hazard.primary_geometry) return [centroid];
			return [
				centroid,
				{ type: 'Feature' as const, properties, geometry: hazard.primary_geometry }
			];
		})
	});

	function handleClick(event: maplibregl.MapLayerMouseEvent): void {
		const id = event.features?.[0]?.properties?.id as string | undefined;
		if (id !== undefined) onselect(id);
	}
</script>

<GeoJSONSource id="hazards" data={featureCollection} promoteId="id" bind:source>
	<FillLayer
		id="hazards-fill"
		filter={POLYGON_FILTER}
		paint={{ 'fill-color': LEVEL_COLOR, 'fill-opacity': 0.18 }}
		onclick={handleClick}
	/>
	<LineLayer
		id="hazards-line"
		filter={POLYGON_FILTER}
		paint={{ 'line-color': LEVEL_COLOR, 'line-width': LINE_WIDTH }}
	/>
	<CircleLayer
		id="hazards-point"
		filter={POINT_FILTER}
		paint={{
			'circle-radius': LEVEL_RADIUS,
			'circle-color': LEVEL_COLOR,
			'circle-opacity': 0.85,
			'circle-stroke-color': '#ffffff',
			'circle-stroke-width': CIRCLE_STROKE_WIDTH
		}}
		onclick={handleClick}
	/>
	{#if source}
		{#each entries as entry (entry.id)}
			<FeatureState id={entry.id} state={{ selected: entry.id === selectedId }} />
		{/each}
	{/if}
</GeoJSONSource>
