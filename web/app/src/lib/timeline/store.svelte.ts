import { SvelteSet, SvelteURLSearchParams } from 'svelte/reactivity';
import { earthquakeStore } from '$lib/earthquakes/store.svelte';
import type { RawEarthquakeEvent } from '$lib/earthquakes/types';
import { hazardStore } from '$lib/hazards/store.svelte';
import type { RawHazardEvent } from '$lib/hazards/types';
import { alertStore } from '$lib/alerts/store.svelte';
import type { RawAlertEvent } from '$lib/alerts/types';
import { compareItems, itemFromRecord, passesFilters } from './severity';
import type { TimelineFilters, TimelineItem, TimelineKind, TimelinePage } from './types';

const PAGE_LIMIT = 50;
const KIND_ORDER: readonly TimelineKind[] = ['earthquake', 'hazard', 'alert'];
/** Cap on unread pending arrivals; excess events are silently dropped. */
const MAX_PENDING = 200;

interface RawSource<E> {
	subscribeRaw(listener: (event: E) => void): () => void;
}

function defaultFilters(): TimelineFilters {
	return {
		kinds: new Set(KIND_ORDER),
		minMagnitude: 2.5,
		minSeverity: 'all'
	};
}

function buildQuery(baseUrl: string, before: string | null, filters: TimelineFilters): string {
	const params = new SvelteURLSearchParams();
	params.set('limit', String(PAGE_LIMIT));
	if (before) params.set('before', before);
	params.set('kinds', KIND_ORDER.filter((kind) => filters.kinds.has(kind)).join(','));
	params.set('minmag', String(filters.minMagnitude));
	if (filters.minSeverity !== 'all') params.set('min_severity', filters.minSeverity);
	return `${baseUrl}?${params}`;
}

function insertSorted(items: TimelineItem[], item: TimelineItem): void {
	let index = 0;
	while (index < items.length && compareItems(items[index], item) < 0) index += 1;
	items.splice(index, 0, item);
}

/**
 * Unified feed over the three existing SSE streams plus keyset-paginated history.
 * Live inserts always land in `pending`; the component decides when a row is
 * safe to splice into `items` without moving the reader's scroll position.
 */
export class TimelineStore {
	items = $state<TimelineItem[]>([]);
	pending = $state<TimelineItem[]>([]);
	updatedKeys = new SvelteSet<string>();
	nextCursor = $state<string | null>(null);
	loading = $state(false);
	loadingMore = $state(false);
	error: string | null = $state(null);
	filters = $state<TimelineFilters>(defaultFilters());

	#baseUrl = '/api/v1/timeline';
	#generation = 0;
	#subscribed = false;
	#unsubEarthquake: (() => void) | undefined;
	#unsubHazard: (() => void) | undefined;
	#unsubAlert: (() => void) | undefined;

	constructor(
		private readonly earthquakeSource: RawSource<RawEarthquakeEvent> = earthquakeStore,
		private readonly hazardSource: RawSource<RawHazardEvent> = hazardStore,
		private readonly alertSource: RawSource<RawAlertEvent> = alertStore
	) {}

	async connect(baseUrl: string = '/api/v1/timeline'): Promise<void> {
		this.#baseUrl = baseUrl;
		this.#subscribe();
		await this.#loadHead();
	}

	disconnect(): void {
		this.#generation += 1;
		this.#subscribed = false;
		this.#unsubEarthquake?.();
		this.#unsubHazard?.();
		this.#unsubAlert?.();
		this.#unsubEarthquake = undefined;
		this.#unsubHazard = undefined;
		this.#unsubAlert = undefined;
	}

	async loadMore(): Promise<void> {
		if (this.loadingMore || this.nextCursor === null) return;
		this.loadingMore = true;
		const generation = this.#generation;
		try {
			const page = await this.#fetchPage(this.nextCursor);
			if (generation !== this.#generation) return;
			for (const item of page.items) if (!this.#hasKey(item.key)) this.items.push(item);
			this.nextCursor = page.next_cursor;
			this.error = null;
		} catch (error) {
			if (generation !== this.#generation) return;
			this.error = error instanceof Error ? error.message : 'timeline request failed';
		} finally {
			if (generation === this.#generation) this.loadingMore = false;
		}
	}

	flushPending(): void {
		for (const item of this.pending) this.#upsertHead(item);
		this.pending = [];
	}

	setFilters(partial: Partial<TimelineFilters>): void {
		this.filters = { ...this.filters, ...partial };
		this.#generation += 1;
		this.items = [];
		this.pending = [];
		this.updatedKeys.clear();
		this.nextCursor = null;
		void this.#loadHead();
	}

	/** Re-reads page 1 and upserts by key, in place, without disturbing existing rows. */
	async refetchHead(): Promise<void> {
		const generation = this.#generation;
		try {
			const page = await this.#fetchPage(null);
			if (generation !== this.#generation) return;
			for (const item of page.items) this.#upsertHead(item);
		} catch {
			// Best-effort refresh after a resync; the existing state stays as-is.
		}
	}

	#subscribe(): void {
		if (this.#subscribed) return;
		this.#subscribed = true;
		this.#unsubEarthquake = this.earthquakeSource.subscribeRaw((event) => {
			if (event.type === 'resync') {
				void this.refetchHead();
				return;
			}
			this.#applyRaw(event.type, itemFromRecord('earthquake', event.record));
		});
		this.#unsubHazard = this.hazardSource.subscribeRaw((event) => {
			if (event.type === 'resync') {
				void this.refetchHead();
				return;
			}
			this.#applyRaw(event.type, itemFromRecord('hazard', event.record));
		});
		this.#unsubAlert = this.alertSource.subscribeRaw((event) => {
			if (event.type === 'resync') {
				void this.refetchHead();
				return;
			}
			const item = itemFromRecord('alert', event.record);
			if (event.type === 'ended') item.ended = true;
			this.#applyRaw(event.type, item);
		});
	}

	#upsertHead(item: TimelineItem): void {
		const index = this.items.findIndex((existing) => existing.key === item.key);
		if (index !== -1) this.items[index] = item;
		else insertSorted(this.items, item);
	}

	#applyRaw(type: 'new' | 'update' | 'ended', item: TimelineItem): void {
		if (type === 'new') {
			if (this.#hasKey(item.key)) return;
			if (!passesFilters(item, this.filters)) return;
			if (this.pending.length < MAX_PENDING) {
				this.pending.push(item);
			}
			return;
		}

		const itemsIndex = this.items.findIndex((existing) => existing.key === item.key);
		const pendingIndex = this.pending.findIndex((existing) => existing.key === item.key);
		if (itemsIndex === -1 && pendingIndex === -1) return;

		if (!passesFilters(item, this.filters)) {
			if (itemsIndex !== -1) this.items.splice(itemsIndex, 1);
			if (pendingIndex !== -1) this.pending.splice(pendingIndex, 1);
			this.updatedKeys.delete(item.key);
			return;
		}

		if (itemsIndex !== -1) {
			this.items[itemsIndex] = item;
			this.updatedKeys.add(item.key);
		}
		if (pendingIndex !== -1) this.pending[pendingIndex] = item;
	}

	#hasKey(key: string): boolean {
		return (
			this.items.some((item) => item.key === key) || this.pending.some((item) => item.key === key)
		);
	}

	async #loadHead(): Promise<void> {
		this.loading = true;
		this.error = null;
		const generation = this.#generation;
		try {
			const page = await this.#fetchPage(null);
			if (generation !== this.#generation) return;
			this.items = page.items;
			this.pending = [];
			this.updatedKeys.clear();
			this.nextCursor = page.next_cursor;
		} catch (error) {
			if (generation !== this.#generation) return;
			this.error = error instanceof Error ? error.message : 'timeline request failed';
		} finally {
			if (generation === this.#generation) this.loading = false;
		}
	}

	async #fetchPage(before: string | null): Promise<TimelinePage> {
		const url = buildQuery(this.#baseUrl, before, this.filters);
		const response = await fetch(url);
		if (!response.ok) throw new Error(`timeline request failed with status ${response.status}`);
		return (await response.json()) as TimelinePage;
	}
}

export const timelineStore = new TimelineStore();
