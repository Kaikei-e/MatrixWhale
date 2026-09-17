<script lang="ts">
	import 'maplibre-gl/dist/maplibre-gl.css';
	import 'svelte-maplibre-gl/vite';
	import { MapLibre, GeoJSONSource, FillLayer, LineLayer } from 'svelte-maplibre-gl';
	import type * as maplibregl from 'maplibre-gl';
	import type { Snippet } from 'svelte';
	import { DAY, NIGHT } from './tokens';

	interface TickMark {
		pos: number;
		label: string;
	}

	interface Props {
		map?: maplibregl.Map;
		interactive?: boolean;
		landUrl: string;
		initialBounds: [number, number, number, number];
		theme: 'day' | 'night';
		t?: number;
		nws?: boolean;
		class?: string;
		children?: Snippet;
	}

	let {
		map = $bindable(undefined),
		interactive = true,
		landUrl,
		initialBounds,
		theme,
		t = 0,
		nws = false,
		class: className,
		children
	}: Props = $props();

	const TICK_STEPS = [30, 20, 10, 5, 2, 1, 0.5];

	let container: HTMLDivElement | undefined = $state();
	let width = $state(0);
	let height = $state(0);
	let xTicks = $state<TickMark[]>([]);
	let yTicks = $state<TickMark[]>([]);

	function pickStep(range: number): number {
		for (const step of TICK_STEPS) {
			if (range / step >= 4) return step;
		}
		return TICK_STEPS[TICK_STEPS.length - 1];
	}

	function formatLat(lat: number): string {
		const rounded = Math.round(lat * 10) / 10;
		return `${Math.abs(rounded)}°${rounded >= 0 ? 'N' : 'S'}`;
	}

	function formatLon(lon: number): string {
		const rounded = Math.round(lon * 10) / 10;
		return `${Math.abs(rounded)}°${rounded >= 0 ? 'E' : 'W'}`;
	}

	function updateGraticule(): void {
		if (!map || !container) return;
		width = container.clientWidth;
		height = container.clientHeight;

		const bounds = map.getBounds();
		const west = bounds.getWest();
		const east = bounds.getEast();
		const south = bounds.getSouth();
		const north = bounds.getNorth();

		const lonStep = pickStep(east - west);
		const latStep = pickStep(north - south);

		const nextXTicks: TickMark[] = [];
		for (let lon = Math.ceil(west / lonStep) * lonStep; lon <= east; lon += lonStep) {
			nextXTicks.push({ pos: map.project([lon, north]).x, label: formatLon(lon) });
		}

		const nextYTicks: TickMark[] = [];
		for (let lat = Math.floor(north / latStep) * latStep; lat >= south; lat -= latStep) {
			nextYTicks.push({ pos: map.project([west, lat]).y, label: formatLat(lat) });
		}

		xTicks = nextXTicks;
		yTicks = nextYTicks;
	}

	$effect(() => {
		if (!map || !container) return;

		map.on('load', updateGraticule);
		map.on('moveend', updateGraticule);
		const resizeObserver = new ResizeObserver(() => updateGraticule());
		resizeObserver.observe(container);
		updateGraticule();

		return () => {
			map?.off('load', updateGraticule);
			map?.off('moveend', updateGraticule);
			resizeObserver.disconnect();
		};
	});
</script>

<div bind:this={container} class="relative {className ?? ''}">
	<MapLibre
		bind:map
		autoloadGlobalCss={false}
		{interactive}
		renderWorldCopies
		attributionControl={false}
		style={{
			version: 8,
			sources: {},
			layers: [
				{
					id: 'bg',
					type: 'background',
					paint: {
						'background-color': [
							'match',
							['global-state', 'theme'],
							'night',
							NIGHT.paper,
							DAY.paper
						]
					}
				}
			]
		}}
		globalState={{ theme, t, nws }}
		bounds={initialBounds}
		class="h-full w-full"
	>
		<GeoJSONSource id="land" data={landUrl}>
			<FillLayer
				id="land-fill"
				paint={{
					'fill-color': ['match', ['global-state', 'theme'], 'night', NIGHT.land, DAY.land]
				}}
			/>
			<LineLayer
				id="land-line"
				paint={{
					'line-color': ['match', ['global-state', 'theme'], 'night', NIGHT['ink-2'], DAY['ink-2']],
					'line-width': 0.6,
					'line-opacity': 0.6
				}}
			/>
		</GeoJSONSource>
		{@render children?.()}
	</MapLibre>

	<svg class="pointer-events-none absolute inset-0" {width} {height} viewBox="0 0 {width} {height}">
		<rect
			x="0.5"
			y="0.5"
			width={Math.max(width - 1, 0)}
			height={Math.max(height - 1, 0)}
			fill="none"
			stroke="var(--ink)"
			stroke-width="1"
		/>
		{#each xTicks as tick (tick.label)}
			<line x1={tick.pos} y1="0" x2={tick.pos} y2="6" stroke="var(--ink-2)" stroke-width="1" />
			<text x={tick.pos + 4} y="14" class="tabular" font-size="10" fill="var(--ink-2)"
				>{tick.label}</text
			>
		{/each}
		{#each yTicks as tick (tick.label)}
			<line x1="0" y1={tick.pos} x2="6" y2={tick.pos} stroke="var(--ink-2)" stroke-width="1" />
			<text x="8" y={tick.pos - 4} class="tabular" font-size="10" fill="var(--ink-2)"
				>{tick.label}</text
			>
		{/each}
	</svg>
</div>
