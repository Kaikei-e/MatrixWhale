<script lang="ts">
	import { saveTheme } from '$lib/alerts/storage';
	import { themeState } from '$lib/theme.svelte';

	function toggle(): void {
		const next = themeState.current === 'night' ? 'day' : 'night';
		document.documentElement.dataset.theme = next;
		saveTheme(next);
	}
</script>

<button
	type="button"
	onclick={toggle}
	aria-label="Switch to {themeState.current === 'night' ? 'day' : 'night'} theme"
	class="border-ink-2/30 text-ink hover:bg-shoal border px-2 py-1 text-sm"
>
	{themeState.current === 'night' ? 'Night' : 'Day'}
</button>
