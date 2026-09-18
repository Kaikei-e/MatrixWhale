<script lang="ts">
	import type { AlertLevel } from '$lib/hazards/types';
	import { levelDotColor, levelLetter } from '$lib/pane/format';
	import { themeState } from '$lib/theme.svelte';

	interface RowTime {
		iso: string;
		label: string;
	}

	interface Props {
		testid: string;
		rowId: string;
		title: string;
		meta?: string;
		time?: RowTime;
		subtitle?: string;
		secondary?: string;
		level?: AlertLevel;
		kindColor?: string;
		updated?: boolean;
		ended?: boolean;
		onclick: () => void;
	}

	let {
		testid,
		rowId,
		title,
		meta,
		time,
		subtitle,
		secondary,
		level,
		kindColor,
		updated,
		ended,
		onclick
	}: Props = $props();
</script>

<li>
	<button
		type="button"
		data-testid={testid}
		data-row-id={rowId}
		{onclick}
		class="border-ink-2/10 hover:bg-shoal focus-visible:bg-shoal flex w-full flex-col gap-0.5 border-b px-3 py-2 text-left {ended
			? 'opacity-50'
			: ''}"
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
			{:else if kindColor}
				<span
					class="h-2.5 w-2.5 shrink-0 rounded-full"
					style:background-color={kindColor}
					aria-hidden="true"
				></span>
			{/if}
			<span class="text-ink min-w-0 flex-1 truncate text-[15px] font-medium">{title}</span>
			{#if meta}
				<span class="tabular text-ink-2 shrink-0 text-xs">{meta}</span>
			{/if}
		</span>
		<span
			class="text-ink-2 flex min-w-0 items-center gap-1 text-sm {level || kindColor ? 'pl-6' : ''}"
		>
			{#if time}
				<time datetime={time.iso} title={time.iso} class="tabular shrink-0">{time.label}</time>
			{:else if subtitle}
				<span class="min-w-0 shrink-0 truncate">{subtitle}</span>
			{/if}
			{#if secondary}
				{#if time || subtitle}
					<span aria-hidden="true" class="shrink-0">·</span>
				{/if}
				<span class="min-w-0 flex-1 truncate">{secondary}</span>
			{/if}
			{#if updated}
				<span
					data-testid="timeline-badge-updated"
					class="bg-shoal text-ink-2 shrink-0 rounded-full px-1.5 py-0 text-[10px] font-medium tracking-wide uppercase"
					>Updated</span
				>
			{/if}
			{#if ended}
				<span
					data-testid="timeline-badge-ended"
					class="bg-shoal text-ink-2 shrink-0 rounded-full px-1.5 py-0 text-[10px] font-medium tracking-wide uppercase"
					>Ended</span
				>
			{/if}
		</span>
	</button>
</li>
