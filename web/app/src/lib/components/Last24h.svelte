<script lang="ts">
	import { onMount } from 'svelte';
	import { SEVERITIES, type HistoryBucket, type Severity } from '$lib/alerts/types';

	const SEVERITY_BAR_COLOR: Record<Severity, string> = {
		Extreme: 'bg-light',
		Severe: 'bg-light/60',
		Moderate: 'bg-ink-2/70',
		Minor: 'bg-ink-2/40',
		Unknown: 'bg-ink-2/20'
	};

	let buckets = $state<HistoryBucket[] | null>(null);
	let error = $state(false);

	const hourFormat = new Intl.DateTimeFormat(undefined, { hour: 'numeric' });

	async function refresh(): Promise<void> {
		try {
			const response = await fetch('/api/v1/alerts/history?hours=24');
			if (!response.ok) throw new Error(`status ${response.status}`);
			buckets = (await response.json()) as HistoryBucket[];
			error = false;
		} catch {
			error = true;
		}
	}

	onMount(() => {
		refresh();
		const interval = setInterval(refresh, 60000);
		return () => clearInterval(interval);
	});

	function bucketTotal(bucket: HistoryBucket): number {
		return SEVERITIES.reduce((sum, severity) => sum + bucket.counts[severity], 0);
	}
</script>

{#if error}
	<p class="text-ink-2 text-sm">History unavailable.</p>
{:else if buckets}
	{@const totals = buckets.map(bucketTotal)}
	{@const maxTotal = Math.max(1, ...totals)}
	<div class="flex h-16 items-end gap-1">
		{#each buckets as bucket, i (bucket.hour_start)}
			<div
				class="flex flex-1 flex-col-reverse"
				style="height: {(totals[i] / maxTotal) * 100}%"
				title="{hourFormat.format(new Date(bucket.hour_start))}: {totals[i]}"
			>
				{#each SEVERITIES as severity (severity)}
					{#if bucket.counts[severity] > 0}
						<div
							class={SEVERITY_BAR_COLOR[severity]}
							style="height: {(bucket.counts[severity] / totals[i]) * 100}%"
						></div>
					{/if}
				{/each}
			</div>
		{/each}
	</div>
	<div class="tabular text-ink-2 mt-1 flex gap-1 text-xs">
		{#each buckets as bucket, i (bucket.hour_start)}
			<span class="flex-1 text-center"
				>{i % 4 === 0 ? hourFormat.format(new Date(bucket.hour_start)) : ''}</span
			>
		{/each}
	</div>
{:else}
	<p class="text-ink-2 text-sm">Loading history…</p>
{/if}
