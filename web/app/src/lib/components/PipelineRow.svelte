<script lang="ts">
	import { onMount } from 'svelte';
	import type { PipelineStatus } from '$lib/alerts/types';
	import { formatLocalDateTime } from '$lib/alerts/timeFormat';

	let status = $state<PipelineStatus | null>(null);
	let error = $state(false);

	async function refresh(): Promise<void> {
		try {
			const response = await fetch('/api/v1/pipeline/status');
			if (!response.ok) throw new Error(`status ${response.status}`);
			status = (await response.json()) as PipelineStatus;
			error = false;
		} catch {
			error = true;
		}
	}

	onMount(() => {
		refresh();
		const interval = setInterval(refresh, 10000);
		return () => clearInterval(interval);
	});

	function localTime(iso: string | null): string {
		return iso ? formatLocalDateTime(iso) : '—';
	}

	const activeTotal = $derived(
		status ? Object.values(status.active_by_severity).reduce((sum, n) => sum + n, 0) : 0
	);
</script>

<div class="tabular flex flex-wrap gap-x-10 gap-y-3 text-sm">
	{#if error}
		<p class="text-ink-2">Pipeline status unavailable.</p>
	{:else if status}
		<div>
			<p class="text-ink-2">NOAA fetch</p>
			<p>
				<span title={status.last_fetch_at ?? undefined}>{localTime(status.last_fetch_at)}</span>
				· {status.last_http_status ?? '—'}
			</p>
		</div>
		<div>
			<p class="text-ink-2">Received</p>
			<p>{status.last_received ?? '—'}</p>
		</div>
		<div>
			<p class="text-ink-2">Decoded / dropped</p>
			<p class={status.last_dropped && status.last_dropped > 0 ? 'text-light' : ''}>
				{status.last_decoded ?? '—'} / {status.last_dropped ?? '—'}
			</p>
		</div>
		<div>
			<p class="text-ink-2">DB write</p>
			<p>
				<span title={status.last_write_at ?? undefined}>{localTime(status.last_write_at)}</span>
				· new {status.last_new ?? '—'} · updated {status.last_updated ?? '—'} · ended {status.last_ended ??
					'—'}
			</p>
		</div>
		<div>
			<p class="text-ink-2">SSE clients</p>
			<p>{status.sse_clients ?? '—'}</p>
		</div>
		<div>
			<p class="text-ink-2">Active total</p>
			<p>{activeTotal}</p>
		</div>
	{:else}
		<p class="text-ink-2">Loading pipeline status…</p>
	{/if}
</div>
