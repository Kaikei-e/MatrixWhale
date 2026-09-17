<script lang="ts">
	import { page } from '$app/state';
	import type * as maplibregl from 'maplibre-gl';
	import ChartFrame from '$lib/chart/ChartFrame.svelte';
	import ZonesLayer from '$lib/chart/ZonesLayer.svelte';
	import AlertPolygonsLayer from '$lib/chart/AlertPolygonsLayer.svelte';
	import PulseLayer from '$lib/chart/PulseLayer.svelte';
	import CentroidMarkers from '$lib/chart/CentroidMarkers.svelte';
	import Legend from '$lib/chart/Legend.svelte';
	import PresetButtons from '$lib/components/PresetButtons.svelte';
	import FeedPanel from '$lib/components/FeedPanel.svelte';
	import DetailPanel from '$lib/components/DetailPanel.svelte';
	import BottomSheet from '$lib/components/BottomSheet.svelte';
	import { LAND_50M, ZONE_CENTROIDS } from '$lib/chart/dataFiles';
	import { REGION_PRESETS, bboxOfAlerts, initialViewBbox, type Bbox } from '$lib/chart/presets';
	import { alertStore } from '$lib/alerts/store.svelte';
	import { themeState } from '$lib/theme.svelte';
	import { BlinkEngine } from '$lib/alerts/blinkEngine.svelte';

	let map = $state<maplibregl.Map | undefined>();
	let centroids = $state<Record<string, [number, number]>>({});
	let selectedId = $state<string | null>(null);
	let sheetExpanded = $state(false);
	let userInteracted = $state(false);
	let autoFitted = $state(false);
	let focusApplied = $state(false);

	const focusId = page.url.searchParams.get('focus');
	const engine = new BlinkEngine();

	const selectedAlert = $derived(
		selectedId ? (alertStore.activeAlerts.get(selectedId) ?? null) : null
	);

	$effect(() => {
		if (alertStore.hasAnyBlinking) {
			engine.start();
		} else {
			engine.stop();
		}
		return () => engine.stop();
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

	// The desktop side panel (md:w-[22rem]) overlays the map instead of
	// resizing it, so fitBounds needs extra right padding on wide viewports or
	// fitted points can end up hidden behind it.
	const SIDE_PANEL_WIDTH = 352;
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

	function handlePreset(bbox: Bbox): void {
		userInteracted = true;
		fitToBbox(bbox, alertStore.reducedMotion ? 0 : 600);
	}
</script>

<div class="relative h-full w-full">
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
		<CentroidMarkers {centroids} phase={engine.phase} onselect={selectAlert} />
	</ChartFrame>

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

	<div
		data-testid="side-panel"
		class="border-ink-2/30 bg-paper absolute top-0 right-0 bottom-0 hidden w-[22rem] flex-col border-l md:flex"
	>
		{#if selectedAlert}
			<DetailPanel
				alert={selectedAlert}
				onclose={closeDetail}
				onacknowledge={() => alertStore.acknowledge(selectedAlert.id)}
			/>
		{/if}
		<FeedPanel {selectedId} onselect={selectAlert} />
	</div>

	<div class="md:hidden">
		<BottomSheet bind:expanded={sheetExpanded}>
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
