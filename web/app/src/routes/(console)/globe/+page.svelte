<script lang="ts">
	import { browser } from '$app/environment';
	import { page } from '$app/state';
	import type * as maplibregl from 'maplibre-gl';
	import ChartFrame from '$lib/chart/ChartFrame.svelte';
	import ZonesLayer from '$lib/chart/ZonesLayer.svelte';
	import AlertPolygonsLayer from '$lib/chart/AlertPolygonsLayer.svelte';
	import PulseLayer from '$lib/chart/PulseLayer.svelte';
	import CentroidMarkers from '$lib/chart/CentroidMarkers.svelte';
	import EarthquakeMarkers from '$lib/chart/EarthquakeMarkers.svelte';
	import HazardMarkers from '$lib/chart/HazardMarkers.svelte';
	import Legend from '$lib/chart/Legend.svelte';
	import PresetButtons from '$lib/components/PresetButtons.svelte';
	import FeedPanel from '$lib/components/FeedPanel.svelte';
	import DetailPanel from '$lib/components/DetailPanel.svelte';
	import BottomSheet from '$lib/components/BottomSheet.svelte';
	import EarthquakePanel from '$lib/components/EarthquakePanel.svelte';
	import SidePane from '$lib/components/pane/SidePane.svelte';
	import { LAND_50M, ZONE_CENTROIDS } from '$lib/chart/dataFiles';
	import { REGION_PRESETS, bboxOfAlerts, initialViewBbox, type Bbox } from '$lib/chart/presets';
	import { alertStore } from '$lib/alerts/store.svelte';
	import { themeState } from '$lib/theme.svelte';
	import { BlinkEngine } from '$lib/alerts/blinkEngine.svelte';
	import { earthquakeStore } from '$lib/earthquakes/store.svelte';
	import { hazardStore } from '$lib/hazards/store.svelte';

	let map = $state<maplibregl.Map | undefined>();
	let centroids = $state<Record<string, [number, number]>>({});
	let selectedId = $state<string | null>(null);
	let selectedEarthquakeId = $state<number | null>(null);
	let selectedHazardId = $state<string | null>(null);
	let earthquakeSourceMounted = $state(false);
	let earthquakeLayerReady = $state(false);
	let sheetExpanded = $state(false);
	let userInteracted = $state(false);
	let autoFitted = $state(false);
	let focusApplied = $state(false);
	let focusEarthquakeApplied = $state(false);

	const focusId = page.url.searchParams.get('focus');
	// Shared by alerts and earthquakes so rhythms of the same name (q/fl2/fl4)
	// flash in phase; earthquakes additionally use the group rhythm.
	const engine = new BlinkEngine();

	const selectedAlert = $derived(
		selectedId ? (alertStore.activeAlerts.get(selectedId) ?? null) : null
	);

	$effect(() => {
		if (alertStore.hasAnyBlinking || (earthquakeStore.hasAnyBlinking && !alertStore.stopAll)) {
			engine.start();
		} else {
			engine.stop();
		}
		return () => engine.stop();
	});

	$effect(() => {
		if (!map || !earthquakeSourceMounted) return;
		earthquakeLayerReady = Boolean(
			map.getSource('earthquakes') && map.getLayer('earthquakes-point')
		);
	});

	$effect(() => {
		if (!browser) return;
		void earthquakeStore.connect('/api/v1/earthquakes/recent', '/api/v1/earthquakes/stream', {
			hours: 24,
			minMagnitude: 2.5,
			eventType: 'earthquake'
		});
		return () => earthquakeStore.disconnect();
	});

	$effect(() => {
		if (!browser) return;
		void earthquakeStore.fetchSources('/api/v1/sources');
	});

	$effect(() => {
		if (!browser) return;
		void hazardStore.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		return () => hazardStore.disconnect();
	});

	$effect(() => {
		if (!browser) return;
		void hazardStore.fetchSources('/api/v1/sources');
	});

	$effect(() => {
		earthquakeStore.reducedMotion = alertStore.reducedMotion;
	});

	$effect(() => {
		fetch(ZONE_CENTROIDS)
			.then((response) => response.json())
			.then((data: Record<string, [number, number]>) => {
				centroids = data;
			})
			.catch(() => {});
	});

	$effect(() => {
		if (!map) return;
		const currentMap = map;
		const markInteracted = (event: maplibregl.MapLibreEvent): void => {
			if (event.originalEvent) userInteracted = true;
		};
		currentMap.on('dragstart', markInteracted);
		currentMap.on('zoomstart', markInteracted);
		return () => {
			currentMap.off('dragstart', markInteracted);
			currentMap.off('zoomstart', markInteracted);
		};
	});

	// Fit to the active alerts once, after both the snapshot and the centroid
	// lookup have arrived; later SSE updates must not move the map under the user.
	$effect(() => {
		if (!map || userInteracted || autoFitted) return;
		if (alertStore.activeAlerts.size === 0 || Object.keys(centroids).length === 0) return;
		autoFitted = true;
		fitToBbox(initialViewBbox(alertStore.sorted, centroids), 0);
	});

	$effect(() => {
		if (!focusId || focusApplied || !map) return;
		if (!alertStore.activeAlerts.has(focusId)) return;
		focusApplied = true;
		selectAlert(focusId);
	});

	$effect(() => {
		if (!focusId || focusEarthquakeApplied || !map) return;
		const id = Number(focusId);
		if (!Number.isFinite(id) || !earthquakeStore.earthquakes.has(id)) return;
		focusEarthquakeApplied = true;
		selectEarthquake(id);
	});

	// The desktop side panel overlays the map instead of resizing it, so
	// fitBounds needs extra right padding on wide viewports or fitted points
	// can end up hidden behind it. SidePane's width prop is driven by this
	// same constant so the two can never drift apart.
	const SIDE_PANEL_WIDTH = 380;
	const MD_BREAKPOINT = 768;

	function mapPadding(base: number): maplibregl.PaddingOptions {
		const right = window.innerWidth >= MD_BREAKPOINT ? base + SIDE_PANEL_WIDTH : base;
		return { top: base, bottom: base, left: base, right };
	}

	function fitToBbox(bbox: Bbox, duration: number): void {
		map?.fitBounds(
			[
				[bbox[0], bbox[1]],
				[bbox[2], bbox[3]]
			],
			// Region presets are always real extents; an alert-derived bbox can
			// degenerate to a single point (one alert, one centroid) and would
			// otherwise zoom to the map's max zoom.
			{ padding: mapPadding(24), duration, maxZoom: 10 }
		);
	}

	function fitToAlertId(id: string): void {
		const bbox = bboxOfAlerts([alertStore.activeAlerts.get(id)!], centroids);
		if (!bbox) return;
		map?.fitBounds(
			[
				[bbox[0], bbox[1]],
				[bbox[2], bbox[3]]
			],
			{ padding: mapPadding(48), maxZoom: 8, duration: alertStore.reducedMotion ? 0 : 600 }
		);
	}

	function selectAlert(id: string): void {
		if (!alertStore.activeAlerts.has(id)) return;
		selectedId = id;
		userInteracted = true;
		sheetExpanded = true;
		if (alertStore.blink.get(id)?.mode === 'persistent') alertStore.acknowledge(id);
		fitToAlertId(id);
	}

	function closeDetail(): void {
		selectedId = null;
	}

	function selectEarthquake(id: number): void {
		const earthquake = earthquakeStore.earthquakes.get(id);
		if (!earthquake) return;
		selectedEarthquakeId = id;
		userInteracted = true;
		sheetExpanded = true;
		map?.easeTo({
			center: [earthquake.longitude, earthquake.latitude],
			zoom: Math.max(map.getZoom(), 7),
			duration: alertStore.reducedMotion ? 0 : 600
		});
	}

	function closeEarthquakeDetail(): void {
		selectedEarthquakeId = null;
	}

	function selectHazard(id: string): void {
		const hazard = hazardStore.hazards.get(id);
		if (!hazard) return;
		selectedHazardId = id;
		userInteracted = true;
		sheetExpanded = true;
		map?.easeTo({
			center: [hazard.longitude, hazard.latitude],
			// Hazard footprints (droughts, cyclones) are often country-scale, so
			// this flies in less tightly than the earthquake point-source zoom.
			zoom: Math.max(map.getZoom(), 4),
			duration: alertStore.reducedMotion ? 0 : 600
		});
	}

	function closeHazardDetail(): void {
		selectedHazardId = null;
	}

	function handlePreset(bbox: Bbox): void {
		userInteracted = true;
		fitToBbox(bbox, alertStore.reducedMotion ? 0 : 600);
	}
</script>

<div class="relative h-full w-full overflow-hidden">
	<ChartFrame
		bind:map
		landUrl={LAND_50M}
		initialBounds={REGION_PRESETS.CONUS}
		theme={themeState.current}
		nws={alertStore.useNwsColors}
		class="h-full w-full"
	>
		<ZonesLayer />
		<AlertPolygonsLayer />
		<PulseLayer phase={engine.phase} />
		<!-- Earthquakes draw first so alert centroid rings, the primary product,
		     stay on top of earthquake circles. -->
		<EarthquakeMarkers
			phase={engine.phase}
			onselect={selectEarthquake}
			onready={() => (earthquakeSourceMounted = true)}
		/>
		<HazardMarkers selectedId={selectedHazardId} onselect={selectHazard} />
		<CentroidMarkers {centroids} phase={engine.phase} onselect={selectAlert} />
	</ChartFrame>
	<div
		data-testid="earthquake-map-layer"
		data-ready={earthquakeLayerReady ? 'true' : 'false'}
		class="sr-only"
		aria-hidden="true"
	></div>

	<div class="absolute top-3 left-3 flex flex-wrap items-center gap-2">
		<PresetButtons onselect={handlePreset} />
		<button
			type="button"
			aria-pressed={alertStore.useNwsColors}
			onclick={() => (alertStore.useNwsColors = !alertStore.useNwsColors)}
			class="border-ink-2/30 bg-paper/90 text-ink hover:bg-shoal border px-2 py-1 text-sm"
		>
			NWS colors
		</button>
	</div>

	<Legend class="absolute bottom-16 left-3 md:bottom-3" />

	<SidePane
		class="absolute top-0 right-0 bottom-0 hidden md:flex"
		width={SIDE_PANEL_WIDTH}
		{selectedEarthquakeId}
		{selectedHazardId}
		selectedAlertId={selectedId}
		onSelectEarthquake={selectEarthquake}
		onSelectHazard={selectHazard}
		onSelectAlert={selectAlert}
		onCloseEarthquake={closeEarthquakeDetail}
		onCloseHazard={closeHazardDetail}
		onCloseAlert={closeDetail}
		onAcknowledgeAlert={(id) => alertStore.acknowledge(id)}
	/>

	<div class="md:hidden">
		<BottomSheet bind:expanded={sheetExpanded}>
			<EarthquakePanel
				selectedId={selectedEarthquakeId}
				onselect={selectEarthquake}
				onclose={closeEarthquakeDetail}
			/>
			{#if selectedAlert}
				<DetailPanel
					alert={selectedAlert}
					onclose={closeDetail}
					onacknowledge={() => alertStore.acknowledge(selectedAlert.id)}
				/>
			{/if}
			<FeedPanel {selectedId} onselect={selectAlert} />
		</BottomSheet>
	</div>
</div>
