import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EarthquakeStore } from './store.svelte';
import type { Earthquake } from './types';

class FakeEventSource {
	static instances: FakeEventSource[] = [];
	listeners = new Map<string, Array<(event: MessageEvent<string>) => void>>();
	onopen: ((event: Event) => void) | null = null;
	onerror: ((event: Event) => void) | null = null;
	closed = false;

	constructor(readonly url: string) {
		FakeEventSource.instances.push(this);
	}

	addEventListener(type: string, listener: (event: MessageEvent<string>) => void): void {
		this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
	}

	close(): void {
		this.closed = true;
	}

	open(): void {
		this.onopen?.(new Event('open'));
	}

	emit(type: string, body: unknown): void {
		for (const listener of this.listeners.get(type) ?? []) {
			listener(new MessageEvent(type, { data: JSON.stringify(body) }));
		}
	}
}

function makeEarthquake(overrides: Partial<Earthquake> = {}): Earthquake {
	const now = Date.now();
	return {
		source: 'usgs',
		source_id: 'us123',
		contributing_ids: ['us123'],
		net: 'us',
		code: '123',
		magnitude: 4.2,
		magnitude_type: 'mb',
		occurred_at: new Date(now).toISOString(),
		occurred_at_ms: now,
		updated_at: new Date(now).toISOString(),
		updated_at_ms: now,
		place: 'Test location',
		title: 'M 4.2 - Test location',
		status: 'reviewed',
		event_type: 'earthquake',
		tsunami: 0,
		significance: 271,
		alert: null,
		mmi: null,
		cdi: null,
		felt: null,
		nst: null,
		dmin: null,
		rms: null,
		gap: null,
		url: 'https://earthquake.usgs.gov/earthquakes/eventpage/us123',
		detail: null,
		longitude: 139.7,
		latitude: 35.6,
		depth_km: 12,
		first_seen_at: new Date(now).toISOString(),
		last_seen_at: new Date(now).toISOString(),
		...overrides
	};
}

async function settle(): Promise<void> {
	for (let index = 0; index < 8; index += 1) await Promise.resolve();
}

describe('EarthquakeStore', () => {
	const fetchMock = vi.fn();

	beforeEach(() => {
		vi.useFakeTimers();
		FakeEventSource.instances = [];
		vi.stubGlobal('EventSource', FakeEventSource);
		vi.stubGlobal('fetch', fetchMock);
		fetchMock.mockReset();
	});

	afterEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	it('waits until SSE is open before loading the initial snapshot', async () => {
		fetchMock.mockResolvedValue(new Response(JSON.stringify([])));
		const store = new EarthquakeStore();
		await store.connect('/recent', '/stream');

		expect(fetchMock).not.toHaveBeenCalled();
		FakeEventSource.instances[0].open();
		await settle();
		expect(fetchMock).toHaveBeenCalledWith('/recent?hours=24&minmag=2.5&type=earthquake', {
			headers: undefined
		});
		store.disconnect();
	});

	it('keeps a newer SSE arrival when an older snapshot resolves afterwards', async () => {
		let resolveSnapshot: (response: Response) => void;
		fetchMock.mockReturnValue(
			new Promise<Response>((resolve) => {
				resolveSnapshot = resolve;
			})
		);
		const store = new EarthquakeStore();
		await store.connect('/recent', '/stream');
		const stream = FakeEventSource.instances[0];
		stream.open();
		const newer = makeEarthquake({ updated_at_ms: 20 });
		stream.emit('new', newer);
		resolveSnapshot!(new Response(JSON.stringify([makeEarthquake({ updated_at_ms: 10 })])));
		await settle();

		expect(store.earthquakes.get('usgs:us123')?.updated_at_ms).toBe(20);
		expect(store.blink.get('usgs:us123')?.mode).toBe('arrival');
		store.disconnect();
	});

	it('uses the resync snapshot as a baseline while preserving later SSE events', async () => {
		const first = makeEarthquake({ source_id: 'first' });
		const removed = makeEarthquake({ source_id: 'removed' });
		fetchMock
			.mockResolvedValueOnce(new Response(JSON.stringify([first, removed])))
			.mockResolvedValueOnce(new Response(JSON.stringify([first])));
		const store = new EarthquakeStore();
		await store.connect('/recent', '/stream');
		const stream = FakeEventSource.instances[0];
		stream.open();
		await settle();
		expect(store.earthquakes.size).toBe(2);

		stream.emit('resync', { reason: 'event_gap' });
		await settle();
		expect([...store.earthquakes.keys()]).toEqual(['usgs:first']);
		store.disconnect();
	});

	it('removes events when an update is deleted or stops matching the filter', async () => {
		fetchMock.mockResolvedValue(new Response(JSON.stringify([])));
		const store = new EarthquakeStore();
		await store.connect('/recent', '/stream');
		const stream = FakeEventSource.instances[0];
		stream.open();
		await settle();
		stream.emit('new', makeEarthquake({ updated_at_ms: 1 }));
		stream.emit('update', makeEarthquake({ updated_at_ms: 2, status: 'deleted' }));
		// A replayed pre-deletion `new` must not replace the tombstone that the
		// filter/cache overlay relies on after a later snapshot resync.
		stream.emit('new', makeEarthquake({ updated_at_ms: 1 }));
		expect(store.earthquakes.size).toBe(0);

		stream.emit('new', makeEarthquake({ updated_at_ms: 3 }));
		stream.emit('update', makeEarthquake({ updated_at_ms: 4, magnitude: 1 }));
		expect(store.earthquakes.size).toBe(0);
		store.disconnect();
	});

	it('uses ETags per filter URL and does not flash a backfill event', async () => {
		fetchMock
			.mockResolvedValueOnce(new Response(JSON.stringify([]), { headers: { etag: '"24h"' } }))
			.mockResolvedValueOnce(new Response(null, { status: 304 }))
			.mockResolvedValueOnce(new Response(JSON.stringify([])));
		const store = new EarthquakeStore();
		await store.connect('/recent', '/stream');
		const stream = FakeEventSource.instances[0];
		stream.open();
		await settle();
		store.retrySnapshot();
		await settle();
		expect(fetchMock.mock.calls[1][1]).toEqual({ headers: { 'If-None-Match': '"24h"' } });

		store.setFilter({ hours: 168 });
		await settle();
		expect(fetchMock.mock.calls[2][1]).toEqual({ headers: undefined });
		stream.emit('new', makeEarthquake({ is_backfill: true }));
		expect(store.blink.get('usgs:us123')?.mode).toBe('persistent');
		store.disconnect();
	});

	it('restores the cached snapshot body when an earlier filter returns 304', async () => {
		const recent = makeEarthquake({ source_id: 'recent' });
		const weekOnly = makeEarthquake({
			source_id: 'week-only',
			occurred_at_ms: Date.now() - 48 * 60 * 60 * 1000
		});
		fetchMock
			.mockResolvedValueOnce(new Response(JSON.stringify([recent]), { headers: { etag: '"24h"' } }))
			.mockResolvedValueOnce(
				new Response(JSON.stringify([recent, weekOnly]), { headers: { etag: '"7d"' } })
			)
			.mockResolvedValueOnce(new Response(null, { status: 304 }))
			.mockResolvedValueOnce(new Response(null, { status: 304 }));
		const store = new EarthquakeStore();
		await store.connect('/recent', '/stream');
		const stream = FakeEventSource.instances[0];
		stream.open();
		await settle();

		store.setFilter({ hours: 168 });
		await settle();
		expect([...store.earthquakes.keys()]).toEqual(['usgs:recent', 'usgs:week-only']);
		const updateRevision = weekOnly.updated_at_ms + 1;
		stream.emit('update', makeEarthquake({ ...weekOnly, updated_at_ms: updateRevision }));
		expect(store.earthquakes.get('usgs:week-only')?.updated_at_ms).toBe(updateRevision);
		store.setFilter({ hours: 24 });
		await settle();
		expect([...store.earthquakes.keys()]).toEqual(['usgs:recent']);
		store.setFilter({ hours: 168 });
		await settle();
		expect([...store.earthquakes.keys()]).toEqual(['usgs:recent', 'usgs:week-only']);
		expect(store.earthquakes.get('usgs:week-only')?.updated_at_ms).toBe(updateRevision);
		expect(fetchMock.mock.calls[3][1]).toEqual({ headers: { 'If-None-Match': '"7d"' } });
		store.disconnect();
	});

	it('trims events by occurrence time and sorts by magnitude', () => {
		const store = new EarthquakeStore();
		store.earthquakes.set('usgs:small', makeEarthquake({ source_id: 'small', magnitude: 3 }));
		store.earthquakes.set('usgs:large', makeEarthquake({ source_id: 'large', magnitude: 5 }));
		store.earthquakes.set(
			'usgs:old',
			makeEarthquake({ source_id: 'old', occurred_at_ms: Date.now() - 25 * 60 * 60 * 1000 })
		);
		store.trim();

		expect(store.sorted.map((earthquake) => earthquake.source_id)).toEqual(['large', 'small']);
	});

	it('includes null magnitudes only when the all-magnitudes API filter is selected', async () => {
		const unknownMagnitude = makeEarthquake({ source_id: 'unknown', magnitude: null });
		fetchMock.mockResolvedValue(new Response(JSON.stringify([unknownMagnitude])));
		const store = new EarthquakeStore();
		await store.connect('/recent', '/stream', { minMagnitude: 'all' });
		FakeEventSource.instances[0].open();
		await settle();

		expect(store.earthquakes.has('usgs:unknown')).toBe(true);
		expect(fetchMock).toHaveBeenCalledWith('/recent?hours=24&minmag=all&type=earthquake', {
			headers: undefined
		});
		store.disconnect();
	});

	it('hides a quarry blast under the default filter and shows it with eventType "all"', async () => {
		const blast = makeEarthquake({ source_id: 'blast', event_type: 'quarry blast' });
		fetchMock
			.mockResolvedValueOnce(new Response(JSON.stringify([blast])))
			.mockResolvedValueOnce(new Response(JSON.stringify([blast])));
		const store = new EarthquakeStore();
		await store.connect('/recent', '/stream');
		FakeEventSource.instances[0].open();
		await settle();

		expect(store.earthquakes.has('usgs:blast')).toBe(false);

		store.setFilter({ eventType: 'all' });
		await settle();
		expect(store.earthquakes.has('usgs:blast')).toBe(true);
		store.disconnect();
	});
});
