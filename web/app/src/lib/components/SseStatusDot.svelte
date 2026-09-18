<script lang="ts">
	import { alertStore } from '$lib/alerts/store.svelte';

	interface Props {
		variant?: 'nav' | 'feed';
		connected?: 'connecting' | 'open' | 'closed';
		class?: string;
	}

	let {
		variant = 'nav',
		connected = alertStore.connected,
		class: className = 'text-sm'
	}: Props = $props();

	const LABEL = {
		nav: { open: 'Live', connecting: 'Connecting', closed: 'Disconnected' },
		feed: { open: 'Live', connecting: 'Connecting…', closed: 'Disconnected — retrying' }
	} as const;

	const DOT_COLOR = {
		nav: { open: 'bg-green-600', connecting: 'bg-amber-500', closed: 'bg-red-600' },
		feed: { open: 'bg-green-600', connecting: 'bg-ink-2', closed: 'bg-red-600' }
	} as const;
</script>

<span
	class="text-ink-2 flex items-center gap-2 {className}"
	aria-label="SSE status: {LABEL[variant][connected]}"
>
	<span class="h-2 w-2 rounded-full {DOT_COLOR[variant][connected]}" aria-hidden="true"></span>
	{LABEL[variant][connected]}
</span>
