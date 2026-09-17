<script lang="ts">
	import type { Alert, Severity } from '$lib/alerts/types';
	import { alertStore } from '$lib/alerts/store.svelte';

	interface Props {
		alert: Alert;
		selected: boolean;
		onselect: () => void;
	}

	let { alert, selected, onselect }: Props = $props();

	const SEVERITY_COLOR: Record<Severity, string> = {
		Extreme: 'text-light',
		Severe: 'text-light',
		Moderate: 'text-ink',
		Minor: 'text-ink-2',
		Unknown: 'text-ink-2'
	};

	let now = $state(Date.now());

	$effect(() => {
		const timer = setInterval(() => (now = Date.now()), 30000);
		return () => clearInterval(timer);
	});

	const isNew = $derived(alertStore.blink.get(alert.id)?.mode === 'arrival');

	function timeSince(iso: string | null): string {
		if (!iso) return '—';
		const minutes = Math.max(0, Math.round((now - new Date(iso).getTime()) / 60000));
		if (minutes < 1) return 'just now';
		if (minutes < 60) return `${minutes}m ago`;
		const hours = Math.round(minutes / 60);
		if (hours < 24) return `${hours}h ago`;
		return `${Math.round(hours / 24)}d ago`;
	}
</script>

<button
	type="button"
	data-testid="feed-item"
	onclick={onselect}
	aria-current={selected ? 'true' : undefined}
	class="border-ink-2/10 hover:bg-shoal focus-visible:bg-shoal flex w-full flex-col gap-0.5 border-b px-3 py-2 text-left text-sm {selected
		? 'bg-shoal'
		: ''}"
>
	<span class="flex items-center justify-between gap-2">
		<span class="font-medium">{alert.event}</span>
		{#if isNew}
			<span class="bg-light shrink-0 px-1 text-xs text-white">New</span>
		{/if}
	</span>
	<span class="flex items-center justify-between gap-2 text-xs">
		<span class={SEVERITY_COLOR[alert.severity]}>{alert.severity}</span>
		<span class="tabular text-ink-2">{timeSince(alert.sent)}</span>
	</span>
	<span class="text-ink-2 line-clamp-1">{alert.area_desc}</span>
</button>
