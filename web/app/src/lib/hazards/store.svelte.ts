import { SvelteMap, SvelteSet } from 'svelte/reactivity';
import type { DataSource } from '$lib/earthquakes/types';
import {
	ALERT_LEVELS,
	HAZARD_TYPES,
	HAZARD_TYPE_CODES,
	type Hazard,
	type HazardDetail,
	type HazardFilter,
	type RawHazardEvent
} from './types';

const HEARTBEAT_TIMEOUT_MS = 60000;
const MAX_SNAPSHOT_CACHES = 16;
const HAZARDS_BASE_PATH = '/api/v1/hazards';

function defaultFilter(): HazardFilter {
	return {
		types: new Set(HAZARD_TYPES.filter((type) => type !== 'earthquake')),
		levels: new Set(ALERT_LEVELS)
	};
}

function boundedFilter(filter: Partial<HazardFilter>): HazardFilter {
	return {
		types: filter.types ? new Set(filter.types) : defaultFilter().types,
		levels: filter.levels ? new Set(filter.levels) : new Set(ALERT_LEVELS)
	};
}

function requestUrl(url: string, filter: HazardFilter): string {
	const params = new URLSearchParams({
		types: [...filter.types].map((type) => HAZARD_TYPE_CODES[type]).join(','),
		levels: [...filter.levels].join(',')
	});
	return `${url}${url.includes('?') ? '&' : '?'}${params}`;
}

/**
 * GDACS hazards mirror the earthquake store's snapshot+SSE contract, keyed by
 * `id` and revision-guarded by `modified_at_ms`. There is no blink/arrival
 * animation here (unlike earthquakes/alerts): the map only needs a stable set.
 */
export class HazardStore {
	hazards = new SvelteMap<string, Hazard>();
	sources = new SvelteMap<string, DataSource>();
	details = new SvelteMap<string, HazardDetail>();
	connected: 'connecting' | 'open' | 'closed' = $state('closed');
	snapshotError: string | null = $state(null);
	filter = $state<HazardFilter>(defaultFilter());

	#snapshotBaseUrl: string | undefined;
	#streamUrl: string | undefined;
	#es: EventSource | undefined;
	#etagByUrl = new SvelteMap<string, string>();
	#snapshotByUrl = new SvelteMap<string, { hazards: Hazard[]; streamSequence: number }>();
	#watchdog: ReturnType<typeof setTimeout> | undefined;
	#generation = 0;
	#filterRevision = 0;
	#snapshotRequest = 0;
	#streamSequence = 0;
	#streamSequenceByKey = new SvelteMap<string, number>();
	#streamHazardByKey = new SvelteMap<string, Hazard>();
	#rawListeners = new SvelteSet<(event: RawHazardEvent) => void>();

	sorted = $derived.by(() =>
		[...this.hazards.values()].sort((a, b) => b.modified_at_ms - a.modified_at_ms)
	);

	async connect(
		snapshotUrl: string,
		streamUrl: string,
		filter: Partial<HazardFilter> = {}
	): Promise<void> {
		if (this.#es) return;
		this.filter = boundedFilter(filter);
		this.#snapshotBaseUrl = snapshotUrl;
		this.#streamUrl = streamUrl;
		this.connected = 'connecting';
		// Mirrors EarthquakeStore: the initial snapshot loads from `open`, after
		// the SSE subscription has begun, so events arriving during the download
		// win by revision and the snapshot/SSE race never flashes stale data.
		this.#openStream(streamUrl);
	}

	async fetchSources(url: string): Promise<void> {
		try {
			const response = await fetch(url);
			if (!response.ok) return;
			const body = (await response.json()) as { sources: DataSource[] };
			for (const source of body.sources) this.sources.set(source.id, source);
		} catch {
			// Attribution is supplementary; leave labels/links working without it.
		}
	}

	async fetchDetail(id: string): Promise<HazardDetail | null> {
		const separatorIndex = id.indexOf(':');
		if (separatorIndex === -1) return null;
		const source = id.slice(0, separatorIndex);
		const sourceId = id.slice(separatorIndex + 1);
		try {
			const response = await fetch(
				`${HAZARDS_BASE_PATH}/${encodeURIComponent(source)}/${encodeURIComponent(sourceId)}`
			);
			if (!response.ok) return null;
			const detail = (await response.json()) as HazardDetail;
			this.details.set(id, detail);
			this.#merge(detail.hazard);
			return detail;
		} catch {
			return null;
		}
	}

	setFilter(filter: Partial<HazardFilter>): void {
		this.filter = boundedFilter({ ...this.filter, ...filter });
		this.#filterRevision += 1;
		this.trim();
		void this.#loadSnapshot();
	}

	disconnect(): void {
		this.#generation += 1;
		this.#es?.close();
		this.#es = undefined;
		if (this.#watchdog) clearTimeout(this.#watchdog);
		this.#watchdog = undefined;
		this.connected = 'closed';
	}

	retrySnapshot(): void {
		void this.#loadSnapshot();
	}

	/** Raw SSE payloads for the unified timeline, delivered before this store's own filtering. */
	subscribeRaw(listener: (event: RawHazardEvent) => void): () => void {
		this.#rawListeners.add(listener);
		return () => this.#rawListeners.delete(listener);
	}

	#emitRaw(event: RawHazardEvent): void {
		for (const listener of this.#rawListeners) listener(event);
	}

	trim(): void {
		for (const [key, hazard] of this.hazards) {
			if (!this.#matchesFilter(hazard)) this.#remove(key);
		}
	}

	async #loadSnapshot(): Promise<void> {
		if (!this.#snapshotBaseUrl) return;
		const generation = this.#generation;
		const filterRevision = this.#filterRevision;
		const request = ++this.#snapshotRequest;
		const streamSequence = this.#streamSequence;
		const url = requestUrl(this.#snapshotBaseUrl, this.filter);
		try {
			const etag = this.#etagByUrl.get(url);
			const headers = etag ? { 'If-None-Match': etag } : undefined;
			const response = await fetch(url, { headers });
			if (response.status === 304) {
				if (
					generation !== this.#generation ||
					filterRevision !== this.#filterRevision ||
					request !== this.#snapshotRequest
				)
					return;
				const cached = this.#snapshotByUrl.get(url);
				if (cached) this.#applySnapshot(cached.hazards, cached.streamSequence);
				this.trim();
				this.snapshotError = null;
				return;
			}
			if (!response.ok) throw new Error(`snapshot request failed with status ${response.status}`);
			const { hazards } = (await response.json()) as { hazards: Hazard[] };
			if (
				generation !== this.#generation ||
				filterRevision !== this.#filterRevision ||
				request !== this.#snapshotRequest
			)
				return;
			const receivedEtag = response.headers.get('etag');
			if (receivedEtag) this.#etagByUrl.set(url, receivedEtag);
			this.#snapshotByUrl.delete(url);
			this.#snapshotByUrl.set(url, { hazards, streamSequence });
			if (this.#snapshotByUrl.size > MAX_SNAPSHOT_CACHES) {
				const oldestUrl = this.#snapshotByUrl.keys().next().value;
				if (oldestUrl) {
					this.#snapshotByUrl.delete(oldestUrl);
					this.#etagByUrl.delete(oldestUrl);
				}
			}
			this.#applySnapshot(hazards, streamSequence);
			this.trim();
			this.snapshotError = null;
		} catch (error) {
			if (
				generation !== this.#generation ||
				filterRevision !== this.#filterRevision ||
				request !== this.#snapshotRequest
			)
				return;
			this.snapshotError = error instanceof Error ? error.message : 'snapshot request failed';
		}
	}

	#applySnapshot(hazards: Hazard[], baselineStreamSequence: number): void {
		const snapshotKeys = new SvelteSet<string>();
		for (const hazard of hazards) {
			const key = hazard.id;
			snapshotKeys.add(key);
			// An SSE event after the snapshot/cache baseline (including a filter
			// drop) is newer than its body and must remain the visible projection.
			if ((this.#streamSequenceByKey.get(key) ?? 0) > baselineStreamSequence) continue;
			this.#merge(hazard);
		}
		for (const [key] of this.hazards) {
			if (snapshotKeys.has(key)) continue;
			if ((this.#streamSequenceByKey.get(key) ?? 0) <= baselineStreamSequence) this.#remove(key);
		}
		// A cache baseline can predate a filter change. Replay its newer stream
		// overlay so re-enabling a type/level restores a still-valid hazard.
		for (const [key, hazard] of this.#streamHazardByKey) {
			if ((this.#streamSequenceByKey.get(key) ?? 0) > baselineStreamSequence) {
				this.#merge(hazard);
			}
		}
	}

	#openStream(url: string): void {
		const es = new EventSource(url);
		es.addEventListener('new', this.#handleNew);
		es.addEventListener('update', this.#handleUpdate);
		es.addEventListener('resync', this.#handleResync);
		es.addEventListener('heartbeat', this.#handleHeartbeat);
		es.onopen = this.#handleOpen;
		es.onerror = this.#handleError;
		this.#es = es;
		this.#armWatchdog();
	}

	#restartStream(): void {
		if (!this.#streamUrl || !this.#es) return;
		this.#es.close();
		this.#es = undefined;
		this.connected = 'connecting';
		this.#openStream(this.#streamUrl);
	}

	#armWatchdog(): void {
		if (this.#watchdog) clearTimeout(this.#watchdog);
		this.#watchdog = setTimeout(() => {
			this.connected = 'closed';
			this.#restartStream();
		}, HEARTBEAT_TIMEOUT_MS);
	}

	#matchesFilter(hazard: Hazard): boolean {
		return this.filter.types.has(hazard.hazard_type) && this.filter.levels.has(hazard.alert_level);
	}

	#remove(key: string): void {
		this.hazards.delete(key);
	}

	#merge(hazard: Hazard): void {
		const key = hazard.id;
		const current = this.hazards.get(key);
		if (current && current.modified_at_ms >= hazard.modified_at_ms) return;
		if (!this.#matchesFilter(hazard)) {
			this.#remove(key);
			return;
		}
		this.hazards.set(key, hazard);
	}

	#applyStreamHazard(hazard: Hazard): void {
		const key = hazard.id;
		const streamCurrent = this.#streamHazardByKey.get(key);
		if (streamCurrent && streamCurrent.modified_at_ms >= hazard.modified_at_ms) return;
		this.#streamSequence += 1;
		this.#streamSequenceByKey.set(key, this.#streamSequence);
		this.#streamHazardByKey.set(key, hazard);
		this.#merge(hazard);
	}

	#handleNew = (event: MessageEvent<string>): void => {
		const hazard = JSON.parse(event.data) as Hazard;
		this.#emitRaw({ type: 'new', record: hazard });
		this.#applyStreamHazard(hazard);
	};

	#handleUpdate = (event: MessageEvent<string>): void => {
		const hazard = JSON.parse(event.data) as Hazard;
		this.#emitRaw({ type: 'update', record: hazard });
		this.#applyStreamHazard(hazard);
	};

	#handleResync = (): void => {
		this.#emitRaw({ type: 'resync' });
		void this.#loadSnapshot();
	};

	#handleHeartbeat = (): void => {
		this.connected = 'open';
		this.#armWatchdog();
	};

	#handleOpen = (): void => {
		this.connected = 'open';
		this.#armWatchdog();
		// Also runs after a watchdog restart; a snapshot repairs anything outside
		// the server's replay buffer or lost when the watchdog rebuilt the stream.
		void this.#loadSnapshot();
	};

	#handleError = (): void => {
		this.connected = 'closed';
	};
}

export const hazardStore = new HazardStore();
