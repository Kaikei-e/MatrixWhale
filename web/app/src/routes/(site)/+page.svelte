<script lang="ts">
	import { browser } from '$app/environment';
	import { resolve } from '$app/paths';
	import type * as maplibregl from 'maplibre-gl';
	import ChartFrame from '$lib/chart/ChartFrame.svelte';
	import { LAND_110M, ZONE_CENTROIDS } from '$lib/chart/dataFiles';
	import { REGION_PRESETS } from '$lib/chart/presets';
	import { alertCentroid } from '$lib/chart/alertPoints';
	import { tokensFor } from '$lib/chart/tokens';
	import { themeState } from '$lib/theme.svelte';
	import type { Alert } from '$lib/alerts/types';
	import type { Feature, Point } from 'geojson';

	const REPO_URL = 'https://github.com/Kaikei-e/MatrixWhale';
	const ALERT_POINTS_SOURCE = 'landing-alert-points';
	const LIGHT_STAGGER_MS = 40;
	const MAX_STAGGER_MS = 2000;

	let map = $state<maplibregl.Map | undefined>();
	let liveError = $state(false);
	let activeAlertCount = $state<number | undefined>();
	let staggerTimers: Array<ReturnType<typeof setTimeout>> = [];

	async function lightActiveAlerts(
		currentMap: maplibregl.Map,
		signal?: AbortSignal
	): Promise<void> {
		try {
			const [alertsResponse, centroidsResponse] = await Promise.all([
				fetch('/api/v1/alerts/active?sources=noaa', { signal }),
				fetch(ZONE_CENTROIDS, { signal })
			]);
			if (!alertsResponse.ok) throw new Error(`alerts request failed: ${alertsResponse.status}`);
			if (signal?.aborted) return;

			const alerts = (await alertsResponse.json()) as Alert[];
			if (signal?.aborted) return;
			activeAlertCount = alerts.length;
			const centroids = centroidsResponse.ok
				? ((await centroidsResponse.json()) as Record<string, [number, number]>)
				: {};
			if (signal?.aborted) return;

			const bySentAsc = [...alerts].sort((a, b) => (a.sent ?? '').localeCompare(b.sent ?? ''));

			const features: Feature<Point>[] = [];
			for (const alert of bySentAsc) {
				const point = alertCentroid(alert, centroids);
				if (!point) continue;
				features.push({
					type: 'Feature',
					id: features.length,
					geometry: { type: 'Point', coordinates: point },
					properties: {}
				});
			}
			if (features.length === 0 || signal?.aborted) return;

			currentMap.addSource(ALERT_POINTS_SOURCE, {
				type: 'geojson',
				data: { type: 'FeatureCollection', features }
			});
			currentMap.addLayer({
				id: ALERT_POINTS_SOURCE,
				type: 'circle',
				source: ALERT_POINTS_SOURCE,
				paint: {
					'circle-color': [
						'match',
						['global-state', 'theme'],
						'night',
						tokensFor('night').light,
						tokensFor('day').light
					],
					'circle-radius': 4,
					'circle-opacity': ['case', ['boolean', ['feature-state', 'lit'], false], 1, 0]
				}
			});

			for (const timer of staggerTimers) clearTimeout(timer);
			staggerTimers = [];

			features.forEach((feature, index) => {
				const delay = Math.min(index * LIGHT_STAGGER_MS, MAX_STAGGER_MS);
				const timer = setTimeout(() => {
					if (signal?.aborted) return;
					currentMap.setFeatureState(
						{ source: ALERT_POINTS_SOURCE, id: feature.id },
						{ lit: true }
					);
				}, delay);
				staggerTimers.push(timer);
			});
		} catch {
			if (!signal?.aborted) {
				liveError = true;
			}
		}
	}

	$effect(() => {
		if (!browser || !map) return;
		const currentMap = map;
		const controller = new AbortController();
		const onLoad = () => void lightActiveAlerts(currentMap, controller.signal);
		if (currentMap.loaded()) onLoad();
		else currentMap.on('load', onLoad);
		return () => {
			controller.abort();
			currentMap.off('load', onLoad);
			for (const timer of staggerTimers) clearTimeout(timer);
			staggerTimers = [];
		};
	});
</script>

<section class="relative">
	{#if browser}
		<ChartFrame
			interactive={false}
			landUrl={LAND_110M}
			initialBounds={REGION_PRESETS.CONUS}
			theme={themeState.current}
			bind:map
			class="aspect-[21/9] w-full"
		/>
	{:else}
		<div class="chart-placeholder border-ink bg-paper aspect-[21/9] w-full border"></div>
	{/if}

	<div class="pointer-events-none absolute inset-0 flex items-center p-6">
		<div class="border-ink bg-paper/90 pointer-events-auto max-w-sm border p-5">
			<h1 class="text-2xl font-semibold">MatrixWhale</h1>
			<p class="text-ink-2 mt-1 text-sm">Global weather and hazard alerts, charted live.</p>
			<p class="tabular text-ink-2 mt-3 text-xs">
				Mercator · Data: NOAA api.weather.gov · WMO RAA national CAP feeds · Natural Earth
			</p>
			{#if liveError}
				<p class="text-ink-2 mt-3 text-sm">Live data unavailable.</p>
			{:else if activeAlertCount !== undefined}
				<p class="tabular text-ink-2 text-xs">
					{activeAlertCount} active US NWS {activeAlertCount === 1 ? 'alert' : 'alerts'}
				</p>
			{/if}
			<div class="mt-4 flex gap-3 text-sm">
				<a href={resolve('/globe')} class="border-ink hover:bg-shoal border px-3 py-1.5"
					>Open the chart</a
				>
				<a href={resolve('/home')} class="border-ink hover:bg-shoal border px-3 py-1.5"
					>Open console</a
				>
			</div>
		</div>
	</div>
</section>

<section class="mx-auto max-w-3xl px-6 py-10">
	<h2 class="text-ink-2 text-xs tracking-wide uppercase">How data flows</h2>
	<ol class="tabular mt-3 list-inside list-decimal text-sm">
		<li>NOAA and WMO CAP alerting feeds</li>
		<li>Plecto proxy</li>
		<li>Go adapters</li>
		<li>Gleam core</li>
		<li>PostgreSQL</li>
		<li>SSE</li>
		<li>SvelteKit</li>
	</ol>
</section>

<section class="border-ink-2/30 mx-auto max-w-3xl border-t px-6 py-10">
	<h2 class="text-ink-2 text-xs tracking-wide uppercase">What you can do</h2>
	<div class="mt-4 flex flex-col gap-6 text-sm">
		<div>
			<h3 class="font-medium">Watch</h3>
			<p class="text-ink-2 mt-1">
				Open the chart to see active weather and hazard alerts light up on a live nautical-style
				map.
			</p>
		</div>
		<div>
			<h3 class="font-medium">Search</h3>
			<p class="text-ink-2 mt-1">Search past and current alerts by area name from the console.</p>
		</div>
		<div>
			<h3 class="font-medium">Subscribe</h3>
			<p class="text-ink-2 mt-1">Read the alert stream directly over server-sent events.</p>
			<pre class="tabular border-ink-2/30 mt-2 overflow-x-auto border p-3 text-xs"><code
					>curl -N -H 'Accept: text/event-stream' https://&lt;host&gt;/api/v1/alerts/stream</code
				></pre>
		</div>
	</div>
</section>

<footer class="border-ink-2/30 text-ink-2 mx-auto max-w-3xl border-t px-6 py-10 text-xs">
	<p>
		<a href={REPO_URL} class="hover:underline">{REPO_URL.replace('https://', '')}</a> · Apache-2.0
	</p>
	<p class="mt-1">Data: NOAA · WMO Register of Alerting Authorities · Natural Earth</p>
	<p class="mt-1">Use official sources for life-safety decisions.</p>
</footer>
