<script lang="ts">
	import { alertStore } from '$lib/alerts/store.svelte';
	import { SEVERITIES, type Severity } from '$lib/alerts/types';

	const SEVERITY_BAR_COLOR: Record<Severity, string> = {
		Extreme: 'bg-light',
		Severe: 'bg-light/60',
		Moderate: 'bg-ink-2/70',
		Minor: 'bg-ink-2/40',
		Unknown: 'bg-ink-2/20'
	};

	const total = $derived(Object.values(alertStore.countsBySeverity).reduce((sum, n) => sum + n, 0));
	const top = $derived(alertStore.sorted.slice(0, 8));
</script>

<div>
	<div class="border-ink-2/30 flex h-4 w-full overflow-hidden border">
		{#each SEVERITIES as severity (severity)}
			{@const count = alertStore.countsBySeverity[severity]}
			{#if total > 0 && count > 0}
				<div
					class={SEVERITY_BAR_COLOR[severity]}
					style="width: {(count / total) * 100}%"
					title="{severity}: {count}"
				></div>
			{/if}
		{/each}
		{#if total === 0}
			<div class="bg-ink-2/10 w-full"></div>
		{/if}
	</div>

	<ol class="tabular mt-3 flex flex-col gap-1 text-sm">
		{#each top as alert (alert.id)}
			<li class="border-ink-2/10 flex justify-between gap-4 border-b py-1">
				<span>{alert.event}</span>
				<span class="text-ink-2">{alert.severity}</span>
			</li>
		{:else}
			<li class="text-ink-2">No active alerts.</li>
		{/each}
	</ol>
</div>
