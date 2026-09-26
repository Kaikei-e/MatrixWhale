<script lang="ts">
	import { untrack } from 'svelte';
	import { SvelteSet } from 'svelte/reactivity';
	import { browser } from '$app/environment';
	import { earthquakeStore } from '$lib/earthquakes/store.svelte';
	import type { DataSource, Earthquake, EarthquakeMember } from '$lib/earthquakes/types';
	import { hazardStore } from '$lib/hazards/store.svelte';
	import {
		ALERT_LEVELS,
		ALERT_LEVEL_COLORS,
		HAZARD_TYPES,
		HAZARD_TYPE_LABELS,
		OBSERVED_EXTREME_SUBTYPES,
		OBSERVED_EXTREME_SUBTYPE_LABELS,
		type AlertLevel,
		type Hazard,
		type HazardType,
		type ObservedExtremeSubtype
	} from '$lib/hazards/types';
	import {
		formatAlertSourceBadge,
		formatLatLon,
		formatMaxWind,
		formatMslp,
		formatMslpWithUnit,
		formatObservedExtremeSubtype,
		formatWindRadiiSummary,
		observedExtremeColor,
		OBSERVED_EXTREME_COLORS
	} from '$lib/hazards/wis2';
	import { alertStore } from '$lib/alerts/store.svelte';
	import { SEVERITIES, type Alert } from '$lib/alerts/types';
	import { getCountryName } from '$lib/alerts/countries';
	import { summarizeAlertSources } from '$lib/alerts/attribution';
	import { formatCompactDateTime, formatLocalDateTime } from '$lib/alerts/timeFormat';
	import { timelineStore } from '$lib/timeline/store.svelte';
	import type {
		AlertTimelineItem,
		EarthquakeTimelineItem,
		HazardTimelineItem
	} from '$lib/timeline/types';
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
		alertSeverityDotColor
	} from '$lib/pane/format';
	import { themeState } from '$lib/theme.svelte';
	import { ScrollMemory } from '$lib/pane/scroll';
	import TabBar from './TabBar.svelte';
	import FilterChip from './FilterChip.svelte';
	import ListRow from './ListRow.svelte';
	import DetailHeader from './DetailHeader.svelte';
	import TimelineList from './TimelineList.svelte';
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

	const expandedForecastRows = new SvelteSet<string>();

	function toggleForecastRow(rowKey: string) {
		if (expandedForecastRows.has(rowKey)) {
			expandedForecastRows.delete(rowKey);
		} else {
			expandedForecastRows.add(rowKey);
		}
	}

	const scrollMemory = new ScrollMemory();
	let earthquakeListEl = $state<HTMLUListElement | undefined>();
	let hazardListEl = $state<HTMLUListElement | undefined>();
	let alertListEl = $state<HTMLUListElement | undefined>();
	let timelineListEl = $state<HTMLUListElement | undefined>();
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

	let lastSelectedAlert = $state.raw<Alert | null>(null);

	$effect(() => {
		if (selectedAlertId === null) {
			lastSelectedAlert = null;
			return;
		}
		const live = alertStore.activeAlerts.get(selectedAlertId);
		if (live) {
			lastSelectedAlert = live;
		}
	});

	$effect(() => {
		return alertStore.subscribeRaw((event) => {
			if (event.type === 'ended' && event.record.id === selectedAlertId) {
				lastSelectedAlert = event.record;
			}
		});
	});

	const selectedAlert = $derived(
		selectedAlertId !== null
			? (alertStore.activeAlerts.get(selectedAlertId) ??
					(lastSelectedAlert?.id === selectedAlertId ? lastSelectedAlert : null))
			: null
	);

	const counts = $derived<Record<PaneTab, number>>({
		timeline: timelineStore.items.length + timelineStore.pending.length,
		earthquakes: earthquakeStore.sorted.length,
		hazards: hazardStore.sorted.length,
		alerts: alertStore.filtered.length,
		feed: alertStore.filtered.length
	});

	const alertSourcesSummary = $derived(summarizeAlertSources(alertStore.filtered, 3));

	function alertCountryAuthority(alert: Alert): string {
		const countryNames = alert.countries.map((c) => getCountryName(c)).filter(Boolean);
		const country = countryNames.length > 0 ? countryNames.join(', ') : '';
		const badge = formatAlertSourceBadge(alert.source, alert.source_name);
		if (country && badge) return `${country} · ${badge}`;
		return country || badge || alert.source;
	}

	const JMA_DEFAULT_SOURCE: DataSource = {
		id: 'jma',
		name: '気象庁',
		homepage: 'https://www.jma.go.jp/jma/kishou/info/coment.html',
		license: '公共データ利用規約（第1.0版）',
		attribution_text: '気象庁防災情報XMLをもとにMatrixWhaleが加工。編集責任：MatrixWhale。',
		redistributable: true,
		priority: 95
	};

	// EMSC's CC BY 4.0 license requires attribution whenever its events are on
	// screen, not only when one is selected, so this covers the whole loaded set.
	const earthquakeSources = $derived.by((): DataSource[] => {
		const ids = new SvelteSet<string>();
		for (const earthquake of earthquakeStore.sorted) {
			for (const sourceId of earthquake.sources) ids.add(sourceId);
		}
		return [...ids]
			.map(
				(id) => earthquakeStore.sources.get(id) ?? (id === 'jma' ? JMA_DEFAULT_SOURCE : undefined)
			)
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
		return (
			earthquakeStore.sources.get(sourceId)?.name ??
			(sourceId === 'jma' ? JMA_DEFAULT_SOURCE.name : sourceId)
		);
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

	function toggleHazardSubtype(subtype: ObservedExtremeSubtype): void {
		const currentSubtypes = hazardStore.filter.subtypes ?? new Set(OBSERVED_EXTREME_SUBTYPES);
		const subtypes = new SvelteSet(currentSubtypes);
		if (subtypes.has(subtype)) subtypes.delete(subtype);
		else subtypes.add(subtype);
		hazardStore.setFilter({ subtypes });
	}

	function toggleHideUnconfirmed(): void {
		hazardStore.setFilter({ hideUnconfirmed: !hazardStore.filter.hideUnconfirmed });
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

	// Rows in the unified timeline are keyed as "<kind>:<id>", not the raw id the
	// per-kind tabs use, so the remembered focus target must match whichever
	// list is about to reappear.
	function closeEarthquake(): void {
		const id = selectedEarthquakeId !== null ? String(selectedEarthquakeId) : null;
		pendingFocus[activeTab] = activeTab === 'timeline' && id !== null ? `earthquake:${id}` : id;
		onCloseEarthquake();
	}
	function closeHazard(): void {
		pendingFocus[activeTab] =
			activeTab === 'timeline' && selectedHazardId !== null
				? `hazard:${selectedHazardId}`
				: selectedHazardId;
		onCloseHazard();
	}
	function closeAlert(): void {
		lastSelectedAlert = null;
		pendingFocus[activeTab] =
			activeTab === 'timeline' && selectedAlertId !== null
				? `alert:${selectedAlertId}`
				: selectedAlertId;
		onCloseAlert();
	}

	$effect(() => {
		if (selectedEarthquakeId !== null || !earthquakeListEl) return;
		earthquakeListEl.scrollTop = scrollMemory.recall('earthquakes');
		const focusId = pendingFocus.earthquakes;
		if (focusId) {
			earthquakeListEl
				.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(focusId)}"]`)
				?.focus();
			pendingFocus.earthquakes = null;
		}
	});

	$effect(() => {
		if (selectedHazardId !== null || !hazardListEl) return;
		hazardListEl.scrollTop = scrollMemory.recall('hazards');
		const focusId = pendingFocus.hazards;
		if (focusId) {
			hazardListEl.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(focusId)}"]`)?.focus();
			pendingFocus.hazards = null;
		}
	});

	$effect(() => {
		if (selectedAlertId !== null || !alertListEl) return;
		alertListEl.scrollTop = scrollMemory.recall('alerts');
		const focusId = pendingFocus.alerts;
		if (focusId) {
			alertListEl.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(focusId)}"]`)?.focus();
			pendingFocus.alerts = null;
		}
	});

	const selection = $derived({
		earthquakeId: selectedEarthquakeId,
		hazardId: selectedHazardId,
		alertId: selectedAlertId
	});

	const detailOpen = $derived(isDetailOpen(activeTab, selection));
	// The timeline tab can show any of the three kinds; this is both which
	// detail it renders and which one Escape/back closes, kept in sync by
	// construction since both read the same closeKindForTab priority.
	const timelineDetailOpen = $derived(isDetailOpen('timeline', selection));
	const timelineDetailKind = $derived(closeKindForTab('timeline', selection));

	// The record embedded in a timeline row survives eviction from the live
	// per-kind stores (7-day earthquake retention, ended alerts, non-current
	// hazards), so a drill-in from the timeline tab prefers it and only falls
	// back to the live store for an id the timeline hasn't loaded yet.
	const timelineSelectedEarthquake = $derived.by(() => {
		if (selectedEarthquakeId === null) return null;
		const key = `earthquake:${selectedEarthquakeId}`;
		const item = [...timelineStore.items, ...timelineStore.pending].find(
			(candidate): candidate is EarthquakeTimelineItem =>
				candidate.kind === 'earthquake' && candidate.key === key
		);
		return item?.earthquake ?? selectedEarthquake;
	});
	const timelineSelectedHazard = $derived.by(() => {
		if (selectedHazardId === null) return null;
		const key = `hazard:${selectedHazardId}`;
		const item = [...timelineStore.items, ...timelineStore.pending].find(
			(candidate): candidate is HazardTimelineItem =>
				candidate.kind === 'hazard' && candidate.key === key
		);
		return item?.hazard ?? selectedHazard;
	});
	const timelineSelectedAlert = $derived.by(() => {
		if (selectedAlertId === null) return null;
		const key = `alert:${selectedAlertId}`;
		const item = [...timelineStore.items, ...timelineStore.pending].find(
			(candidate): candidate is AlertTimelineItem =>
				candidate.kind === 'alert' && candidate.key === key
		);
		return item?.alert ?? selectedAlert;
	});

	$effect(() => {
		if (timelineDetailOpen || !timelineListEl) return;
		timelineListEl.scrollTop = scrollMemory.recall('timeline');
		const focusId = pendingFocus.timeline;
		if (focusId) {
			timelineListEl.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(focusId)}"]`)?.focus();
			pendingFocus.timeline = null;
		}
	});

	$effect(() => {
		if (!timelineListEl) return;
		const list = timelineListEl;
		const handleScroll = (event: Event): void => {
			scrollMemory.remember('timeline', (event.currentTarget as HTMLElement).scrollTop);
		};
		list.addEventListener('scroll', handleScroll);
		return () => list.removeEventListener('scroll', handleScroll);
	});

	// A drill-in removes the row that had focus, so Escape can't rely on
	// bubbling through the pane; listen on window only while a detail is open.
	$effect(() => {
		if (!browser || !detailOpen) return;
		const handleEscape = (event: KeyboardEvent): void => {
			if (event.key !== 'Escape') return;
			const kind = closeKindForTab(activeTab, selection);
			if (kind === 'earthquake') closeEarthquake();
			else if (kind === 'hazard') closeHazard();
			else closeAlert();
		};
		window.addEventListener('keydown', handleEscape);
		return () => window.removeEventListener('keydown', handleEscape);
	});
</script>

{#snippet earthquakeDetail(earthquake: Earthquake)}
	<DetailHeader
		title={earthquake.place ?? earthquake.title ?? 'Unknown location'}
		onback={closeEarthquake}
	/>
	<div class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto px-3 py-3 text-sm">
		<p class="text-amber text-base font-semibold">
			{magnitudeLabel(earthquake.magnitude)}
		</p>
		<p class="tabular text-ink-2 text-xs">
			<time datetime={earthquake.occurred_at} title={earthquake.occurred_at}
				>{formatLocalDateTime(earthquake.occurred_at)}</time
			>
			· {earthquake.depth_km === null ? 'Depth —' : `Depth ${earthquake.depth_km.toFixed(1)} km`}
		</p>
		<p class="tabular text-ink-2 text-xs">
			{earthquake.latitude.toFixed(3)}°, {earthquake.longitude.toFixed(3)}° · {earthquake.status ??
				'status unavailable'}
		</p>
		{#if earthquake.tsunami === 1}
			<p class="text-ink-2 text-xs">USGS tsunami screening flag; this is not a tsunami warning.</p>
		{/if}
		<ul class="flex flex-col gap-0.5">
			{#each earthquake.members as member (member.source + member.source_id)}
				<li class="text-ink-2 text-xs">{memberLabel(member)}</li>
			{/each}
		</ul>
		{#if earthquake.url}
			<a
				href={earthquake.url}
				target="_blank"
				rel="external noopener noreferrer"
				class="border-ink-2/30 hover:bg-shoal w-fit border px-2 py-1 text-xs"
				>{earthquake.preferred_source.toUpperCase()} event</a
			>
		{/if}
		<div data-testid="earthquake-event-sources" class="flex flex-col gap-0.5">
			{#each earthquake.sources as sourceId (sourceId)}
				{@const source =
					earthquakeStore.sources.get(sourceId) ??
					(sourceId === 'jma' ? JMA_DEFAULT_SOURCE : undefined)}
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
{/snippet}

{#snippet hazardDetail(hazard: Hazard)}
	<DetailHeader title={hazard.title} onback={closeHazard} />
	<div class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto px-3 py-3 text-sm">
		<p class="tabular text-ink-2 flex items-center gap-1 text-xs">
			<span
				class="inline-block h-2 w-2 rounded-full"
				style:background-color={hazard.hazard_type === 'observed_extreme'
					? observedExtremeColor(hazard.subtype)
					: ALERT_LEVEL_COLORS[hazard.alert_level]}
				aria-hidden="true"
			></span>
			{HAZARD_TYPE_LABELS[hazard.hazard_type]} · {levelLabel(hazard.alert_level)}
			{#if hazard.severity_label}
				· {hazard.severity_label}
			{/if}
		</p>
		{#if hazard.hazard_type === 'observed_extreme'}
			<div class="border-ink-2/20 bg-shoal/10 flex flex-col gap-1 rounded border p-2 text-xs">
				<div class="flex items-center gap-2">
					<span
						class="inline-block h-2.5 w-2.5 rounded-full"
						style:background-color={observedExtremeColor(hazard.subtype)}
						aria-hidden="true"
					></span>
					<span class="text-ink font-medium">
						{formatObservedExtremeSubtype(hazard.subtype)}
					</span>
					<span class="text-ink-2">·</span>
					<span class={hazard.confirmed ? 'text-ink font-medium' : 'text-ink-2'}>
						{hazard.confirmed ? 'Confirmed' : 'Unconfirmed'}
					</span>
				</div>
				{#if hazard.severity_value !== null}
					<p class="text-ink tabular text-xs font-medium">
						Observed value: {hazard.severity_value}
						{hazard.severity_unit ?? ''}
					</p>
				{/if}
			</div>
		{/if}
		{#if hazard.description}
			<p>{hazard.description}</p>
		{/if}
		<p class="tabular text-ink-2 text-xs">
			Onset <time datetime={hazard.onset_at} title={hazard.onset_at}
				>{formatLocalDateTime(hazard.onset_at)}</time
			>
			· Through
			<time datetime={hazard.expires_at} title={hazard.expires_at}
				>{formatLocalDateTime(hazard.expires_at)}</time
			>
		</p>
		<p class="tabular text-ink-2 text-xs">
			{hazard.countries.join(', ') || 'Countries unknown'} · Episode {hazard.episode_count}
		</p>
		{#if hazard.external_ids.length > 0}
			<ul class="flex flex-col gap-0.5">
				{#each hazard.external_ids as externalId (externalId)}
					<li class="text-ink-2 text-xs">{externalIdLabel(externalId)}</li>
				{/each}
			</ul>
		{/if}
		{#if hazard.report_url}
			<a
				href={hazard.report_url}
				target="_blank"
				rel="external noopener noreferrer"
				class="border-ink-2/30 hover:bg-shoal w-fit border px-2 py-1 text-xs">GDACS report</a
			>
		{/if}
		{#if hazardStore.sources.get(hazard.source)}
			{@const source = hazardStore.sources.get(hazard.source)}
			<a
				href={source!.homepage}
				target="_blank"
				rel="external noopener noreferrer"
				class="text-ink-2 text-xs hover:underline">{source!.attribution_text}</a
			>
		{/if}
		{#if hazardStore.details.get(hazard.id)?.forecast_tracks && hazardStore.details.get(hazard.id)!.forecast_tracks!.length > 0}
			{@const detail = hazardStore.details.get(hazard.id)!}
			<div
				class="border-ink-2/30 mt-2 flex flex-col gap-2.5 border-t pt-3"
				data-testid="tc-forecast-tracks"
			>
				<h3 class="text-ink text-xs font-semibold tracking-wide uppercase">Model forecast</h3>
				{#each detail.forecast_tracks as track (track.centre_id + track.analysis_time)}
					<div class="border-ink-2/20 bg-shoal/10 flex flex-col gap-1.5 rounded border p-2 text-xs">
						<div class="flex items-center justify-between gap-2">
							<span class="text-ink font-semibold">{track.centre_id}</span>
							{#if track.storm_name}
								<span class="text-ink-2">{track.storm_name} ({track.storm_id})</span>
							{:else}
								<span class="text-ink-2">{track.storm_id}</span>
							{/if}
						</div>
						<p class="tabular text-ink-2 text-[11px]">
							Analysis: <time datetime={track.analysis_time}
								>{formatLocalDateTime(track.analysis_time)}</time
							>
						</p>
						<div class="overflow-x-auto">
							<table
								class="tabular w-full border-collapse text-left text-[11px]"
								data-testid="forecast-track-table"
							>
								<thead>
									<tr class="border-ink-2/20 text-ink-2 border-b">
										<th class="py-1 pr-1 font-medium">Lead h</th>
										<th class="px-1 py-1 font-medium">Time</th>
										<th class="px-1 py-1 font-medium">Lat/Lon</th>
										<th class="px-1 py-1 text-right font-medium">MSLP hPa</th>
										<th class="py-1 pl-1 text-right font-medium">Max wind</th>
									</tr>
								</thead>
								<tbody class="divide-ink-2/10 divide-y">
									{#each track.points as point (point.lead_hours)}
										{@const rowKey = `${track.centre_id}-${point.lead_hours}`}
										{@const radiiSummary = formatWindRadiiSummary(point.wind_radii)}
										{@const hasRadii = radiiSummary !== '—'}
										{@const isExpanded = expandedForecastRows.has(rowKey)}
										<tr
											class="hover:bg-shoal/30 {hasRadii ? 'cursor-pointer' : ''}"
											onclick={hasRadii ? () => toggleForecastRow(rowKey) : undefined}
											title={hasRadii ? `Wind radii: ${radiiSummary}` : undefined}
										>
											<td class="py-1 pr-1 font-medium whitespace-nowrap">
												+{point.lead_hours}h{#if hasRadii}<span
													class="text-ink-2/60 ml-0.5 text-[9px]"
													aria-hidden="true">{isExpanded ? '▾' : '▸'}</span
												>{/if}
											</td>
											<td class="px-1 py-1 whitespace-nowrap">
												<time datetime={point.time} title={formatLocalDateTime(point.time)}>
													{formatCompactDateTime(point.time)}
												</time>
											</td>
											<td class="px-1 py-1 whitespace-nowrap">
												<span title="{point.lat.toFixed(2)}°, {point.lon.toFixed(2)}°">
													{formatLatLon(point.lat, point.lon)}
												</span>
											</td>
											<td class="px-1 py-1 text-right whitespace-nowrap">
												<span title={formatMslpWithUnit(point.mslp_pa)}>
													{formatMslp(point.mslp_pa)}
												</span>
											</td>
											<td class="py-1 pl-1 text-right whitespace-nowrap">
												<span
													title={point.max_wind_ms !== null
														? `${point.max_wind_ms.toFixed(1)} m/s`
														: undefined}
												>
													{formatMaxWind(point.max_wind_ms)}
												</span>
											</td>
										</tr>
										{#if isExpanded && hasRadii}
											<tr
												class="bg-shoal/20 hover:bg-shoal/30 text-ink-2 cursor-pointer text-[10px]"
												onclick={() => toggleForecastRow(rowKey)}
												title="Click to collapse"
											>
												<td colspan="5" class="px-2 py-1">
													<span class="text-ink font-medium">Radii (km):</span>
													{radiiSummary}
												</td>
											</tr>
										{/if}
									{/each}
								</tbody>
							</table>
						</div>
					</div>
				{/each}
			</div>
		{/if}
	</div>
{/snippet}

{#snippet alertDetail(alert: Alert)}
	<DetailHeader title={alert.headline || alert.event} onback={closeAlert} />
	<div class="min-h-0 flex-1 overflow-y-auto">
		<DetailPanel
			{alert}
			onclose={closeAlert}
			onacknowledge={() => onAcknowledgeAlert(alert.id)}
			showHeader={false}
		/>
	</div>
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

		{#if activeTab === 'timeline'}
			<div
				id="pane-panel-timeline"
				role="tabpanel"
				aria-labelledby="pane-tab-timeline"
				class="flex h-full min-h-0 flex-col"
			>
				{#if timelineDetailOpen}
					{#if timelineDetailKind === 'earthquake' && timelineSelectedEarthquake}
						{@render earthquakeDetail(timelineSelectedEarthquake)}
					{:else if timelineDetailKind === 'hazard' && timelineSelectedHazard}
						{@render hazardDetail(timelineSelectedHazard)}
					{:else if timelineDetailKind === 'alert' && timelineSelectedAlert}
						{@render alertDetail(timelineSelectedAlert)}
					{/if}
				{:else}
					<TimelineList
						bind:listEl={timelineListEl}
						{now}
						onSelectEarthquake={openEarthquake}
						onSelectHazard={openHazard}
						onSelectAlert={openAlert}
					/>
				{/if}
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
					{@render earthquakeDetail(selectedEarthquake)}
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
					{@render hazardDetail(selectedHazard)}
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
							<div class="flex flex-wrap items-center gap-1.5" aria-label="Subtype filters">
								<span
									class="text-ink-2 w-14 shrink-0 text-[11px] font-medium tracking-wide uppercase"
									>Subtype</span
								>
								{#each OBSERVED_EXTREME_SUBTYPES as subtype (subtype)}
									<FilterChip
										label={OBSERVED_EXTREME_SUBTYPE_LABELS[subtype]}
										pressed={(
											hazardStore.filter.subtypes ?? new Set(OBSERVED_EXTREME_SUBTYPES)
										).has(subtype)}
										dotColor={OBSERVED_EXTREME_COLORS[subtype]}
										onclick={() => toggleHazardSubtype(subtype)}
										testid="hazard-subtype-chip-{subtype}"
									/>
								{/each}
							</div>
							<div class="flex items-center gap-2 pt-0.5">
								<label class="text-ink-2 flex cursor-pointer items-center gap-1.5 text-xs">
									<input
										type="checkbox"
										data-testid="hide-unconfirmed-checkbox"
										checked={hazardStore.filter.hideUnconfirmed ?? false}
										onchange={toggleHideUnconfirmed}
										class="border-ink-2/30 rounded"
									/>
									<span>Hide unconfirmed</span>
								</label>
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
								subtitle={hazard.hazard_type === 'observed_extreme' && hazard.subtype
									? `Observed Extreme · ${formatObservedExtremeSubtype(hazard.subtype)}`
									: HAZARD_TYPE_LABELS[hazard.hazard_type]}
								secondary={hazard.hazard_type === 'observed_extreme'
									? hazard.confirmed
										? 'Confirmed'
										: 'Unconfirmed'
									: (hazard.severity_label ?? undefined)}
								level={hazard.hazard_type !== 'observed_extreme' ? hazard.alert_level : undefined}
								kindColor={hazard.hazard_type === 'observed_extreme'
									? observedExtremeColor(hazard.subtype)
									: undefined}
								kindLabel={hazard.hazard_type === 'observed_extreme'
									? (hazard.subtype ?? 'Observed Extreme')
									: undefined}
								ended={hazard.hazard_type === 'observed_extreme' && !hazard.confirmed}
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
					{@render alertDetail(selectedAlert)}
				{:else}
					<div class="border-ink-2/30 shrink-0 border-b px-3 py-2">
						<div class="flex items-center justify-between gap-2">
							<h2 class="text-ink text-sm font-semibold">Alerts</h2>
							<SseStatusDot connected={alertStore.connected} variant="feed" class="text-xs" />
						</div>
						<div class="mt-2 flex flex-col gap-1.5" aria-label="Alert filters">
							<div class="flex flex-wrap items-center gap-1.5" aria-label="Severity filters">
								<span
									class="text-ink-2 w-16 shrink-0 text-[11px] font-medium tracking-wide uppercase"
									>Severity</span
								>
								{#each SEVERITIES as severity (severity)}
									<FilterChip
										label={severity}
										pressed={alertStore.severityFilter.has(severity)}
										onclick={() => alertStore.toggleSeverity(severity)}
									/>
								{/each}
							</div>
							<div class="flex items-center gap-1.5" aria-label="Country filter">
								<label
									for="alert-country-select"
									class="text-ink-2 w-16 shrink-0 text-[11px] font-medium tracking-wide uppercase"
									>Country</label
								>
								<select
									id="alert-country-select"
									bind:value={alertStore.countryFilter}
									class="border-ink-2/30 bg-paper text-ink max-w-[240px] truncate border px-2 py-1 text-xs"
									aria-label="Filter by country"
								>
									<option value="all">All countries</option>
									{#each alertStore.activeCountries as country (country.iso3)}
										<option value={country.iso3}>{country.name} ({country.count})</option>
									{/each}
								</select>
							</div>
						</div>
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
						{#each alertStore.displayFiltered as alert (alert.id)}
							<ListRow
								testid="alert-feed-item"
								rowId={alert.id}
								title={alert.headline || alert.event}
								meta={alert.sent ? formatShortRelativeTime(alert.sent, now) : '—'}
								subtitle={alertCountryAuthority(alert)}
								kindColor={alertSeverityDotColor(alert.severity, themeState.current)}
								kindLabel={alert.severity}
								onclick={() => openAlert(alert.id)}
							/>
						{:else}
							<li class="text-ink-2 px-3 py-4 text-sm">No active alerts match these filters.</li>
						{/each}
						{#if alertStore.filteredOverLimit}
							<li class="text-ink-2 px-3 py-2 text-xs">
								Showing {alertStore.displayFiltered.length} of {alertStore.filtered.length} alerts
							</li>
						{/if}
					</ul>
				{/if}
				{#if alertSourcesSummary.totalUnique > 0}
					<footer
						data-testid="alert-attribution"
						class="border-ink-2/30 text-ink-2 flex shrink-0 flex-col gap-0.5 border-t px-3 py-2 text-xs"
					>
						<div class="flex flex-wrap items-center gap-1">
							<span>Sources:</span>
							{#each alertSourcesSummary.visible as source, i (source.name)}
								{#if i > 0}<span>·</span>{/if}
								<span>{source.name}</span>
							{/each}
							{#if alertSourcesSummary.hiddenCount > 0}
								<span>+{alertSourcesSummary.hiddenCount} more</span>
							{/if}
						</div>
					</footer>
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
					{@render alertDetail(selectedAlert)}
				{:else}
					<FeedPanel selectedId={selectedAlertId} onselect={openAlert} />
				{/if}
			</div>
		{/if}
	</div>
</div>
