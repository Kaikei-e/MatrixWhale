<script lang="ts">
	interface Props {
		label: string;
		pressed: boolean;
		onclick: () => void;
		dotColor?: string;
		testid?: string;
		class?: string;
	}

	let { label, pressed, onclick, dotColor, testid, class: className }: Props = $props();
</script>

<button
	type="button"
	data-testid={testid}
	aria-pressed={pressed}
	{onclick}
	class="inline-flex items-center gap-1 rounded-full border px-2.5 py-1 text-xs transition-colors {pressed
		? 'bg-shoal border-shoal text-ink'
		: 'border-ink-2/30 text-ink-2 hover:bg-shoal/40'} {className ?? ''}"
>
	{#if pressed}
		<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" class="shrink-0">
			<path
				d="M13.5 4.5 6.5 11.5 3 8"
				fill="none"
				stroke="currentColor"
				stroke-width="1.75"
				stroke-linecap="round"
				stroke-linejoin="round"
			/>
		</svg>
	{:else if dotColor}
		<span
			class="inline-block h-2 w-2 shrink-0 rounded-full"
			style:background-color={dotColor}
			aria-hidden="true"
		></span>
	{/if}
	{label}
</button>
