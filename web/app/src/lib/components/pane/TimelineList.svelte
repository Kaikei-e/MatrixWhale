<script lang="ts">
	import { SvelteSet } from 'svelte/reactivity';
	import { timelineStore } from '$lib/timeline/store.svelte';
	import type { TimelineItem, TimelineKind } from '$lib/timeline/types';
	import { HAZARD_TYPE_LABELS } from '$lib/hazards/types';
	import { alertSeverityLevel, formatShortRelativeTime, magnitudeLabel } from '$lib/pane/format';
	import FilterChip from './FilterChip.svelte';
	import ListRow from './ListRow.svelte';

	interface Props {
		now: number;
		onSelectEarthquake: (id: number) => void;
		onSelectHazard: (id: string) => void;
		onSelectAlert: (id: string) => void;
		listEl?: HTMLUListElement;
	}

	let {
		now,
		onSelectEarthquake,
		onSelectHazard,
		onSelectAlert,
		listEl = $bindable()
	}: Props = $props();

	const KINDS: TimelineKind[] = ['earthquake', 'hazard', 'alert'];
	const KIND_LABELS: Record<TimelineKind, string> = {
		earthquake: 'Earthquakes',
		hazard: 'Hazards',
		alert: 'Alerts'
	};

	let sentinelEl = $state<HTMLLIElement | undefined>();

	function capitalize(value: string): string {
		return value.charAt(0).toUpperCase() + value.slice(1);
	}

	function primaryText(item: TimelineItem): string {
		if (item.kind === 'earthquake') {
			const place = item.earthquake.place ?? item.earthquake.title ?? 'Unknown location';
			return `${magnitudeLabel(item.earthquake.magnitude)} · ${place}`;
		}
		if (item.kind === 'hazard') {
			return `${HAZARD_TYPE_LABELS[item.hazard.hazard_type]} · ${item.hazard.title}`;
		}
		return `${item.alert.event} · ${item.alert.area_desc}`;
	}

	function secondaryText(item: TimelineItem): string {
		if (item.kind === 'hazard') return capitalize(item.hazard.alert_level);
		if (item.kind === 'alert') return item.alert.severity;
		return capitalize(item.severity);
	}

	function select(item: TimelineItem): void {
		if (item.kind === 'earthquake') onSelectEarthquake(item.earthquake.id);
		else if (item.kind === 'hazard') onSelectHazard(item.hazard.id);
		else onSelectAlert(item.alert.id);
	}

	function toggleKind(kind: TimelineKind): void {
		const kinds = new SvelteSet(timelineStore.filters.kinds);
		if (kinds.has(kind)) {
			if (kinds.size === 1) return;
			kinds.delete(kind);
		} else {
			kinds.add(kind);
		}
		timelineStore.setFilters({ kinds });
	}

	function flushAndScrollToTop(): void {
		timelineStore.flushPending();
		listEl?.scrollTo({ top: 0 });
	}

	function handleScroll(event: Event): void {
		const target = event.currentTarget as HTMLElement;
		if (target.scrollTop <= 8 && timelineStore.pending.length > 0) timelineStore.flushPending();
	}

	// New arrivals land in `pending` while the reader may be mid-scroll; if they
	// are already at the top when one shows up, splice it in without a pill.
	$effect(() => {
		if (timelineStore.pending.length === 0) return;
		if (!listEl || listEl.scrollTop > 8) return;
		timelineStore.flushPending();
	});

	$effect(() => {
		if (!sentinelEl) return;
		const observer = new IntersectionObserver(
			(entries) => {
				if (entries[0]?.isIntersecting) void timelineStore.loadMore();
			},
			{ root: listEl ?? null }
		);
		observer.observe(sentinelEl);
		return () => observer.disconnect();
	});
</script>

<div class="flex h-full min-h-0 flex-col">
	<div class="border-ink-2/30 shrink-0 border-b px-3 py-2">
		<h2 class="text-ink text-sm font-semibold">Timeline</h2>
		<div class="mt-2 flex flex-col gap-1.5">
			<div class="flex flex-wrap items-center gap-1.5" aria-label="Kind filters">
				<span class="text-ink-2 w-14 shrink-0 text-[11px] font-medium tracking-wide uppercase"
					>Kind</span
				>
				{#each KINDS as kind (kind)}
					<FilterChip
						label={KIND_LABELS[kind]}
						pressed={timelineStore.filters.kinds.has(kind)}
						onclick={() => toggleKind(kind)}
						testid="timeline-filter-kind-{kind}"
					/>
				{/each}
			</div>
			<div class="flex flex-wrap items-center gap-1.5" aria-label="Magnitude filters">
				<span class="text-ink-2 w-14 shrink-0 text-[11px] font-medium tracking-wide uppercase"
					>Mag</span
				>
				<FilterChip
					label="All"
					pressed={timelineStore.filters.minMagnitude === 'all'}
					onclick={() => timelineStore.setFilters({ minMagnitude: 'all' })}
					testid="timeline-filter-minmag-all"
				/>
				<FilterChip
					label="2.5+"
					pressed={timelineStore.filters.minMagnitude === 2.5}
					onclick={() => timelineStore.setFilters({ minMagnitude: 2.5 })}
					testid="timeline-filter-minmag-2.5"
				/>
				<FilterChip
					label="4.5+"
					pressed={timelineStore.filters.minMagnitude === 4.5}
					onclick={() => timelineStore.setFilters({ minMagnitude: 4.5 })}
					testid="timeline-filter-minmag-4.5"
				/>
			</div>
			<div class="flex flex-wrap items-center gap-1.5" aria-label="Severity filters">
				<span class="text-ink-2 w-14 shrink-0 text-[11px] font-medium tracking-wide uppercase"
					>Severity</span
				>
				<FilterChip
					label="All"
					pressed={timelineStore.filters.minSeverity === 'all'}
					onclick={() => timelineStore.setFilters({ minSeverity: 'all' })}
					testid="timeline-filter-severity-all"
				/>
				<FilterChip
					label="Moderate+"
					pressed={timelineStore.filters.minSeverity === 'moderate'}
					onclick={() => timelineStore.setFilters({ minSeverity: 'moderate' })}
					testid="timeline-filter-severity-moderate"
				/>
				<FilterChip
					label="Severe+"
					pressed={timelineStore.filters.minSeverity === 'severe'}
					onclick={() => timelineStore.setFilters({ minSeverity: 'severe' })}
					testid="timeline-filter-severity-severe"
				/>
				<FilterChip
					label="Extreme"
					pressed={timelineStore.filters.minSeverity === 'extreme'}
					onclick={() => timelineStore.setFilters({ minSeverity: 'extreme' })}
					testid="timeline-filter-severity-extreme"
				/>
			</div>
		</div>
	</div>

	{#if timelineStore.error}
		<div class="border-ink-2/30 flex items-center justify-between gap-2 border-b px-3 py-2 text-xs">
			<span>{timelineStore.error}</span>
		</div>
	{/if}

	<ul
		bind:this={listEl}
		data-testid="timeline-list"
		onscroll={handleScroll}
		class="relative min-h-0 flex-1 overflow-y-auto"
	>
		{#if timelineStore.pending.length > 0}
			<li class="sticky top-0 z-10 flex justify-center py-1">
				<button
					type="button"
					data-testid="timeline-new-pill"
					onclick={flushAndScrollToTop}
					class="bg-ink text-paper rounded-full px-3 py-1 text-xs shadow"
				>
					{timelineStore.pending.length} new
				</button>
			</li>
		{/if}

		{#if timelineStore.loading}
			<li class="text-ink-2 px-3 py-4 text-sm">Loading…</li>
		{:else if timelineStore.items.length === 0}
			<li class="text-ink-2 px-3 py-4 text-sm">No events yet</li>
		{:else}
			{#each timelineStore.items as item (item.key)}
				<ListRow
					testid="timeline-item"
					rowId={item.key}
					title={primaryText(item)}
					time={{ iso: item.seen_at, label: formatShortRelativeTime(item.seen_at, now) }}
					secondary={secondaryText(item)}
					level={item.kind === 'hazard'
						? item.hazard.alert_level
						: item.kind === 'alert'
							? alertSeverityLevel(item.alert.severity)
							: undefined}
					kindColor={item.kind === 'earthquake' ? 'var(--amber)' : undefined}
					updated={timelineStore.updatedKeys.has(item.key)}
					ended={item.ended}
					onclick={() => select(item)}
				/>
			{/each}
			<li data-testid="timeline-sentinel" aria-hidden="true" bind:this={sentinelEl}></li>
			{#if timelineStore.loadingMore}
				<li class="text-ink-2 px-3 py-4 text-sm">Loading…</li>
			{:else if timelineStore.nextCursor === null}
				<li class="text-ink-2 px-3 py-4 text-sm">No more events</li>
			{/if}
		{/if}
	</ul>
</div>
