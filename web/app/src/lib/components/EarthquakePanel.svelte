<script lang="ts">
	import { SvelteSet } from 'svelte/reactivity';
	import { earthquakeStore } from '$lib/earthquakes/store.svelte';
	import type { DataSource, EarthquakeMember } from '$lib/earthquakes/types';
	import { formatLocalDateTime } from '$lib/alerts/timeFormat';

	interface Props {
		selectedId: number | null;
		onselect: (id: number) => void;
		onclose: () => void;
		class?: string;
	}

	let { selectedId, onselect, onclose, class: className }: Props = $props();
	let now = $state(Date.now());

	$effect(() => {
		const timer = setInterval(() => (now = Date.now()), 30000);
		return () => clearInterval(timer);
	});

	const selected = $derived(
		selectedId !== null ? (earthquakeStore.earthquakes.get(selectedId) ?? null) : null
	);

	const JMA_DEFAULT_SOURCE: DataSource = {
		id: 'jma',
		name: '気象庁',
		homepage: 'https://www.jma.go.jp/jma/kishou/info/coment.html',
		license: '公共データ利用規約（第1.0版）',
		attribution_text: '気象庁防災情報XMLをもとにMatrixWhaleが加工。編集責任：MatrixWhale。',
		redistributable: true,
		priority: 95
	};

	function magnitudeLabel(magnitude: number | null): string {
		return magnitude === null ? 'M—' : `M${magnitude.toFixed(1)}`;
	}

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

	// EMSC's CC BY 4.0 license requires attribution whenever its events are on
	// screen, not only when one is selected, so this covers the whole loaded set.
	const visibleSources = $derived.by((): DataSource[] => {
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

	function timeSince(iso: string): string {
		const minutes = Math.max(0, Math.round((now - new Date(iso).getTime()) / 60000));
		if (minutes < 1) return 'just now';
		if (minutes < 60) return `${minutes}m ago`;
		const hours = Math.round(minutes / 60);
		if (hours < 24) return `${hours}h ago`;
		return `${Math.round(hours / 24)}d ago`;
	}
</script>

<section class="border-ink-2/30 flex shrink-0 flex-col border-b {className ?? ''}">
	<div class="border-ink-2/30 shrink-0 border-b px-3 py-2">
		<div class="flex items-baseline justify-between gap-2">
			<h2 class="text-sm font-semibold">Earthquakes</h2>
			<span class="text-ink-2 tabular text-xs">{earthquakeStore.sorted.length} shown</span>
		</div>
		<div class="mt-2 flex flex-wrap gap-1" aria-label="Earthquake filters">
			<button
				type="button"
				aria-pressed={earthquakeStore.filter.hours === 24}
				onclick={() => earthquakeStore.setFilter({ hours: 24 })}
				class="border-ink-2/30 aria-pressed:bg-shoal border px-2 py-0.5 text-xs"
			>
				24h
			</button>
			<button
				type="button"
				aria-pressed={earthquakeStore.filter.hours === 168}
				onclick={() => earthquakeStore.setFilter({ hours: 168 })}
				class="border-ink-2/30 aria-pressed:bg-shoal border px-2 py-0.5 text-xs"
			>
				7d
			</button>
			<button
				type="button"
				aria-pressed={earthquakeStore.filter.minMagnitude === 2.5}
				onclick={() => earthquakeStore.setFilter({ minMagnitude: 2.5 })}
				class="border-ink-2/30 aria-pressed:bg-shoal border px-2 py-0.5 text-xs"
			>
				M2.5+
			</button>
			<button
				type="button"
				aria-pressed={earthquakeStore.filter.minMagnitude === 'all'}
				onclick={() => earthquakeStore.setFilter({ minMagnitude: 'all' })}
				class="border-ink-2/30 aria-pressed:bg-shoal border px-2 py-0.5 text-xs"
			>
				All magnitudes
			</button>
			<button
				type="button"
				aria-pressed={earthquakeStore.filter.eventType === 'earthquake'}
				onclick={() => earthquakeStore.setFilter({ eventType: 'earthquake' })}
				class="border-ink-2/30 aria-pressed:bg-shoal border px-2 py-0.5 text-xs"
			>
				Earthquakes only
			</button>
			<button
				type="button"
				aria-pressed={earthquakeStore.filter.eventType === 'all'}
				onclick={() => earthquakeStore.setFilter({ eventType: 'all' })}
				class="border-ink-2/30 aria-pressed:bg-shoal border px-2 py-0.5 text-xs"
			>
				All types
			</button>
		</div>
		<p class="text-ink-2 mt-2 text-xs">
			<span class="mr-1 inline-block h-2 w-2 rounded-full bg-amber-600" aria-hidden="true"></span>
			Live {earthquakeStore.connected === 'open' ? '· connected' : '· reconnecting'}
		</p>
	</div>

	{#if earthquakeStore.snapshotError}
		<div class="border-ink-2/30 flex items-center justify-between gap-2 border-b px-3 py-2 text-xs">
			<span>{earthquakeStore.snapshotError}</span>
			<button
				type="button"
				onclick={() => earthquakeStore.retrySnapshot()}
				class="border-ink-2/30 shrink-0 border px-2 py-0.5">Retry</button
			>
		</div>
	{/if}

	{#if selected}
		<div class="border-ink-2/30 flex shrink-0 flex-col gap-2 border-b px-3 py-3 text-sm">
			<div class="flex items-start justify-between gap-2">
				<h3 class="font-semibold">
					<span class="text-amber-700">{magnitudeLabel(selected.magnitude)}</span>
					{selected.place ?? selected.title ?? 'Unknown location'}
				</h3>
				<button
					type="button"
					onclick={onclose}
					aria-label="Close earthquake details"
					class="text-ink-2">&times;</button
				>
			</div>
			<p class="text-ink-2 tabular text-xs">
				<time datetime={selected.occurred_at} title={selected.occurred_at}
					>{formatLocalDateTime(selected.occurred_at)}</time
				>
				· {selected.depth_km === null ? 'Depth —' : `Depth ${selected.depth_km.toFixed(1)} km`}
			</p>
			<p class="text-ink-2 tabular text-xs">
				{selected.latitude.toFixed(3)}°, {selected.longitude.toFixed(3)}° · {selected.status ??
					'status unavailable'}
			</p>
			{#if selected.tsunami === 1}
				<p class="text-ink-2 text-xs">
					USGS tsunami screening flag; this is not a tsunami warning.
				</p>
			{/if}
			<ul class="flex flex-col gap-0.5">
				{#each selected.members as member (member.source + member.source_id)}
					<li class="text-ink-2 text-xs">{memberLabel(member)}</li>
				{/each}
			</ul>
			<div class="flex items-center gap-2 pt-1">
				{#if selected.url}
					<a
						href={selected.url}
						target="_blank"
						rel="external noopener noreferrer"
						class="border-ink-2/30 hover:bg-shoal border px-2 py-1 text-xs"
						>{selected.preferred_source.toUpperCase()} event</a
					>
				{/if}
			</div>
			<div data-testid="earthquake-event-sources" class="flex flex-col gap-0.5">
				{#each selected.sources as sourceId (sourceId)}
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
	{/if}

	<ul class="max-h-40 min-h-28 overflow-y-auto">
		{#each earthquakeStore.sorted as earthquake (earthquake.id)}
			<li>
				<button
					type="button"
					data-testid="earthquake-feed-item"
					aria-current={selectedId === earthquake.id ? 'true' : undefined}
					onclick={() => onselect(earthquake.id)}
					class="border-ink-2/10 hover:bg-shoal focus-visible:bg-shoal flex w-full flex-col gap-0.5 border-b px-3 py-2 text-left text-sm {selectedId ===
					earthquake.id
						? 'bg-shoal'
						: ''}"
				>
					<span class="flex items-center justify-between gap-2">
						<span class="font-medium"
							><span class="text-amber-700">{magnitudeLabel(earthquake.magnitude)}</span>
							{earthquake.place ?? earthquake.title ?? 'Unknown location'}</span
						>
						<span class="tabular text-ink-2 shrink-0 text-xs"
							>{timeSince(earthquake.occurred_at)}</span
						>
					</span>
					<span class="text-ink-2 text-xs"
						>{earthquake.event_type ?? 'event'}{earthquake.magnitude_type
							? ` · ${earthquake.magnitude_type}`
							: ''}</span
					>
				</button>
			</li>
		{:else}
			<li class="text-ink-2 px-3 py-4 text-sm">No events match these filters.</li>
		{/each}
	</ul>
	{#if visibleSources.length > 0}
		<footer
			data-testid="earthquake-attribution"
			class="border-ink-2/30 flex shrink-0 flex-col gap-0.5 border-t px-3 py-2"
		>
			{#each visibleSources as source (source.id)}
				<a
					href={source.homepage}
					target="_blank"
					rel="external noopener noreferrer"
					class="text-ink-2 text-xs hover:underline">{source.attribution_text}</a
				>
			{/each}
		</footer>
	{/if}
</section>
