<script lang="ts">
	import { alertStore } from '$lib/alerts/store.svelte';
	import { SEVERITIES, type Severity } from '$lib/alerts/types';
	import FeedItem from './FeedItem.svelte';
	import SseStatusDot from './SseStatusDot.svelte';

	interface Props {
		selectedId: string | null;
		onselect: (id: string) => void;
		class?: string;
	}

	let { selectedId, onselect, class: className }: Props = $props();

	let now = $state(Date.now());

	const countsBySeverity = $derived.by(() => {
		const counts = { Extreme: 0, Severe: 0, Moderate: 0, Minor: 0, Unknown: 0 } as Record<
			Severity,
			number
		>;
		for (const alert of alertStore.filtered) counts[alert.severity]++;
		return counts;
	});

	$effect(() => {
		const timer = setInterval(() => (now = Date.now()), 30000);
		return () => clearInterval(timer);
	});
</script>

<div class="flex min-h-0 flex-1 flex-col {className ?? ''}">
	<div class="border-ink-2/30 border-b px-3 py-2">
		<div class="flex items-baseline justify-between">
			<h2 class="text-sm font-semibold">Active alerts</h2>
			<span class="text-ink-2 tabular text-xs">{alertStore.filtered.length} total</span>
		</div>
		<div class="text-ink-2 tabular mt-1 flex flex-wrap gap-x-3 gap-y-0.5 text-xs">
			{#each SEVERITIES as severity (severity)}
				{#if countsBySeverity[severity] > 0}
					<span>{severity} {countsBySeverity[severity]}</span>
				{/if}
			{/each}
		</div>
		<SseStatusDot variant="feed" class="mt-1 text-xs" />
	</div>

	{#if alertStore.snapshotError}
		<div class="border-ink-2/30 flex items-center justify-between gap-2 border-b px-3 py-2 text-xs">
			<span>{alertStore.snapshotError}</span>
			<button
				type="button"
				onclick={() => alertStore.retrySnapshot()}
				class="border-ink-2/30 shrink-0 border px-2 py-0.5"
			>
				Retry
			</button>
		</div>
	{/if}

	<ul class="min-h-0 flex-1 overflow-y-auto">
		{#each alertStore.filtered as alert (alert.id)}
			<li>
				<FeedItem
					{alert}
					{now}
					selected={alert.id === selectedId}
					onselect={() => onselect(alert.id)}
				/>
			</li>
		{:else}
			<li class="text-ink-2 px-3 py-4 text-sm">No active alerts match these filters.</li>
		{/each}
	</ul>
</div>
