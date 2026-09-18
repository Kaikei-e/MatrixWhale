<script lang="ts">
	import { untrack } from 'svelte';
	import { SvelteSet } from 'svelte/reactivity';
	import { browser } from '$app/environment';
	import { earthquakeStore } from '$lib/earthquakes/store.svelte';
	import type { DataSource, EarthquakeMember } from '$lib/earthquakes/types';
	import { hazardStore } from '$lib/hazards/store.svelte';
	import {
		ALERT_LEVELS,
		ALERT_LEVEL_COLORS,
		HAZARD_TYPES,
		HAZARD_TYPE_LABELS,
		type AlertLevel,
		type HazardType
	} from '$lib/hazards/types';
	import { alertStore } from '$lib/alerts/store.svelte';
	import { formatLocalDateTime } from '$lib/alerts/timeFormat';
	import {
		PANE_TAB_LABELS,
		loadStoredTab,
		storeTab,
		resolveTabForSelection,
		isDetailOpen,
		closeKindForTab,
		type PaneTab,
		type SelectionKind
	} from '$lib/pane/state';
	import {
		formatShortRelativeTime,
		magnitudeLabel,
		earthquakeSeverity,
		alertSeverityLevel
	} from '$lib/pane/format';
	import { ScrollMemory } from '$lib/pane/scroll';
	import TabBar from './TabBar.svelte';
	import FilterChip from './FilterChip.svelte';
	import ListRow from './ListRow.svelte';
	import DetailHeader from './DetailHeader.svelte';
	import FeedPanel from '../FeedPanel.svelte';
	import DetailPanel from '../DetailPanel.svelte';
	import SseStatusDot from '../SseStatusDot.svelte';

	interface Props {
		selectedEarthquakeId: number | null;
		selectedHazardId: string | null;
		selectedAlertId: string | null;
		onSelectEarthquake: (id: number) => void;
		onSelectHazard: (id: string) => void;
		onSelectAlert: (id: string) => void;
		onCloseEarthquake: () => void;
		onCloseHazard: () => void;
		onCloseAlert: () => void;
		onAcknowledgeAlert: (id: string) => void;
		width: number;
		class?: string;
	}

	let {
		selectedEarthquakeId,
		selectedHazardId,
		selectedAlertId,
		onSelectEarthquake,
		onSelectHazard,
		onSelectAlert,
		onCloseEarthquake,
		onCloseHazard,
		onCloseAlert,
		onAcknowledgeAlert,
		width,
		class: className
	}: Props = $props();

	let activeTab = $state<PaneTab>(loadStoredTab(browser ? localStorage : null) ?? 'earthquakes');
	let now = $state(Date.now());
	let toastMessage = $state<string | null>(null);
	let toastTimer: ReturnType<typeof setTimeout> | undefined;

	const scrollMemory = new ScrollMemory();
	let earthquakeListEl = $state<HTMLUListElement | undefined>();
	let hazardListEl = $state<HTMLUListElement | undefined>();
	let alertListEl = $state<HTMLUListElement | undefined>();
	const pendingFocus: Partial<Record<PaneTab, string | null>> = {};

	let lastEarthquakeId: number | null = null;
	let lastHazardId: string | null = null;
	let lastAlertId: string | null = null;

	$effect(() => {
		const timer = setInterval(() => (now = Date.now()), 30000);
		return () => clearInterval(timer);
	});

	$effect(() => () => {
		if (toastTimer) clearTimeout(toastTimer);
	});

	const selectedEarthquake = $derived(
		selectedEarthquakeId !== null
			? (earthquakeStore.earthquakes.get(selectedEarthquakeId) ?? null)
			: null
	);
	const selectedHazard = $derived(
		selectedHazardId !== null ? (hazardStore.hazards.get(selectedHazardId) ?? null) : null
	);
	const selectedAlert = $derived(
		selectedAlertId !== null ? (alertStore.activeAlerts.get(selectedAlertId) ?? null) : null
	);

	const counts = $derived<Record<PaneTab, number>>({
		earthquakes: earthquakeStore.sorted.length,
		hazards: hazardStore.sorted.length,
		alerts: alertStore.sorted.length,
		feed: alertStore.sorted.length
	});

	// EMSC's CC BY 4.0 license requires attribution whenever its events are on
	// screen, not only when one is selected, so this covers the whole loaded set.
	const earthquakeSources = $derived.by((): DataSource[] => {
		const ids = new SvelteSet<string>();
		for (const earthquake of earthquakeStore.sorted) {
			for (const sourceId of earthquake.sources) ids.add(sourceId);
		}
		return [...ids]
			.map((id) => earthquakeStore.sources.get(id))
			.filter((source): source is DataSource => source !== undefined)
			.sort((a, b) => b.priority - a.priority);
	});

	// GDACS's public-domain terms request attribution whenever its hazards are
	// on screen, not only when one is selected, so this covers the whole loaded set.
	const hazardSources = $derived.by((): DataSource[] => {
		const ids = new SvelteSet<string>();
		for (const hazard of hazardStore.sorted) ids.add(hazard.source);
		return [...ids]
			.map((id) => hazardStore.sources.get(id))
			.filter((source): source is DataSource => source !== undefined)
			.sort((a, b) => b.priority - a.priority);
	});

	function sourceName(sourceId: string): string {
		return earthquakeStore.sources.get(sourceId)?.name ?? sourceId;
	}

	function memberLabel(member: EarthquakeMember): string {
		const magnitude = `${magnitudeLabel(member.magnitude)}${member.magnitude_type ? ` ${member.magnitude_type}` : ''}`;
		const misfit = member.misfit === null ? '' : ` (misfit ${member.misfit.toFixed(2)})`;
		return `${sourceName(member.source)} · ${magnitude} · ${member.matched_by}${misfit}`;
	}

	function levelLabel(level: AlertLevel): string {
		return level.charAt(0).toUpperCase() + level.slice(1);
	}

	function externalIdLabel(externalId: string): string {
		const separatorIndex = externalId.indexOf(':');
		if (separatorIndex === -1) return externalId;
		const key = externalId.slice(0, separatorIndex);
		const value = externalId.slice(separatorIndex + 1);
		return `${key.toUpperCase()}: ${value}`;
	}

	function toggleHazardType(type: HazardType): void {
		const types = new SvelteSet(hazardStore.filter.types);
		if (types.has(type)) types.delete(type);
		else types.add(type);
		hazardStore.setFilter({ types });
	}

	function toggleHazardLevel(level: AlertLevel): void {
		const levels = new SvelteSet(hazardStore.filter.levels);
		if (levels.has(level)) levels.delete(level);
		else levels.add(level);
		hazardStore.setFilter({ levels });
	}

	function setActiveTab(tab: PaneTab): void {
		activeTab = tab;
		storeTab(browser ? localStorage : null, tab);
	}

	function showToast(message: string): void {
		toastMessage = message;
		if (toastTimer) clearTimeout(toastTimer);
		toastTimer = setTimeout(() => {
			toastMessage = null;
		}, 2000);
	}

	function applySelectionSwitch(kind: SelectionKind): void {
		const current = untrack(() => activeTab);
		const { tab, switched } = resolveTabForSelection(current, kind);
		if (!switched) return;
		setActiveTab(tab);
		showToast(`Switched to ${PANE_TAB_LABELS[tab]}`);
	}

	// A map-marker click can land on a kind whose tab is not active; a row click
	// inside the already-active tab (or the alert-owning Feed tab) must not.
	$effect(() => {
		const eqId = selectedEarthquakeId;
		const hzId = selectedHazardId;
		const alId = selectedAlertId;
		const prevEq = lastEarthquakeId;
		const prevHz = lastHazardId;
		const prevAl = lastAlertId;
		lastEarthquakeId = eqId;
		lastHazardId = hzId;
		lastAlertId = alId;

		if (eqId !== null && eqId !== prevEq) applySelectionSwitch('earthquake');
		else if (hzId !== null && hzId !== prevHz) applySelectionSwitch('hazard');
		else if (alId !== null && alId !== prevAl) applySelectionSwitch('alert');
	});

	function openEarthquake(id: number): void {
		onSelectEarthquake(id);
	}
	function openHazard(id: string): void {
		onSelectHazard(id);
	}
	function openAlert(id: string): void {
		onSelectAlert(id);
	}

	function closeEarthquake(): void {
		pendingFocus.earthquakes = selectedEarthquakeId !== null ? String(selectedEarthquakeId) : null;
		onCloseEarthquake();
	}
	function closeHazard(): void {
		pendingFocus.hazards = selectedHazardId;
		onCloseHazard();
	}
	function closeAlert(): void {
		pendingFocus[activeTab] = selectedAlertId;
		onCloseAlert();
	}

	$effect(() => {
		if (selectedEarthquakeId !== null || !earthquakeListEl) return;
		earthquakeListEl.scrollTop = scrollMemory.recall('earthquakes');
		const focusId = pendingFocus.earthquakes;
		if (focusId) {
			earthquakeListEl.querySelector<HTMLElement>(`[data-row-id="${focusId}"]`)?.focus();
			pendingFocus.earthquakes = null;
		}
	});

	$effect(() => {
		if (selectedHazardId !== null || !hazardListEl) return;
		hazardListEl.scrollTop = scrollMemory.recall('hazards');
		const focusId = pendingFocus.hazards;
		if (focusId) {
			hazardListEl.querySelector<HTMLElement>(`[data-row-id="${focusId}"]`)?.focus();
			pendingFocus.hazards = null;
		}
	});

	$effect(() => {
		if (selectedAlertId !== null || !alertListEl) return;
		alertListEl.scrollTop = scrollMemory.recall('alerts');
		const focusId = pendingFocus.alerts;
		if (focusId) {
			alertListEl.querySelector<HTMLElement>(`[data-row-id="${focusId}"]`)?.focus();
			pendingFocus.alerts = null;
		}
	});

	const detailOpen = $derived(
		isDetailOpen(activeTab, {
			earthquakeId: selectedEarthquakeId,
			hazardId: selectedHazardId,
			alertId: selectedAlertId
		})
	);

	// A drill-in removes the row that had focus, so Escape can't rely on
	// bubbling through the pane; listen on window only while a detail is open.
	$effect(() => {
		if (!browser || !detailOpen) return;
		const handleEscape = (event: KeyboardEvent): void => {
			if (event.key !== 'Escape') return;
			const kind = closeKindForTab(activeTab);
			if (kind === 'earthquake') closeEarthquake();
			else if (kind === 'hazard') closeHazard();
			else closeAlert();
		};
		window.addEventListener('keydown', handleEscape);
		return () => window.removeEventListener('keydown', handleEscape);
	});
</script>

{#snippet alertDetail()}
	{#if selectedAlert}
		<DetailHeader title={selectedAlert.event} onback={closeAlert} />
		<div class="min-h-0 flex-1 overflow-y-auto">
			<DetailPanel
				alert={selectedAlert}
				onclose={closeAlert}
				onacknowledge={() => onAcknowledgeAlert(selectedAlert.id)}
				showHeader={false}
			/>
		</div>
	{/if}
{/snippet}

<div
	data-testid="side-panel"
	class="border-ink-2/30 bg-paper flex-col overflow-hidden border-l {className ?? ''}"
	style:width="{width}px"
>
	<TabBar active={activeTab} {counts} onselect={setActiveTab} />
	<div class="relative min-h-0 flex-1">
		{#if toastMessage}
			<div
				role="status"
				aria-live="polite"
				class="bg-ink text-paper pointer-events-none absolute inset-x-0 top-2 z-10 mx-auto w-fit rounded-full px-3 py-1 text-xs shadow"
			>
				{toastMessage}
			</div>
		{/if}

		{#if activeTab === 'earthquakes'}
			<div
				id="pane-panel-earthquakes"
				role="tabpanel"
				aria-labelledby="pane-tab-earthquakes"
				class="flex h-full min-h-0 flex-col"
			>
				{#if selectedEarthquake}
					<DetailHeader
						title={selectedEarthquake.place ?? selectedEarthquake.title ?? 'Unknown location'}
						onback={closeEarthquake}
					/>
					<div class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto px-3 py-3 text-sm">
						<p class="text-amber text-base font-semibold">
							{magnitudeLabel(selectedEarthquake.magnitude)}
						</p>
						<p class="tabular text-ink-2 text-xs">
							<time datetime={selectedEarthquake.occurred_at} title={selectedEarthquake.occurred_at}
								>{formatLocalDateTime(selectedEarthquake.occurred_at)}</time
							>
							· {selectedEarthquake.depth_km === null
								? 'Depth —'
								: `Depth ${selectedEarthquake.depth_km.toFixed(1)} km`}
						</p>
						<p class="tabular text-ink-2 text-xs">
							{selectedEarthquake.latitude.toFixed(3)}°, {selectedEarthquake.longitude.toFixed(3)}°
							· {selectedEarthquake.status ?? 'status unavailable'}
						</p>
						{#if selectedEarthquake.tsunami === 1}
							<p class="text-ink-2 text-xs">
								USGS tsunami screening flag; this is not a tsunami warning.
							</p>
						{/if}
						<ul class="flex flex-col gap-0.5">
							{#each selectedEarthquake.members as member (member.source + member.source_id)}
								<li class="text-ink-2 text-xs">{memberLabel(member)}</li>
							{/each}
						</ul>
						{#if selectedEarthquake.url}
							<a
								href={selectedEarthquake.url}
								target="_blank"
								rel="external noopener noreferrer"
								class="border-ink-2/30 hover:bg-shoal w-fit border px-2 py-1 text-xs"
								>{selectedEarthquake.preferred_source.toUpperCase()} event</a
							>
						{/if}
						<div data-testid="earthquake-event-sources" class="flex flex-col gap-0.5">
							{#each selectedEarthquake.sources as sourceId (sourceId)}
								{@const source = earthquakeStore.sources.get(sourceId)}
								{#if source}
									<a
										href={source.homepage}
										target="_blank"
										rel="external noopener noreferrer"
										class="text-ink-2 text-xs hover:underline">{source.attribution_text}</a
									>
								{/if}
							{/each}
						</div>
					</div>
				{:else}
					<div class="border-ink-2/30 shrink-0 border-b px-3 py-2">
						<div class="flex items-center justify-between gap-2">
							<h2 class="text-ink text-sm font-semibold">Earthquakes</h2>
							<SseStatusDot connected={earthquakeStore.connected} variant="feed" class="text-xs" />
						</div>
						<div class="mt-2 flex flex-col gap-1.5" aria-label="Earthquake filters">
							<div class="flex flex-wrap items-center gap-1.5">
								<span
									class="text-ink-2 w-20 shrink-0 text-[11px] font-medium tracking-wide uppercase"
									>Window</span
								>
								<FilterChip
									label="24h"
									pressed={earthquakeStore.filter.hours === 24}
									onclick={() => earthquakeStore.setFilter({ hours: 24 })}
								/>
								<FilterChip
									label="7d"
									pressed={earthquakeStore.filter.hours === 168}
									onclick={() => earthquakeStore.setFilter({ hours: 168 })}
								/>
							</div>
							<div class="flex flex-wrap items-center gap-1.5">
								<span
									class="text-ink-2 w-20 shrink-0 text-[11px] font-medium tracking-wide uppercase"
									>Magnitude</span
								>
								<FilterChip
									label="M2.5+"
									pressed={earthquakeStore.filter.minMagnitude === 2.5}
									onclick={() => earthquakeStore.setFilter({ minMagnitude: 2.5 })}
								/>
								<FilterChip
									label="All magnitudes"
									pressed={earthquakeStore.filter.minMagnitude === 'all'}
									onclick={() => earthquakeStore.setFilter({ minMagnitude: 'all' })}
								/>
							</div>
							<div class="flex flex-wrap items-center gap-1.5">
								<span
									class="text-ink-2 w-20 shrink-0 text-[11px] font-medium tracking-wide uppercase"
									>Type</span
								>
								<FilterChip
									label="Earthquakes only"
									pressed={earthquakeStore.filter.eventType === 'earthquake'}
									onclick={() => earthquakeStore.setFilter({ eventType: 'earthquake' })}
								/>
								<FilterChip
									label="All types"
									pressed={earthquakeStore.filter.eventType === 'all'}
									onclick={() => earthquakeStore.setFilter({ eventType: 'all' })}
								/>
							</div>
						</div>
					</div>
					{#if earthquakeStore.snapshotError}
						<div
							class="border-ink-2/30 flex items-center justify-between gap-2 border-b px-3 py-2 text-xs"
						>
							<span>{earthquakeStore.snapshotError}</span>
							<button
								type="button"
								onclick={() => earthquakeStore.retrySnapshot()}
								class="border-ink-2/30 shrink-0 border px-2 py-0.5">Retry</button
							>
						</div>
					{/if}
					<ul
						bind:this={earthquakeListEl}
						onscroll={(event) =>
							scrollMemory.remember('earthquakes', (event.currentTarget as HTMLElement).scrollTop)}
						class="min-h-0 flex-1 overflow-y-auto"
					>
						{#each earthquakeStore.sorted as earthquake (earthquake.id)}
							<ListRow
								testid="earthquake-feed-item"
								rowId={String(earthquake.id)}
								title={earthquake.place ?? earthquake.title ?? 'Unknown location'}
								meta={formatShortRelativeTime(earthquake.occurred_at, now)}
								subtitle={earthquake.event_type ?? 'event'}
								secondary={magnitudeLabel(earthquake.magnitude)}
								level={earthquakeSeverity(earthquake.magnitude)}
								onclick={() => openEarthquake(earthquake.id)}
							/>
						{:else}
							<li class="text-ink-2 px-3 py-4 text-sm">No events match these filters.</li>
						{/each}
					</ul>
				{/if}
				{#if earthquakeSources.length > 0}
					<footer
						data-testid="earthquake-attribution"
						class="border-ink-2/30 flex shrink-0 flex-col gap-0.5 border-t px-3 py-2"
					>
						{#each earthquakeSources as source (source.id)}
							<a
								href={source.homepage}
								target="_blank"
								rel="external noopener noreferrer"
								class="text-ink-2 text-xs hover:underline">{source.attribution_text}</a
							>
						{/each}
					</footer>
				{/if}
			</div>
		{/if}

		{#if activeTab === 'hazards'}
			<div
				id="pane-panel-hazards"
				role="tabpanel"
				aria-labelledby="pane-tab-hazards"
				class="flex h-full min-h-0 flex-col"
			>
				{#if selectedHazard}
					<DetailHeader title={selectedHazard.title} onback={closeHazard} />
					<div class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto px-3 py-3 text-sm">
						<p class="tabular text-ink-2 flex items-center gap-1 text-xs">
							<span
								class="inline-block h-2 w-2 rounded-full"
								style:background-color={ALERT_LEVEL_COLORS[selectedHazard.alert_level]}
								aria-hidden="true"
							></span>
							{HAZARD_TYPE_LABELS[selectedHazard.hazard_type]} · {levelLabel(
								selectedHazard.alert_level
							)}
							{#if selectedHazard.severity_label}
								· {selectedHazard.severity_label}
							{/if}
						</p>
						<p>{selectedHazard.description}</p>
						<p class="tabular text-ink-2 text-xs">
							Onset <time datetime={selectedHazard.onset_at} title={selectedHazard.onset_at}
								>{formatLocalDateTime(selectedHazard.onset_at)}</time
							>
							· Expires
							<time datetime={selectedHazard.expires_at} title={selectedHazard.expires_at}
								>{formatLocalDateTime(selectedHazard.expires_at)}</time
							>
						</p>
						<p class="tabular text-ink-2 text-xs">
							{selectedHazard.countries.join(', ') || 'Countries unknown'} · Episode {selectedHazard.episode_count}
						</p>
						{#if selectedHazard.external_ids.length > 0}
							<ul class="flex flex-col gap-0.5">
								{#each selectedHazard.external_ids as externalId (externalId)}
									<li class="text-ink-2 text-xs">{externalIdLabel(externalId)}</li>
								{/each}
							</ul>
						{/if}
						{#if selectedHazard.report_url}
							<a
								href={selectedHazard.report_url}
								target="_blank"
								rel="external noopener noreferrer"
								class="border-ink-2/30 hover:bg-shoal w-fit border px-2 py-1 text-xs"
								>GDACS report</a
							>
						{/if}
						{#if hazardStore.sources.get(selectedHazard.source)}
							{@const source = hazardStore.sources.get(selectedHazard.source)}
							<a
								href={source!.homepage}
								target="_blank"
								rel="external noopener noreferrer"
								class="text-ink-2 text-xs hover:underline">{source!.attribution_text}</a
							>
						{/if}
					</div>
				{:else}
					<div class="border-ink-2/30 shrink-0 border-b px-3 py-2">
						<div class="flex items-center justify-between gap-2">
							<h2 class="text-ink text-sm font-semibold">Hazards</h2>
							<SseStatusDot connected={hazardStore.connected} variant="feed" class="text-xs" />
						</div>
						<div class="mt-2 flex flex-col gap-1.5">
							<div class="flex flex-wrap items-center gap-1.5" aria-label="Hazard type filters">
								<span
									class="text-ink-2 w-14 shrink-0 text-[11px] font-medium tracking-wide uppercase"
									>Type</span
								>
								{#each HAZARD_TYPES as type (type)}
									<FilterChip
										label={HAZARD_TYPE_LABELS[type]}
										pressed={hazardStore.filter.types.has(type)}
										onclick={() => toggleHazardType(type)}
									/>
								{/each}
							</div>
							<div class="flex flex-wrap items-center gap-1.5" aria-label="Alert level filters">
								<span
									class="text-ink-2 w-14 shrink-0 text-[11px] font-medium tracking-wide uppercase"
									>Level</span
								>
								{#each ALERT_LEVELS as level (level)}
									<FilterChip
										label={levelLabel(level)}
										pressed={hazardStore.filter.levels.has(level)}
										dotColor={ALERT_LEVEL_COLORS[level]}
										onclick={() => toggleHazardLevel(level)}
									/>
								{/each}
							</div>
						</div>
					</div>
					{#if hazardStore.snapshotError}
						<div
							class="border-ink-2/30 flex items-center justify-between gap-2 border-b px-3 py-2 text-xs"
						>
							<span>{hazardStore.snapshotError}</span>
							<button
								type="button"
								onclick={() => hazardStore.retrySnapshot()}
								class="border-ink-2/30 shrink-0 border px-2 py-0.5">Retry</button
							>
						</div>
					{/if}
					<ul
						bind:this={hazardListEl}
						onscroll={(event) =>
							scrollMemory.remember('hazards', (event.currentTarget as HTMLElement).scrollTop)}
						class="min-h-0 flex-1 overflow-y-auto"
					>
						{#each hazardStore.sorted as hazard (hazard.id)}
							<ListRow
								testid="hazard-feed-item"
								rowId={hazard.id}
								title={hazard.title}
								meta={formatShortRelativeTime(hazard.modified_at, now)}
								subtitle={HAZARD_TYPE_LABELS[hazard.hazard_type]}
								secondary={hazard.severity_label ?? undefined}
								level={hazard.alert_level}
								onclick={() => openHazard(hazard.id)}
							/>
						{:else}
							<li class="text-ink-2 px-3 py-4 text-sm">No hazards match these filters.</li>
						{/each}
					</ul>
				{/if}
				{#if hazardSources.length > 0}
					<footer
						data-testid="hazard-attribution"
						class="border-ink-2/30 flex shrink-0 flex-col gap-0.5 border-t px-3 py-2"
					>
						{#each hazardSources as source (source.id)}
							<a
								href={source.homepage}
								target="_blank"
								rel="external noopener noreferrer"
								class="text-ink-2 text-xs hover:underline">{source.attribution_text}</a
							>
						{/each}
					</footer>
				{/if}
			</div>
		{/if}

		{#if activeTab === 'alerts'}
			<div
				id="pane-panel-alerts"
				role="tabpanel"
				aria-labelledby="pane-tab-alerts"
				class="flex h-full min-h-0 flex-col"
			>
				{#if selectedAlert}
					{@render alertDetail()}
				{:else}
					<div
						class="border-ink-2/30 flex shrink-0 items-center justify-between gap-2 border-b px-3 py-2"
					>
						<h2 class="text-ink text-sm font-semibold">Alerts</h2>
						<SseStatusDot connected={alertStore.connected} variant="feed" class="text-xs" />
					</div>
					{#if alertStore.snapshotError}
						<div
							class="border-ink-2/30 flex items-center justify-between gap-2 border-b px-3 py-2 text-xs"
						>
							<span>{alertStore.snapshotError}</span>
							<button
								type="button"
								onclick={() => alertStore.retrySnapshot()}
								class="border-ink-2/30 shrink-0 border px-2 py-0.5">Retry</button
							>
						</div>
					{/if}
					<ul
						bind:this={alertListEl}
						onscroll={(event) =>
							scrollMemory.remember('alerts', (event.currentTarget as HTMLElement).scrollTop)}
						class="min-h-0 flex-1 overflow-y-auto"
					>
						{#each alertStore.sorted as alert (alert.id)}
							<ListRow
								testid="alert-feed-item"
								rowId={alert.id}
								title={alert.event}
								meta={alert.sent ? formatShortRelativeTime(alert.sent, now) : '—'}
								subtitle={alert.severity}
								secondary={alert.area_desc}
								level={alertSeverityLevel(alert.severity)}
								onclick={() => openAlert(alert.id)}
							/>
						{:else}
							<li class="text-ink-2 px-3 py-4 text-sm">No active NWS alerts</li>
						{/each}
					</ul>
				{/if}
			</div>
		{/if}

		{#if activeTab === 'feed'}
			<div
				id="pane-panel-feed"
				role="tabpanel"
				aria-labelledby="pane-tab-feed"
				class="flex h-full min-h-0 flex-col"
			>
				{#if selectedAlert}
					{@render alertDetail()}
				{:else}
					<FeedPanel selectedId={selectedAlertId} onselect={openAlert} />
				{/if}
			</div>
		{/if}
	</div>
</div>
