<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import { CircleLayer, GeoJSONSource, SymbolLayer } from 'svelte-maplibre-gl';
	import { hazardStore } from '$lib/hazards/store.svelte';

	interface Props {
		visible?: boolean;
		selectedId?: string | null;
		onselect?: (id: string) => void;
	}

	let { visible = true, selectedId = null, onselect }: Props = $props();

	let source = $state<maplibregl.GeoJSONSource | undefined>(undefined);

	const SUBTYPE_COLOR: maplibregl.ExpressionSpecification = [
		'match',
		['get', 'subtype'],
		'wind',
		'#00bcd4',
		'gust',
		'#ff9800',
		'rain_1h',
		'#2196f3',
		'rain_24h',
		'#3f51b5',
		'low_pressure',
		'#9c27b0',
		'#607d8b'
	];

	// Unconfirmed observations have a constant faded opacity (never animated per frame)
	const CIRCLE_OPACITY: maplibregl.ExpressionSpecification = [
		'case',
		['boolean', ['get', 'confirmed'], false],
		0.9,
		0.35
	];

	const STROKE_OPACITY: maplibregl.ExpressionSpecification = [
		'case',
		['boolean', ['get', 'confirmed'], false],
		1.0,
		0.4
	];

	const TEXT_OPACITY: maplibregl.ExpressionSpecification = [
		'case',
		['boolean', ['get', 'confirmed'], false],
		1.0,
		0.45
	];

	const SUBTYPE_SYMBOL: maplibregl.ExpressionSpecification = [
		'match',
		['get', 'subtype'],
		'wind',
		'W',
		'gust',
		'G',
		'rain_1h',
		'1h',
		'rain_24h',
		'24h',
		'low_pressure',
		'P',
		'!'
	];

	const featureCollection = $derived.by(() => {
		if (!visible) {
			return { type: 'FeatureCollection' as const, features: [] };
		}

		const extremes = hazardStore.sorted.filter(
			(hazard) => hazard.hazard_type === 'observed_extreme'
		);

		return {
			type: 'FeatureCollection' as const,
			features: extremes.map((hazard) => ({
				type: 'Feature' as const,
				properties: {
					id: hazard.id,
					subtype: hazard.subtype ?? 'wind',
					confirmed: hazard.confirmed === true,
					selected: hazard.id === selectedId
				},
				geometry: {
					type: 'Point' as const,
					coordinates: [hazard.longitude, hazard.latitude]
				}
			}))
		};
	});

	function handleClick(event: maplibregl.MapLayerMouseEvent): void {
		const id = event.features?.[0]?.properties?.id as string | undefined;
		if (id !== undefined && onselect) onselect(id);
	}
</script>

<GeoJSONSource id="observed-extremes" data={featureCollection} promoteId="id" bind:source>
	<CircleLayer
		id="observed-extremes-point"
		paint={{
			'circle-radius': 9,
			'circle-color': SUBTYPE_COLOR,
			'circle-opacity': CIRCLE_OPACITY,
			'circle-stroke-color': '#ffffff',
			'circle-stroke-width': ['case', ['boolean', ['get', 'selected'], false], 3, 1.5],
			'circle-stroke-opacity': STROKE_OPACITY
		}}
		onclick={handleClick}
	/>
	<SymbolLayer
		id="observed-extremes-symbol"
		layout={{
			'text-field': SUBTYPE_SYMBOL,
			'text-size': 9,
			'text-allow-overlap': true,
			'text-ignore-placement': true
		}}
		paint={{
			'text-color': '#ffffff',
			'text-opacity': TEXT_OPACITY
		}}
		onclick={handleClick}
	/>
</GeoJSONSource>
