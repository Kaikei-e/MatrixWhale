<script lang="ts">
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
	import ThemeToggle from './ThemeToggle.svelte';
	import StopBlinkToggle from './StopBlinkToggle.svelte';
	import SseStatusDot from './SseStatusDot.svelte';
</script>

<nav
	class="border-ink-2/30 flex flex-wrap items-center justify-between gap-x-4 gap-y-2 border-b px-4 py-3"
>
	<a href={resolve('/')} class="font-semibold whitespace-nowrap">MatrixWhale</a>
	<div class="flex items-center gap-4 text-sm">
		<a href={resolve('/globe')} aria-current={page.url.pathname === '/globe' ? 'page' : undefined}
			>Chart</a
		>
		<a href={resolve('/home')} aria-current={page.url.pathname === '/home' ? 'page' : undefined}
			>Console</a
		>
		<a href={resolve('/feeds')} aria-current={page.url.pathname === '/feeds' ? 'page' : undefined}
			>Feeds</a
		>
	</div>
	<div class="flex items-center gap-3">
		<SseStatusDot />
		<StopBlinkToggle />
		<ThemeToggle />
	</div>
</nav>
