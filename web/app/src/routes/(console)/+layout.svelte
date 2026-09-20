<script lang="ts">
	import { browser } from '$app/environment';
	import type { Snippet } from 'svelte';
	import ConsoleNav from '$lib/components/ConsoleNav.svelte';
	import { alertStore } from '$lib/alerts/store.svelte';

	let { children }: { children?: Snippet } = $props();

	$effect(() => {
		if (browser) alertStore.connect();
		return () => alertStore.disconnect();
	});

	$effect(() => {
		if (!browser) return;
		const media = matchMedia('(prefers-reduced-motion: reduce)');
		alertStore.reducedMotion = media.matches;
		const onChange = (event: MediaQueryListEvent) => {
			alertStore.reducedMotion = event.matches;
		};
		media.addEventListener('change', onChange);
		return () => media.removeEventListener('change', onChange);
	});
</script>

<div class="flex h-screen flex-col">
	<ConsoleNav />
	<div class="min-h-0 flex-1">
		{@render children?.()}
	</div>
</div>
