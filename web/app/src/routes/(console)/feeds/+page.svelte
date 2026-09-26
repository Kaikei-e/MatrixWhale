<script lang="ts">
	import { onMount } from 'svelte';
	import { SvelteSet } from 'svelte/reactivity';
	import {
		FEED_HEALTHS,
		type CapFeedsResponse,
		type FeedHealth,
		type FeedSortColumn
	} from '$lib/feeds/types';
	import {
		computeHealthCounts,
		filterFeeds,
		sortFeeds,
		formatFeedDisplayUrl,
		isHttpUrl
	} from '$lib/feeds/logic';
	import {
		computeTotalFailures,
		computeUnique24h,
		sortWis2Channels,
		type Wis2HealthResponse,
		type Wis2SortColumn
	} from '$lib/feeds/wis2';
	import { formatShortRelativeTime } from '$lib/pane/format';
	import { formatLocalDateTime } from '$lib/alerts/timeFormat';
	import FilterChip from '$lib/components/pane/FilterChip.svelte';

	let loading = $state(true);
	let error = $state<string | null>(null);
	let data = $state<CapFeedsResponse | null>(null);
	let now = $state(Date.now());

	let searchQuery = $state('');
	// Default: all healths EXCEPT 'excluded'
	let activeHealths = new SvelteSet<FeedHealth>([
		'ok',
		'empty',
		'stale',
		'degraded',
		'failing',
		'pending'
	]);

	let sortColumn = $state<FeedSortColumn>('health');
	let sortDirection = $state<'asc' | 'desc'>('asc');

	let wis2Loading = $state(true);
	let wis2Error = $state<string | null>(null);
	let wis2Data = $state<Wis2HealthResponse | null>(null);
	let wis2SortColumn = $state<Wis2SortColumn>('status');
	let wis2SortDirection = $state<'asc' | 'desc'>('asc');

	async function fetchFeeds(): Promise<void> {
		loading = true;
		error = null;
		try {
			const res = await fetch('/api/v1/cap/feeds');
			if (!res.ok) throw new Error(`Feeds request failed with status ${res.status}`);
			data = (await res.json()) as CapFeedsResponse;
			error = null;
		} catch (err) {
			error = err instanceof Error ? err.message : 'Failed to load feeds';
		} finally {
			loading = false;
		}
	}

	async function fetchWis2(): Promise<void> {
		wis2Loading = true;
		wis2Error = null;
		try {
			const res = await fetch('/api/v1/wis2/health');
			if (!res.ok) throw new Error(`WIS2 health request failed with status ${res.status}`);
			wis2Data = (await res.json()) as Wis2HealthResponse;
			wis2Error = null;
		} catch (err) {
			wis2Error = err instanceof Error ? err.message : 'Failed to load WIS2 health';
		} finally {
			wis2Loading = false;
		}
	}

	onMount(() => {
		void fetchFeeds();
		void fetchWis2();
		const timer = setInterval(() => (now = Date.now()), 30000);
		return () => clearInterval(timer);
	});

	function handleWis2Sort(col: Wis2SortColumn): void {
		if (wis2SortColumn === col) {
			wis2SortDirection = wis2SortDirection === 'asc' ? 'desc' : 'asc';
		} else {
			wis2SortColumn = col;
			wis2SortDirection =
				col === 'unique_24h' ||
				col === 'duplicates_24h' ||
				col === 'failures' ||
				col === 'last_received_at'
					? 'desc'
					: 'asc';
		}
	}

	const sortedWis2Channels = $derived(
		wis2Data ? sortWis2Channels(wis2Data.channels, wis2SortColumn, wis2SortDirection) : []
	);

	function toggleHealth(health: FeedHealth): void {
		if (activeHealths.has(health)) {
			activeHealths.delete(health);
		} else {
			activeHealths.add(health);
		}
	}

	function handleSort(col: FeedSortColumn): void {
		if (sortColumn === col) {
			sortDirection = sortDirection === 'asc' ? 'desc' : 'asc';
		} else {
			sortColumn = col;
			sortDirection =
				col === 'last_success' ||
				col === 'failures' ||
				col === 'items' ||
				col === 'newest_item' ||
				col === 'active_alerts'
					? 'desc'
					: 'asc';
		}
	}

	const allFeeds = $derived(data?.feeds ?? []);
	const healthCounts = $derived(data?.counts ?? computeHealthCounts(allFeeds));

	const filteredFeeds = $derived(filterFeeds(allFeeds, activeHealths, searchQuery));
	const displayedFeeds = $derived(sortFeeds(filteredFeeds, sortColumn, sortDirection));

	const HEALTH_BADGE_CLASSES: Record<FeedHealth, string> = {
		ok: 'bg-emerald-100 text-emerald-900 border-emerald-300 dark:bg-emerald-950 dark:text-emerald-200 dark:border-emerald-800',
		empty:
			'bg-slate-100 text-slate-800 border-slate-300 dark:bg-slate-800 dark:text-slate-200 dark:border-slate-700',
		stale:
			'bg-yellow-100 text-yellow-950 border-yellow-300 dark:bg-yellow-950 dark:text-yellow-200 dark:border-yellow-800',
		degraded:
			'bg-amber-100 text-amber-950 border-amber-300 dark:bg-amber-950 dark:text-amber-200 dark:border-amber-800',
		failing:
			'bg-rose-100 text-rose-950 border-rose-300 dark:bg-rose-950 dark:text-rose-200 dark:border-rose-800',
		pending:
			'bg-sky-100 text-sky-950 border-sky-300 dark:bg-sky-950 dark:text-sky-200 dark:border-sky-800',
		excluded:
			'bg-zinc-100 text-zinc-700 border-zinc-300 dark:bg-zinc-800 dark:text-zinc-300 dark:border-zinc-700'
	};

	function formatTime(iso: string | null | undefined): string {
		if (!iso) return '—';
		return formatShortRelativeTime(iso, now);
	}
</script>

<svelte:head>
	<title>Feed Health · MatrixWhale</title>
</svelte:head>

<main class="text-ink mx-auto flex h-full w-full max-w-7xl flex-col gap-4 overflow-y-auto p-6">
	<header class="border-ink-2/30 flex flex-wrap items-baseline justify-between gap-4 border-b pb-4">
		<div>
			<h1 class="text-2xl font-bold tracking-tight">CAP Feed Health</h1>
			<p class="text-ink-2 mt-1 text-sm">
				Operational health of national alerting authority feeds indexed from the WMO RAA registry.
			</p>
		</div>

		{#if data}
			<div class="tabular text-ink-2 flex flex-wrap gap-4 text-xs">
				{#if data.generated_at}
					<span>Generated: {formatLocalDateTime(data.generated_at)}</span>
				{/if}
				{#if data.registry_fetched_at}
					<span>Registry fetched: {formatLocalDateTime(data.registry_fetched_at)}</span>
				{:else}
					<span>Registry fetched: pending</span>
				{/if}
			</div>
		{/if}
	</header>

	<section class="flex flex-col gap-3">
		<div class="flex flex-wrap items-center justify-between gap-3">
			<div class="flex flex-wrap items-center gap-1.5" aria-label="Health filters">
				<span class="text-ink-2 mr-1 text-xs font-semibold tracking-wide uppercase">Health:</span>
				{#each FEED_HEALTHS as health (health)}
					<FilterChip
						label="{health} ({healthCounts[health] ?? 0})"
						pressed={activeHealths.has(health)}
						onclick={() => toggleHealth(health)}
						testid="feed-health-chip-{health}"
					/>
				{/each}
			</div>

			<div class="w-full sm:w-72">
				<label for="feed-search" class="sr-only">Search feeds</label>
				<input
					id="feed-search"
					data-testid="feed-search-input"
					type="search"
					bind:value={searchQuery}
					placeholder="Search country, authority, URL…"
					class="border-ink-2/30 bg-paper text-ink placeholder:text-ink-2 focus:border-ink w-full border px-3 py-1.5 text-xs focus:outline-none"
				/>
			</div>
		</div>
	</section>

	{#if loading}
		<div class="text-ink-2 py-12 text-center text-sm">Loading feeds…</div>
	{:else if error}
		<div class="text-ink-2 flex flex-col items-center justify-center gap-2 py-12 text-sm">
			<span>{error}</span>
			<button
				type="button"
				onclick={fetchFeeds}
				class="border-ink-2/30 text-ink hover:bg-shoal border px-3 py-1 text-xs"
			>
				Retry
			</button>
		</div>
	{:else if displayedFeeds.length === 0}
		<div class="text-ink-2 py-12 text-center text-sm">No feeds match the current filters.</div>
	{:else}
		<div class="border-ink-2/30 w-full overflow-x-auto border" data-testid="feeds-table-wrapper">
			<table class="tabular w-full table-fixed text-left text-xs" data-testid="feeds-table">
				<thead class="border-ink-2/30 bg-shoal/40 text-ink border-b">
					<tr>
						<th
							scope="col"
							data-testid="feed-th-health"
							class="hover:bg-shoal/80 w-24 cursor-pointer px-3 py-2.5 font-semibold select-none"
							aria-sort={sortColumn === 'health'
								? sortDirection === 'asc'
									? 'ascending'
									: 'descending'
								: 'none'}
							onclick={() => handleSort('health')}
						>
							<button type="button" class="flex items-center gap-1 font-semibold">
								Health
								{#if sortColumn === 'health'}
									<span aria-hidden="true">{sortDirection === 'asc' ? '▲' : '▼'}</span>
								{/if}
							</button>
						</th>
						<th
							scope="col"
							data-testid="feed-th-country"
							class="hover:bg-shoal/80 w-32 cursor-pointer px-3 py-2.5 font-semibold select-none"
							aria-sort={sortColumn === 'country'
								? sortDirection === 'asc'
									? 'ascending'
									: 'descending'
								: 'none'}
							onclick={() => handleSort('country')}
						>
							<button type="button" class="flex items-center gap-1 font-semibold">
								Country
								{#if sortColumn === 'country'}
									<span aria-hidden="true">{sortDirection === 'asc' ? '▲' : '▼'}</span>
								{/if}
							</button>
						</th>
						<th
							scope="col"
							data-testid="feed-th-authority"
							class="hover:bg-shoal/80 w-44 cursor-pointer px-3 py-2.5 font-semibold select-none"
							aria-sort={sortColumn === 'authority'
								? sortDirection === 'asc'
									? 'ascending'
									: 'descending'
								: 'none'}
							onclick={() => handleSort('authority')}
						>
							<button type="button" class="flex items-center gap-1 font-semibold">
								Authority
								{#if sortColumn === 'authority'}
									<span aria-hidden="true">{sortDirection === 'asc' ? '▲' : '▼'}</span>
								{/if}
							</button>
						</th>
						<th
							scope="col"
							data-testid="feed-th-url"
							class="hover:bg-shoal/80 w-48 cursor-pointer px-3 py-2.5 font-semibold select-none"
							aria-sort={sortColumn === 'url'
								? sortDirection === 'asc'
									? 'ascending'
									: 'descending'
								: 'none'}
							onclick={() => handleSort('url')}
						>
							<button type="button" class="flex items-center gap-1 font-semibold">
								URL
								{#if sortColumn === 'url'}
									<span aria-hidden="true">{sortDirection === 'asc' ? '▲' : '▼'}</span>
								{/if}
							</button>
						</th>
						<th
							scope="col"
							data-testid="feed-th-language"
							class="hover:bg-shoal/80 w-14 cursor-pointer px-2 py-2.5 font-semibold select-none"
							aria-sort={sortColumn === 'language'
								? sortDirection === 'asc'
									? 'ascending'
									: 'descending'
								: 'none'}
							onclick={() => handleSort('language')}
						>
							<button type="button" class="flex items-center gap-1 font-semibold">
								Lang
								{#if sortColumn === 'language'}
									<span aria-hidden="true">{sortDirection === 'asc' ? '▲' : '▼'}</span>
								{/if}
							</button>
						</th>
						<th
							scope="col"
							data-testid="feed-th-format"
							class="hover:bg-shoal/80 w-16 cursor-pointer px-2 py-2.5 font-semibold select-none"
							aria-sort={sortColumn === 'format'
								? sortDirection === 'asc'
									? 'ascending'
									: 'descending'
								: 'none'}
							onclick={() => handleSort('format')}
						>
							<button type="button" class="flex items-center gap-1 font-semibold">
								Format
								{#if sortColumn === 'format'}
									<span aria-hidden="true">{sortDirection === 'asc' ? '▲' : '▼'}</span>
								{/if}
							</button>
						</th>
						<th
							scope="col"
							data-testid="feed-th-last_success"
							class="hover:bg-shoal/80 w-28 cursor-pointer px-3 py-2.5 text-right font-semibold select-none"
							aria-sort={sortColumn === 'last_success'
								? sortDirection === 'asc'
									? 'ascending'
									: 'descending'
								: 'none'}
							onclick={() => handleSort('last_success')}
						>
							<button
								type="button"
								class="flex w-full items-center justify-end gap-1 font-semibold"
							>
								Last Success
								{#if sortColumn === 'last_success'}
									<span aria-hidden="true">{sortDirection === 'asc' ? '▲' : '▼'}</span>
								{/if}
							</button>
						</th>
						<th
							scope="col"
							data-testid="feed-th-failures"
							class="hover:bg-shoal/80 w-20 cursor-pointer px-3 py-2.5 text-right font-semibold select-none"
							aria-sort={sortColumn === 'failures'
								? sortDirection === 'asc'
									? 'ascending'
									: 'descending'
								: 'none'}
							onclick={() => handleSort('failures')}
						>
							<button
								type="button"
								class="flex w-full items-center justify-end gap-1 font-semibold"
							>
								Failures
								{#if sortColumn === 'failures'}
									<span aria-hidden="true">{sortDirection === 'asc' ? '▲' : '▼'}</span>
								{/if}
							</button>
						</th>
						<th
							scope="col"
							data-testid="feed-th-items"
							class="hover:bg-shoal/80 w-16 cursor-pointer px-3 py-2.5 text-right font-semibold select-none"
							aria-sort={sortColumn === 'items'
								? sortDirection === 'asc'
									? 'ascending'
									: 'descending'
								: 'none'}
							onclick={() => handleSort('items')}
						>
							<button
								type="button"
								class="flex w-full items-center justify-end gap-1 font-semibold"
							>
								Items
								{#if sortColumn === 'items'}
									<span aria-hidden="true">{sortDirection === 'asc' ? '▲' : '▼'}</span>
								{/if}
							</button>
						</th>
						<th
							scope="col"
							data-testid="feed-th-newest_item"
							class="hover:bg-shoal/80 w-28 cursor-pointer px-3 py-2.5 text-right font-semibold select-none"
							aria-sort={sortColumn === 'newest_item'
								? sortDirection === 'asc'
									? 'ascending'
									: 'descending'
								: 'none'}
							onclick={() => handleSort('newest_item')}
						>
							<button
								type="button"
								class="flex w-full items-center justify-end gap-1 font-semibold"
							>
								Newest
								{#if sortColumn === 'newest_item'}
									<span aria-hidden="true">{sortDirection === 'asc' ? '▲' : '▼'}</span>
								{/if}
							</button>
						</th>
						<th
							scope="col"
							data-testid="feed-th-active_alerts"
							class="hover:bg-shoal/80 w-20 cursor-pointer px-3 py-2.5 text-right font-semibold select-none"
							aria-sort={sortColumn === 'active_alerts'
								? sortDirection === 'asc'
									? 'ascending'
									: 'descending'
								: 'none'}
							onclick={() => handleSort('active_alerts')}
						>
							<button
								type="button"
								class="flex w-full items-center justify-end gap-1 font-semibold"
							>
								Alerts
								{#if sortColumn === 'active_alerts'}
									<span aria-hidden="true">{sortDirection === 'asc' ? '▲' : '▼'}</span>
								{/if}
							</button>
						</th>
					</tr>
				</thead>
				<tbody class="divide-ink-2/10 divide-y">
					{#each displayedFeeds as feed (feed.url)}
						{@const displayUrl = formatFeedDisplayUrl(feed.url)}
						<tr class="hover:bg-shoal/20" data-testid="feed-row">
							<td class="px-3 py-2 whitespace-nowrap">
								<span
									class="inline-flex items-center rounded border px-1.5 py-0.5 text-[11px] font-medium {HEALTH_BADGE_CLASSES[
										feed.health
									]}"
								>
									{feed.health}
								</span>
							</td>
							<td class="text-ink px-3 py-2 font-medium">
								<div
									class="truncate"
									title={feed.authority.country_name || feed.authority.country_iso3}
								>
									{feed.authority.country_name || feed.authority.country_iso3}
								</div>
							</td>
							<td class="text-ink px-3 py-2">
								<div class="truncate" title={feed.authority.name}>
									{feed.authority.name}
								</div>
							</td>
							<td class="px-3 py-2">
								<div class="truncate" title={feed.url}>
									{#if isHttpUrl(feed.url)}
										<a
											href={feed.url}
											target="_blank"
											rel="external noopener noreferrer"
											class="text-ink hover:underline"
										>
											<span class="font-medium">{displayUrl.host}</span>
											<span class="text-ink-2">{displayUrl.displayPath}</span>
										</a>
									{:else}
										<span class="font-medium">{displayUrl.host}</span>
										<span class="text-ink-2">{displayUrl.displayPath}</span>
									{/if}
								</div>
							</td>
							<td class="text-ink-2 px-2 py-2">{feed.language ?? '—'}</td>
							<td class="text-ink-2 px-2 py-2">{feed.format ?? '—'}</td>
							<td class="text-ink-2 px-3 py-2 text-right whitespace-nowrap">
								{formatTime(feed.last_success_at)}
							</td>
							<td
								class="px-3 py-2 text-right {feed.consecutive_failures > 0
									? 'text-amber font-medium'
									: 'text-ink-2'}"
							>
								{feed.consecutive_failures}
							</td>
							<td class="text-ink-2 px-3 py-2 text-right">
								{feed.item_count ?? '—'}
							</td>
							<td class="text-ink-2 px-3 py-2 text-right whitespace-nowrap">
								{formatTime(feed.newest_item_at)}
							</td>
							<td
								class="px-3 py-2 text-right font-medium {feed.active_alerts > 0
									? 'text-ink'
									: 'text-ink-2'}"
							>
								{feed.active_alerts}
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}

	<section class="mt-8 flex flex-col gap-4" data-testid="wis2-section">
		<header
			class="border-ink-2/30 flex flex-wrap items-baseline justify-between gap-4 border-b pb-3"
		>
			<div>
				<h2 class="text-xl font-bold tracking-tight">WIS2 Ingestion Health</h2>
				<p class="text-ink-2 mt-1 text-sm">
					Real-time status of WMO Information System 2.0 Global Broker subscription and channel
					ingestion metrics.
				</p>
			</div>

			{#if wis2Data?.broker}
				<div
					data-testid="wis2-broker-status"
					class="border-ink-2/30 bg-shoal/20 text-ink flex flex-wrap items-center gap-2 rounded border px-3 py-1.5 text-xs"
				>
					<span
						class="inline-block h-2 w-2 rounded-full {wis2Data.broker.connected
							? 'bg-emerald-500'
							: 'bg-rose-500'}"
						aria-hidden="true"
					></span>
					<span class="font-medium">
						{wis2Data.broker.connected ? 'Broker Connected' : 'Broker Disconnected'}
					</span>
					<span class="text-ink-2">·</span>
					<span class="text-ink-2 font-mono text-[11px]">{wis2Data.broker.url}</span>
					{#if wis2Data.broker.last_report_at}
						<span class="text-ink-2">·</span>
						<span class="tabular text-ink-2"
							>Reported {formatTime(wis2Data.broker.last_report_at)}</span
						>
					{/if}
					{#if wis2Data.broker.error}
						<span class="text-ink-2">·</span>
						<span class="font-medium text-rose-600 dark:text-rose-400">{wis2Data.broker.error}</span
						>
					{/if}
				</div>
			{/if}
		</header>

		{#if wis2Loading}
			<div class="text-ink-2 py-8 text-center text-sm">Loading WIS2 health…</div>
		{:else if wis2Error}
			<div class="text-ink-2 flex flex-col items-center justify-center gap-2 py-8 text-sm">
				<span>{wis2Error}</span>
				<button
					type="button"
					onclick={fetchWis2}
					class="border-ink-2/30 text-ink hover:bg-shoal border px-3 py-1 text-xs"
				>
					Retry
				</button>
			</div>
		{:else if sortedWis2Channels.length === 0}
			<div class="text-ink-2 py-8 text-center text-sm">No active WIS2 channels reported.</div>
		{:else}
			<div class="border-ink-2/30 w-full overflow-x-auto border" data-testid="wis2-table-wrapper">
				<table class="tabular w-full table-fixed text-left text-xs" data-testid="wis2-table">
					<thead class="border-ink-2/30 bg-shoal/40 text-ink border-b">
						<tr>
							<th
								scope="col"
								data-testid="wis2-th-centre"
								class="hover:bg-shoal/80 w-44 cursor-pointer px-3 py-2.5 font-semibold select-none"
								aria-sort={wis2SortColumn === 'centre_id'
									? wis2SortDirection === 'asc'
										? 'ascending'
										: 'descending'
									: 'none'}
								onclick={() => handleWis2Sort('centre_id')}
							>
								<button type="button" class="flex items-center gap-1 font-semibold">
									Centre
									{#if wis2SortColumn === 'centre_id'}
										<span aria-hidden="true">{wis2SortDirection === 'asc' ? '▲' : '▼'}</span>
									{/if}
								</button>
							</th>
							<th
								scope="col"
								data-testid="wis2-th-kind"
								class="hover:bg-shoal/80 w-28 cursor-pointer px-3 py-2.5 font-semibold select-none"
								aria-sort={wis2SortColumn === 'kind'
									? wis2SortDirection === 'asc'
										? 'ascending'
										: 'descending'
									: 'none'}
								onclick={() => handleWis2Sort('kind')}
							>
								<button type="button" class="flex items-center gap-1 font-semibold">
									Kind
									{#if wis2SortColumn === 'kind'}
										<span aria-hidden="true">{wis2SortDirection === 'asc' ? '▲' : '▼'}</span>
									{/if}
								</button>
							</th>
							<th
								scope="col"
								data-testid="wis2-th-unique"
								class="hover:bg-shoal/80 w-28 cursor-pointer px-3 py-2.5 text-right font-semibold select-none"
								aria-sort={wis2SortColumn === 'unique_24h'
									? wis2SortDirection === 'asc'
										? 'ascending'
										: 'descending'
									: 'none'}
								onclick={() => handleWis2Sort('unique_24h')}
							>
								<button
									type="button"
									class="flex w-full items-center justify-end gap-1 font-semibold"
								>
									Unique 24h
									{#if wis2SortColumn === 'unique_24h'}
										<span aria-hidden="true">{wis2SortDirection === 'asc' ? '▲' : '▼'}</span>
									{/if}
								</button>
							</th>
							<th
								scope="col"
								data-testid="wis2-th-duplicates"
								class="hover:bg-shoal/80 w-24 cursor-pointer px-3 py-2.5 text-right font-semibold select-none"
								aria-sort={wis2SortColumn === 'duplicates_24h'
									? wis2SortDirection === 'asc'
										? 'ascending'
										: 'descending'
									: 'none'}
								onclick={() => handleWis2Sort('duplicates_24h')}
							>
								<button
									type="button"
									class="flex w-full items-center justify-end gap-1 font-semibold"
								>
									Duplicates
									{#if wis2SortColumn === 'duplicates_24h'}
										<span aria-hidden="true">{wis2SortDirection === 'asc' ? '▲' : '▼'}</span>
									{/if}
								</button>
							</th>
							<th
								scope="col"
								data-testid="wis2-th-failures"
								class="hover:bg-shoal/80 w-40 cursor-pointer px-3 py-2.5 text-right font-semibold select-none"
								aria-sort={wis2SortColumn === 'failures'
									? wis2SortDirection === 'asc'
										? 'ascending'
										: 'descending'
									: 'none'}
								onclick={() => handleWis2Sort('failures')}
							>
								<button
									type="button"
									class="flex w-full items-center justify-end gap-1 font-semibold"
								>
									Failures
									{#if wis2SortColumn === 'failures'}
										<span aria-hidden="true">{wis2SortDirection === 'asc' ? '▲' : '▼'}</span>
									{/if}
								</button>
							</th>
							<th
								scope="col"
								data-testid="wis2-th-last_received"
								class="hover:bg-shoal/80 w-28 cursor-pointer px-3 py-2.5 text-right font-semibold select-none"
								aria-sort={wis2SortColumn === 'last_received_at'
									? wis2SortDirection === 'asc'
										? 'ascending'
										: 'descending'
									: 'none'}
								onclick={() => handleWis2Sort('last_received_at')}
							>
								<button
									type="button"
									class="flex w-full items-center justify-end gap-1 font-semibold"
								>
									Last Received
									{#if wis2SortColumn === 'last_received_at'}
										<span aria-hidden="true">{wis2SortDirection === 'asc' ? '▲' : '▼'}</span>
									{/if}
								</button>
							</th>
							<th
								scope="col"
								data-testid="wis2-th-status"
								class="hover:bg-shoal/80 w-24 cursor-pointer px-3 py-2.5 font-semibold select-none"
								aria-sort={wis2SortColumn === 'status'
									? wis2SortDirection === 'asc'
										? 'ascending'
										: 'descending'
									: 'none'}
								onclick={() => handleWis2Sort('status')}
							>
								<button type="button" class="flex items-center gap-1 font-semibold">
									Status
									{#if wis2SortColumn === 'status'}
										<span aria-hidden="true">{wis2SortDirection === 'asc' ? '▲' : '▼'}</span>
									{/if}
								</button>
							</th>
						</tr>
					</thead>
					<tbody class="divide-ink-2/10 divide-y">
						{#each sortedWis2Channels as channel (channel.centre_id + channel.kind)}
							{@const unique = computeUnique24h(channel.received_24h, channel.duplicates_24h)}
							{@const totalFailures = computeTotalFailures(
								channel.download_failed_24h,
								channel.decode_failed_24h,
								channel.integrity_failed_24h
							)}
							<tr class="hover:bg-shoal/20" data-testid="wis2-row">
								<td class="text-ink px-3 py-2 font-medium">
									<div class="truncate" title={channel.centre_id}>
										{channel.centre_id}
									</div>
								</td>
								<td class="text-ink-2 px-3 py-2">
									<span
										class="border-ink-2/20 bg-shoal/30 inline-flex rounded border px-1.5 py-0.5 font-mono text-[11px]"
									>
										{channel.kind}
									</span>
								</td>
								<td
									class="px-3 py-2 text-right font-semibold {unique > 0
										? 'text-ink'
										: 'text-ink-2'}"
								>
									{unique}
								</td>
								<td class="text-ink-2 px-3 py-2 text-right">
									{channel.duplicates_24h}
								</td>
								<td
									class="px-3 py-2 text-right {totalFailures > 0
										? 'text-amber font-medium'
										: 'text-ink-2'}"
								>
									<span
										title="Download: {channel.download_failed_24h}, Decode: {channel.decode_failed_24h}, Integrity: {channel.integrity_failed_24h}"
									>
										{totalFailures}
										<span class="text-ink-2 text-[10px] font-normal">
											({channel.download_failed_24h}/{channel.decode_failed_24h}/{channel.integrity_failed_24h})
										</span>
									</span>
								</td>
								<td class="text-ink-2 px-3 py-2 text-right whitespace-nowrap">
									{formatTime(channel.last_received_at)}
								</td>
								<td class="px-3 py-2 whitespace-nowrap">
									<span
										class="inline-flex items-center rounded border px-1.5 py-0.5 text-[11px] font-medium {HEALTH_BADGE_CLASSES[
											channel.status
										]}"
									>
										{channel.status}
									</span>
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	</section>
</main>
