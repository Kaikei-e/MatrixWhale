<script lang="ts">
	import { alertStore } from '$lib/alerts/store.svelte';

	const LABEL = { open: 'Live', connecting: 'Connecting', closed: 'Disconnected' } as const;
	const DOT_COLOR = {
		open: 'bg-green-600',
		connecting: 'bg-amber-500',
		closed: 'bg-red-600'
	} as const;
</script>

<span
	class="text-ink-2 flex items-center gap-2 text-sm"
	aria-label="SSE status: {LABEL[alertStore.connected]}"
>
	<span class="h-2 w-2 rounded-full {DOT_COLOR[alertStore.connected]}" aria-hidden="true"></span>
	{LABEL[alertStore.connected]}
</span>
