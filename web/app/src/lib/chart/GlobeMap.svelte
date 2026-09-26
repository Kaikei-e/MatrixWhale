<script lang="ts">
	import type * as maplibregl from 'maplibre-gl';
	import ChartFrame from '$lib/chart/ChartFrame.svelte';
	import ZonesLayer from '$lib/chart/ZonesLayer.svelte';
	import AlertPolygonsLayer from '$lib/chart/AlertPolygonsLayer.svelte';
	import PulseLayer from '$lib/chart/PulseLayer.svelte';
	import CentroidMarkers from '$lib/chart/CentroidMarkers.svelte';
	import EarthquakeMarkers from '$lib/chart/EarthquakeMarkers.svelte';
	import HazardMarkers from '$lib/chart/HazardMarkers.svelte';
	import ForecastTrackLayer from '$lib/chart/ForecastTrackLayer.svelte';
	import ObservedExtremesLayer from '$lib/chart/ObservedExtremesLayer.svelte';
	import { LAND_50M } from '$lib/chart/dataFiles';
	import { REGION_PRESETS } from '$lib/chart/presets';
	import { alertStore } from '$lib/alerts/store.svelte';
	import { themeState } from '$lib/theme.svelte';
	import type { BlinkPhase } from '$lib/alerts/blinkEngine.svelte';

	interface Props {
		map?: maplibregl.Map;
		earthquakeSourceMounted?: boolean;
		centroids: Record<string, [number, number]>;
		phase: BlinkPhase;
		selectedHazardId: string | null;
		showObservedExtremes?: boolean;
		onselectAlert: (id: string) => void;
		onselectEarthquake: (id: number) => void;
		onselectHazard: (id: string) => void;
	}

	let {
		map = $bindable(undefined),
		earthquakeSourceMounted = $bindable(false),
		centroids,
		phase,
		selectedHazardId,
		showObservedExtremes = true,
		onselectAlert,
		onselectEarthquake,
		onselectHazard
	}: Props = $props();
</script>

<ChartFrame
	bind:map
	landUrl={LAND_50M}
	initialBounds={REGION_PRESETS.CONUS}
	theme={themeState.current}
	nws={alertStore.useNwsColors}
	class="h-full w-full"
>
	<ZonesLayer />
	<AlertPolygonsLayer onselect={onselectAlert} />
	<PulseLayer {phase} />
	<!-- Earthquakes draw first so alert centroid rings, the primary product,
	     stay on top of earthquake circles. -->
	<EarthquakeMarkers
		{phase}
		onselect={onselectEarthquake}
		onready={() => (earthquakeSourceMounted = true)}
	/>
	<HazardMarkers selectedId={selectedHazardId} onselect={onselectHazard} />
	<ObservedExtremesLayer
		visible={showObservedExtremes}
		selectedId={selectedHazardId}
		onselect={onselectHazard}
	/>
	<ForecastTrackLayer {selectedHazardId} />
	<CentroidMarkers {centroids} {phase} onselect={onselectAlert} />
</ChartFrame>
