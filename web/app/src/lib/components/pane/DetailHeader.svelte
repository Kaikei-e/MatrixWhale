<script lang="ts">
	interface Props {
		title: string;
		onback: () => void;
	}

	let { title, onback }: Props = $props();
	let backButton = $state<HTMLButtonElement | undefined>();

	// The row that opened this detail is gone from the DOM, so keyboard focus
	// would otherwise fall back to <body>; anchor it here on every drill-in.
	$effect(() => {
		backButton?.focus();
	});
</script>

<div class="border-ink-2/30 flex shrink-0 items-center gap-2 border-b px-3 py-2">
	<button
		bind:this={backButton}
		type="button"
		onclick={onback}
		aria-label="Back to list"
		class="text-ink-2 hover:text-ink hover:bg-shoal shrink-0 rounded p-1"
	>
		<svg viewBox="0 0 20 20" width="18" height="18" aria-hidden="true">
			<path
				d="M12.5 4.5 7 10l5.5 5.5"
				fill="none"
				stroke="currentColor"
				stroke-width="1.75"
				stroke-linecap="round"
				stroke-linejoin="round"
			/>
		</svg>
	</button>
	<h2 class="text-ink min-w-0 flex-1 truncate text-sm font-semibold">{title}</h2>
</div>
