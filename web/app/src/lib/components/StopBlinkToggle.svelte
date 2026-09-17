<script lang="ts">
	import { alertStore } from '$lib/alerts/store.svelte';
</script>

<button
	type="button"
	aria-pressed={alertStore.stopAll}
	onclick={() => (alertStore.stopAll = !alertStore.stopAll)}
	class="border-ink-2/30 text-ink hover:bg-shoal border px-2 py-1 text-sm"
>
	Stop blinking
</button>
