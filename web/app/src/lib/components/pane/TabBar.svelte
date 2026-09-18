<script lang="ts">
	import { PANE_TABS, PANE_TAB_LABELS, nextTabIndex, type PaneTab } from '$lib/pane/state';
	import { formatBadgeCount } from '$lib/pane/format';

	interface Props {
		active: PaneTab;
		counts: Record<PaneTab, number>;
		onselect: (tab: PaneTab) => void;
	}

	let { active, counts, onselect }: Props = $props();

	// "Earthquakes" is the longest label; 14px left only ~3px of slack in a
	// 95px tab (380px / 4), so 13px is used for every label for a safe margin
	// (measured ~77px vs ~87px available — see TabBar visual verification).
	const TAB_LABEL_FONT_PX = 13;

	function focusTab(tab: PaneTab): void {
		document.getElementById(`pane-tab-${tab}`)?.focus();
	}

	function handleKeydown(event: KeyboardEvent, index: number): void {
		let nextIndex: number | null = null;
		if (event.key === 'ArrowRight') nextIndex = nextTabIndex(index, 1, PANE_TABS.length);
		else if (event.key === 'ArrowLeft') nextIndex = nextTabIndex(index, -1, PANE_TABS.length);
		else if (event.key === 'Home') nextIndex = 0;
		else if (event.key === 'End') nextIndex = PANE_TABS.length - 1;
		if (nextIndex === null) return;
		event.preventDefault();
		const tab = PANE_TABS[nextIndex];
		onselect(tab);
		focusTab(tab);
	}
</script>

<div
	role="tablist"
	aria-label="Side panel sections"
	class="border-ink-2/30 flex shrink-0 overflow-hidden border-b"
>
	{#each PANE_TABS as tab, index (tab)}
		<button
			type="button"
			role="tab"
			id="pane-tab-{tab}"
			aria-selected={tab === active}
			aria-controls="pane-panel-{tab}"
			tabindex={tab === active ? 0 : -1}
			onclick={() => onselect(tab)}
			onkeydown={(event) => handleKeydown(event, index)}
			class="flex min-w-0 flex-1 flex-col justify-center gap-0.5 border-b-2 px-1 py-1.5 {tab ===
			active
				? 'border-ink'
				: 'border-transparent'}"
		>
			<span
				data-testid="pane-tab-label"
				class="text-center font-medium whitespace-nowrap {tab === active
					? 'text-ink'
					: 'text-ink-2'}"
				style:font-size="{TAB_LABEL_FONT_PX}px">{PANE_TAB_LABELS[tab]}</span
			>
			<span class="tabular text-ink-2 text-center text-[12px] leading-none"
				>{formatBadgeCount(counts[tab])}</span
			>
		</button>
	{/each}
</div>
