import { SvelteMap, SvelteSet } from 'svelte/reactivity';
import { fetchSourcesShared } from '$lib/sources/fetch';
import type {
	DataSource,
	Earthquake,
	EarthquakeBlinkState,
	EarthquakeEventType,
	EarthquakeFilter,
	RawEarthquakeEvent
} from './types';

const ARRIVAL_MS = 5000;
const HEARTBEAT_TIMEOUT_MS = 60000;
const TRIM_INTERVAL_MS = 60000;
const MAX_WINDOW_MS = 168 * 60 * 60 * 1000;
const MAX_SNAPSHOT_CACHES = 16;

const DEFAULT_FILTER: EarthquakeFilter = {
	hours: 24,
	minMagnitude: 2.5,
	eventType: 'earthquake'
};

function boundedFilter(filter: Partial<EarthquakeFilter>): EarthquakeFilter {
	const hours = Number.isFinite(filter.hours) ? Math.min(168, Math.max(1, filter.hours!)) : 24;
	const minMagnitude =
		filter.minMagnitude === 'all'
			? 'all'
			: typeof filter.minMagnitude === 'number' && Number.isFinite(filter.minMagnitude)
				? filter.minMagnitude!
				: 2.5;
	const eventType: EarthquakeEventType = filter.eventType === 'all' ? 'all' : 'earthquake';
	return { hours, minMagnitude, eventType };
}

function requestUrl(url: string, filter: EarthquakeFilter): string {
	const params = new URLSearchParams({
		hours: String(filter.hours),
		minmag: String(filter.minMagnitude),
		type: filter.eventType
	});
	return `${url}${url.includes('?') ? '&' : '?'}${params}`;
}

/**
 * Event facts differ from alerts: no event is "ended". They leave the view
 * only when occurrence time, type, magnitude, or deletion status says so.
 */
export class EarthquakeStore {
	earthquakes = new SvelteMap<number, Earthquake>();
	blink = new SvelteMap<number, EarthquakeBlinkState>();
	sources = new SvelteMap<string, DataSource>();
	reducedMotion = $state(false);
	connected: 'connecting' | 'open' | 'closed' = $state('closed');
	snapshotError: string | null = $state(null);
	filter = $state<EarthquakeFilter>({ ...DEFAULT_FILTER });

	#snapshotBaseUrl: string | undefined;
	#streamUrl: string | undefined;
	#es: EventSource | undefined;
	#etagByUrl = new SvelteMap<string, string>();
	#snapshotByUrl = new SvelteMap<string, { earthquakes: Earthquake[]; streamSequence: number }>();
	#watchdog: ReturnType<typeof setTimeout> | undefined;
	#trimTimer: ReturnType<typeof setInterval> | undefined;
	#blinkTimers = new SvelteMap<number, ReturnType<typeof setTimeout>>();
	#generation = 0;
	#filterRevision = 0;
	#snapshotRequest = 0;
	#streamSequence = 0;
	#streamSequenceByKey = new SvelteMap<number, number>();
	#streamOccurredAtByKey = new SvelteMap<number, number>();
	#streamEarthquakeByKey = new SvelteMap<number, Earthquake>();
	#rawListeners = new SvelteSet<(event: RawEarthquakeEvent) => void>();

	sorted = $derived.by(() =>
		[...this.earthquakes.values()].sort(
			(a, b) =>
				(b.magnitude ?? Number.NEGATIVE_INFINITY) - (a.magnitude ?? Number.NEGATIVE_INFINITY) ||
				b.occurred_at_ms - a.occurred_at_ms
		)
	);

	hasAnyBlinking = $derived.by(() => {
		if (this.reducedMotion) return false;
		for (const state of this.blink.values()) {
			if (state.mode === 'arrival' || state.mode === 'persistent') return true;
		}
		return false;
	});

	async connect(
		snapshotUrl: string,
		streamUrl: string,
		filter: Partial<EarthquakeFilter> = DEFAULT_FILTER
	): Promise<void> {
		if (this.#es) return;
		this.filter = boundedFilter(filter);
		this.#snapshotBaseUrl = snapshotUrl;
		this.#streamUrl = streamUrl;
		this.connected = 'connecting';
		// The initial snapshot is loaded from `open`, after the server has begun
		// the SSE subscription. Events arriving while it downloads win by their
		// revision/stream sequence, closing the snapshot/SSE race.
		this.#openStream(streamUrl);
		this.#trimTimer = setInterval(() => this.trim(), TRIM_INTERVAL_MS);
	}

	async fetchSources(url: string): Promise<void> {
		const generation = this.#generation;
		try {
			const sources = await fetchSourcesShared(url);
			if (generation !== this.#generation) return;
			for (const source of sources) this.sources.set(source.id, source);
		} catch {
			// Attribution is supplementary; leave labels/links working without it.
		}
	}

	setFilter(filter: Partial<EarthquakeFilter>): void {
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
		if (this.#trimTimer) clearInterval(this.#trimTimer);
		this.#trimTimer = undefined;
		for (const timer of this.#blinkTimers.values()) clearTimeout(timer);
		this.#blinkTimers.clear();
		this.connected = 'closed';
	}

	retrySnapshot(): void {
		void this.#loadSnapshot();
	}

	/** Raw SSE payloads for the unified timeline, delivered before this store's own filtering. */
	subscribeRaw(listener: (event: RawEarthquakeEvent) => void): () => void {
		this.#rawListeners.add(listener);
		return () => this.#rawListeners.delete(listener);
	}

	#emitRaw(event: RawEarthquakeEvent): void {
		for (const listener of this.#rawListeners) listener(event);
	}

	trim(now = Date.now()): void {
		for (const [key, earthquake] of this.earthquakes) {
			if (!this.#matchesFilter(earthquake, now)) this.#remove(key);
		}
		for (const [key, occurredAt] of this.#streamOccurredAtByKey) {
			if (occurredAt < now - MAX_WINDOW_MS) {
				this.#streamOccurredAtByKey.delete(key);
				this.#streamSequenceByKey.delete(key);
				this.#streamEarthquakeByKey.delete(key);
			}
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
				if (cached) this.#applySnapshot(cached.earthquakes, cached.streamSequence);
				this.trim();
				this.snapshotError = null;
				return;
			}
			if (!response.ok) throw new Error(`snapshot request failed with status ${response.status}`);
			const { earthquakes } = (await response.json()) as { earthquakes: Earthquake[] };
			if (
				generation !== this.#generation ||
				filterRevision !== this.#filterRevision ||
				request !== this.#snapshotRequest
			)
				return;
			const receivedEtag = response.headers.get('etag');
			if (receivedEtag) this.#etagByUrl.set(url, receivedEtag);
			this.#snapshotByUrl.delete(url);
			this.#snapshotByUrl.set(url, { earthquakes, streamSequence });
			if (this.#snapshotByUrl.size > MAX_SNAPSHOT_CACHES) {
				const oldestUrl = this.#snapshotByUrl.keys().next().value;
				if (oldestUrl) {
					this.#snapshotByUrl.delete(oldestUrl);
					this.#etagByUrl.delete(oldestUrl);
				}
			}
			this.#applySnapshot(earthquakes, streamSequence);
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

	#applySnapshot(earthquakes: Earthquake[], baselineStreamSequence: number): void {
		const snapshotKeys = new SvelteSet<number>();
		for (const earthquake of earthquakes) {
			const key = earthquake.id;
			snapshotKeys.add(key);
			// An SSE event after the snapshot/cache baseline (including deletion)
			// is newer than its body and must remain the visible projection.
			if ((this.#streamSequenceByKey.get(key) ?? 0) > baselineStreamSequence) continue;
			this.#merge(earthquake, 'snapshot');
		}
		for (const [key] of this.earthquakes) {
			if (snapshotKeys.has(key)) continue;
			if ((this.#streamSequenceByKey.get(key) ?? 0) <= baselineStreamSequence) this.#remove(key);
		}
		// A cache baseline can predate the currently selected time window. Replay
		// its newer stream overlay so a 24h → 7d switch restores a still-valid
		// event, while a deleted/filter-excluded row remains absent.
		for (const [key, earthquake] of this.#streamEarthquakeByKey) {
			if ((this.#streamSequenceByKey.get(key) ?? 0) > baselineStreamSequence) {
				this.#merge(earthquake, 'update');
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

	#matchesFilter(earthquake: Earthquake, now = Date.now()): boolean {
		if (earthquake.status === 'deleted') return false;
		if (
			this.filter.minMagnitude !== 'all' &&
			(earthquake.magnitude === null || earthquake.magnitude < this.filter.minMagnitude)
		)
			return false;
		if (this.filter.eventType === 'earthquake' && earthquake.event_type !== 'earthquake')
			return false;
		return earthquake.occurred_at_ms >= now - this.filter.hours * 60 * 60 * 1000;
	}

	#clearBlinkTimer(key: number): void {
		const timer = this.#blinkTimers.get(key);
		if (timer) clearTimeout(timer);
		this.#blinkTimers.delete(key);
	}

	#remove(key: number): void {
		this.#clearBlinkTimer(key);
		this.earthquakes.delete(key);
		this.blink.delete(key);
	}

	#merge(earthquake: Earthquake, source: 'new' | 'update' | 'snapshot'): void {
		const key = earthquake.id;
		const current = this.earthquakes.get(key);
		if (current && current.updated_at_ms >= earthquake.updated_at_ms) return;
		if (!this.#matchesFilter(earthquake)) {
			this.#remove(key);
			return;
		}

		this.earthquakes.set(key, earthquake);
		if (source === 'snapshot') {
			if (!current) this.blink.set(key, { mode: 'persistent', until: null });
			return;
		}
		if (source === 'update' || earthquake.is_backfill) {
			if (!this.blink.has(key)) this.blink.set(key, { mode: 'persistent', until: null });
			return;
		}

		this.#clearBlinkTimer(key);
		this.blink.set(key, { mode: 'arrival', until: performance.now() + ARRIVAL_MS });
		const timer = setTimeout(() => {
			this.blink.set(key, { mode: 'persistent', until: null });
			this.#blinkTimers.delete(key);
		}, ARRIVAL_MS);
		this.#blinkTimers.set(key, timer);
	}

	#handleNew = (event: MessageEvent<string>): void => {
		const earthquake = JSON.parse(event.data) as Earthquake;
		this.#emitRaw({ type: 'new', record: earthquake });
		const key = earthquake.id;
		const streamCurrent = this.#streamEarthquakeByKey.get(key);
		if (streamCurrent && streamCurrent.updated_at_ms >= earthquake.updated_at_ms) return;
		this.#streamSequence += 1;
		this.#streamSequenceByKey.set(key, this.#streamSequence);
		this.#streamOccurredAtByKey.set(key, earthquake.occurred_at_ms);
		this.#streamEarthquakeByKey.set(key, earthquake);
		this.#merge(earthquake, 'new');
	};

	#handleUpdate = (event: MessageEvent<string>): void => {
		const earthquake = JSON.parse(event.data) as Earthquake;
		this.#emitRaw({ type: 'update', record: earthquake });
		const key = earthquake.id;
		const streamCurrent = this.#streamEarthquakeByKey.get(key);
		if (streamCurrent && streamCurrent.updated_at_ms >= earthquake.updated_at_ms) return;
		this.#streamSequence += 1;
		this.#streamSequenceByKey.set(key, this.#streamSequence);
		this.#streamOccurredAtByKey.set(key, earthquake.occurred_at_ms);
		this.#streamEarthquakeByKey.set(key, earthquake);
		this.#merge(earthquake, 'update');
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
		// Also run this after a watchdog restart. Native EventSource reconnects
		// with Last-Event-ID when possible; a snapshot repairs anything outside
		// the server's replay buffer or lost when the watchdog rebuilt it.
		void this.#loadSnapshot();
	};

	#handleError = (): void => {
		this.connected = 'closed';
	};
}

export const earthquakeStore = new EarthquakeStore();
