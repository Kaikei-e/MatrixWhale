<script lang="ts">
	import type { AlertLevel } from '$lib/hazards/types';
	import { levelDotColor, levelLetter } from '$lib/pane/format';
	import { themeState } from '$lib/theme.svelte';

	interface Props {
		testid: string;
		rowId: string;
		title: string;
		meta: string;
		subtitle: string;
		secondary?: string;
		level?: AlertLevel;
		onclick: () => void;
	}

	let { testid, rowId, title, meta, subtitle, secondary, level, onclick }: Props = $props();
</script>

<li>
	<button
		type="button"
		data-testid={testid}
		data-row-id={rowId}
		{onclick}
		class="border-ink-2/10 hover:bg-shoal focus-visible:bg-shoal flex w-full flex-col gap-0.5 border-b px-3 py-2 text-left"
	>
		<span class="flex items-center gap-2">
			{#if level}
				<span
					class="flex h-4 w-4 shrink-0 items-center justify-center rounded-full text-[9px] font-bold text-white"
					style:background-color={levelDotColor(level, themeState.current)}
					aria-hidden="true"
				>
					{levelLetter(level)}
				</span>
			{/if}
			<span class="text-ink min-w-0 flex-1 truncate text-[15px] font-medium">{title}</span>
			<span class="tabular text-ink-2 shrink-0 text-xs">{meta}</span>
		</span>
		<span class="text-ink-2 flex min-w-0 items-center gap-1 text-sm {level ? 'pl-6' : ''}">
			{#if subtitle}
				<span class="min-w-0 shrink-0 truncate">{subtitle}</span>
			{/if}
			{#if secondary}
				{#if subtitle}
					<span aria-hidden="true" class="shrink-0">·</span>
				{/if}
				<span class="min-w-0 flex-1 truncate">{secondary}</span>
			{/if}
		</span>
	</button>
</li>
