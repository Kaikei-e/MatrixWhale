<script lang="ts">
	import type { Snippet } from 'svelte';

	interface Props {
		expanded?: boolean;
		children?: Snippet;
	}

	let { expanded = $bindable(false), children }: Props = $props();
</script>

<div
	class="border-ink-2/30 bg-paper absolute inset-x-0 bottom-0 flex flex-col border-t transition-transform duration-200"
	style="height: 60vh; transform: translateY({expanded ? '0' : 'calc(100% - 2.75rem)'})"
>
	<button
		type="button"
		aria-expanded={expanded}
		onclick={() => (expanded = !expanded)}
		class="flex w-full shrink-0 items-center justify-center py-2"
	>
		<span class="bg-ink-2/40 h-1 w-10 rounded-full" aria-hidden="true"></span>
		<span class="sr-only">{expanded ? 'Collapse alert feed' : 'Expand alert feed'}</span>
	</button>
	<div class="min-h-0 flex-1 overflow-y-auto">
		{@render children?.()}
	</div>
</div>
