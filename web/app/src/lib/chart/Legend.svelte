<script lang="ts">
	import { alertStore } from '$lib/alerts/store.svelte';
	import { NWS_EVENT_COLORS, DEFAULT_NWS_COLOR } from '$lib/alerts/nwsEventStyle';
	import { NWS_PRIORITY, UNKNOWN_PRIORITY } from '$lib/alerts/priority';
	import { summarizeAlertSources } from '$lib/alerts/attribution';

	interface Props {
		class?: string;
	}

	let { class: className }: Props = $props();

	const BLINK_ROWS = [
		{ key: 'q', label: 'Q', desc: 'New alert' },
		{ key: 'fl2', label: 'Fl 2s', desc: 'Extreme, unconfirmed' },
		{ key: 'fl4', label: 'Fl 4s', desc: 'Severe, unconfirmed' },
		{ key: 'f', label: 'F', desc: 'Moderate' }
	] as const;

	const MAX_NWS_ROWS = 12;

	const motion = $derived(alertStore.stopAll || alertStore.reducedMotion ? 'static' : undefined);

	const nwsEventSummary = $derived.by(() => {
		const counts: Record<string, number> = {};
		for (const alert of alertStore.activeAlerts.values()) {
			if (alert.source !== 'noaa') continue;
			counts[alert.event] = (counts[alert.event] ?? 0) + 1;
		}
		return Object.entries(counts)
			.map(([event, count]) => ({
				event,
				count,
				color: NWS_EVENT_COLORS[event] ?? DEFAULT_NWS_COLOR
			}))
			.sort((a, b) => {
				const priorityA = NWS_PRIORITY[a.event] ?? UNKNOWN_PRIORITY;
				const priorityB = NWS_PRIORITY[b.event] ?? UNKNOWN_PRIORITY;
				return priorityA !== priorityB ? priorityA - priorityB : b.count - a.count;
			});
	});

	const visibleNwsEvents = $derived(nwsEventSummary.slice(0, MAX_NWS_ROWS));
	const hiddenNwsEventCount = $derived(Math.max(0, nwsEventSummary.length - MAX_NWS_ROWS));
	const alertSourceSummary = $derived(summarizeAlertSources(alertStore.filtered, 3));
</script>

<div
	data-testid="legend"
	data-motion={motion}
	class="border-ink-2/30 bg-paper/90 text-ink flex max-h-[60vh] flex-col gap-1.5 overflow-y-auto border px-3 py-2 text-xs {className ??
		''}"
>
	{#each BLINK_ROWS as row (row.key)}
		<div class="flex items-center gap-2">
			<span class="legend-dot legend-dot-{row.key}" aria-hidden="true"></span>
			<span class="tabular w-14 shrink-0">{row.label}</span>
			<span class="text-ink-2">{row.desc}</span>
		</div>
	{/each}
	<div
		class="border-ink-2/30 mt-1 flex flex-col gap-1 border-t pt-1.5"
		data-testid="severity-swatches"
	>
		<span class="font-semibold">Severity</span>
		<div class="flex flex-wrap items-center gap-x-2.5 gap-y-1">
			<div class="flex items-center gap-1">
				<span class="legend-swatch" style="background-color: var(--light)" aria-hidden="true"
				></span>
				<span class="text-ink-2">Extreme</span>
			</div>
			<div class="flex items-center gap-1">
				<span class="legend-swatch" style="background-color: var(--amber)" aria-hidden="true"
				></span>
				<span class="text-ink-2">Severe</span>
			</div>
			<div class="flex items-center gap-1">
				<span class="legend-swatch" style="background-color: var(--moderate)" aria-hidden="true"
				></span>
				<span class="text-ink-2">Moderate</span>
			</div>
			<div class="flex items-center gap-1">
				<span class="legend-swatch" style="background-color: var(--minor)" aria-hidden="true"
				></span>
				<span class="text-ink-2">Minor</span>
			</div>
			<div class="flex items-center gap-1">
				<span class="legend-swatch" style="background-color: var(--ink-2)" aria-hidden="true"
				></span>
				<span class="text-ink-2">Unknown</span>
			</div>
		</div>
	</div>
	{#if alertSourceSummary.totalUnique > 0}
		<div class="border-ink-2/30 mt-1 flex flex-col gap-1 border-t pt-1.5">
			<span class="font-semibold">Sources</span>
			{#each alertSourceSummary.visible as source (source.name)}
				<div class="flex items-center justify-between gap-2">
					<span class="text-ink-2 truncate">{source.name}</span>
					<span class="tabular text-ink-2 shrink-0">{source.count}</span>
				</div>
			{/each}
			{#if alertSourceSummary.hiddenCount > 0}
				<span class="text-ink-2">+{alertSourceSummary.hiddenCount} more</span>
			{/if}
		</div>
	{/if}
	{#if alertStore.useNwsColors && nwsEventSummary.length > 0}
		<div
			data-testid="nws-colors-summary"
			class="border-ink-2/30 mt-1 flex flex-col gap-1.5 border-t pt-1.5"
		>
			<span class="font-semibold">NWS colors</span>
			{#each visibleNwsEvents as row (row.event)}
				<div class="flex items-center gap-2">
					<span class="legend-swatch" style="background-color: {row.color}" aria-hidden="true"
					></span>
					<span class="flex-1 truncate">{row.event}</span>
					<span class="tabular text-ink-2 w-6 shrink-0 text-right">{row.count}</span>
				</div>
			{/each}
			{#if hiddenNwsEventCount > 0}
				<span class="text-ink-2 pl-4">+{hiddenNwsEventCount} more</span>
			{/if}
			<span class="text-ink-2">Click a light for its event.</span>
		</div>
	{/if}
</div>

<style>
	.legend-dot {
		width: 0.5rem;
		height: 0.5rem;
		border-radius: 9999px;
		background: var(--light);
		flex-shrink: 0;
	}

	.legend-dot-f {
		opacity: 0.7;
	}

	.legend-swatch {
		width: 0.5rem;
		height: 0.5rem;
		border-radius: 9999px;
		flex-shrink: 0;
	}

	@media (prefers-reduced-motion: no-preference) {
		[data-testid='legend']:not([data-motion='static']) .legend-dot-q {
			animation: legend-blink-30 1000ms steps(1, end) infinite;
		}

		[data-testid='legend']:not([data-motion='static']) .legend-dot-fl2 {
			animation: legend-blink-25 2000ms steps(1, end) infinite;
		}

		[data-testid='legend']:not([data-motion='static']) .legend-dot-fl4 {
			animation: legend-blink-25 4000ms steps(1, end) infinite;
		}
	}

	@keyframes legend-blink-30 {
		0%,
		30% {
			opacity: 1;
		}
		30.01%,
		100% {
			opacity: 0.15;
		}
	}

	@keyframes legend-blink-25 {
		0%,
		25% {
			opacity: 1;
		}
		25.01%,
		100% {
			opacity: 0.15;
		}
	}
</style>
