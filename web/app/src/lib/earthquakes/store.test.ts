import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EarthquakeStore } from './store.svelte';
import type { Earthquake, EarthquakeMember } from './types';

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

function makeMember(overrides: Partial<EarthquakeMember> = {}): EarthquakeMember {
	const now = Date.now();
	return {
		source: 'usgs',
		source_id: 'us123',
		magnitude: 4.2,
		magnitude_type: 'mb',
		occurred_at_ms: now,
		updated_at_ms: now,
		latitude: 35.6,
		longitude: 139.7,
		depth_km: 12,
		place: 'Test location',
		status: 'reviewed',
		url: 'https://earthquake.usgs.gov/earthquakes/eventpage/us123',
		matched_by: 'origin',
		misfit: null,
		...overrides
	};
}

function makeEarthquake(overrides: Partial<Earthquake> = {}): Earthquake {
	const now = Date.now();
	return {
		id: 1,
		kind: 'earthquake',
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
		net: 'us',
		code: '123',
		url: 'https://earthquake.usgs.gov/earthquakes/eventpage/us123',
		detail: null,
		longitude: 139.7,
		latitude: 35.6,
		depth_km: 12,
		preferred_source: 'usgs',
		sources: ['usgs'],
		members: [makeMember()],
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
		fetchMock.mockResolvedValue(new Response(JSON.stringify({ earthquakes: [] })));
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
		resolveSnapshot!(new Response(JSON.stringify({ earthquakes: [makeEarthquake({ updated_at_ms: 10 })] })));
		await settle();

		expect(store.earthquakes.get(1)?.updated_at_ms).toBe(20);
		expect(store.blink.get(1)?.mode).toBe('arrival');
		store.disconnect();
	});

	it('uses the resync snapshot as a baseline while preserving later SSE events', async () => {
		const first = makeEarthquake({ id: 1 });
		const removed = makeEarthquake({ id: 2 });
		fetchMock
			.mockResolvedValueOnce(new Response(JSON.stringify({ earthquakes: [first, removed] })))
			.mockResolvedValueOnce(new Response(JSON.stringify({ earthquakes: [first] })));
		const store = new EarthquakeStore();
		await store.connect('/recent', '/stream');
		const stream = FakeEventSource.instances[0];
		stream.open();
		await settle();
		expect(store.earthquakes.size).toBe(2);

		stream.emit('resync', { reason: 'event_gap' });
		await settle();
		expect([...store.earthquakes.keys()]).toEqual([1]);
		store.disconnect();
	});

	it('removes events when an update is deleted or stops matching the filter', async () => {
		fetchMock.mockResolvedValue(new Response(JSON.stringify({ earthquakes: [] })));
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

	it('applies a higher-revision update and ignores a lower-revision one, keyed by id', async () => {
		fetchMock.mockResolvedValue(new Response(JSON.stringify({ earthquakes: [] })));
		const store = new EarthquakeStore();
		await store.connect('/recent', '/stream');
		const stream = FakeEventSource.instances[0];
		stream.open();
		await settle();

		stream.emit('new', makeEarthquake({ id: 42, updated_at_ms: 10, magnitude: 4 }));
		expect(store.earthquakes.get(42)?.magnitude).toBe(4);

		stream.emit('update', makeEarthquake({ id: 42, updated_at_ms: 5, magnitude: 9 }));
		expect(store.earthquakes.get(42)?.magnitude).toBe(4);

		stream.emit('update', makeEarthquake({ id: 42, updated_at_ms: 20, magnitude: 6 }));
		expect(store.earthquakes.get(42)?.magnitude).toBe(6);
		store.disconnect();
	});

	it('uses ETags per filter URL and does not flash a backfill event', async () => {
		fetchMock
			.mockResolvedValueOnce(new Response(JSON.stringify({ earthquakes: [] }), { headers: { etag: '"24h"' } }))
			.mockResolvedValueOnce(new Response(null, { status: 304 }))
			.mockResolvedValueOnce(new Response(JSON.stringify({ earthquakes: [] })));
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
		expect(store.blink.get(1)?.mode).toBe('persistent');
		store.disconnect();
	});

	it('restores the cached snapshot body when an earlier filter returns 304', async () => {
		const recent = makeEarthquake({ id: 1 });
		const weekOnly = makeEarthquake({
			id: 2,
			occurred_at_ms: Date.now() - 48 * 60 * 60 * 1000
		});
		fetchMock
			.mockResolvedValueOnce(new Response(JSON.stringify({ earthquakes: [recent] }), { headers: { etag: '"24h"' } }))
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ earthquakes: [recent, weekOnly] }), { headers: { etag: '"7d"' } })
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
		expect([...store.earthquakes.keys()]).toEqual([1, 2]);
		const updateRevision = weekOnly.updated_at_ms + 1;
		stream.emit('update', makeEarthquake({ ...weekOnly, updated_at_ms: updateRevision }));
		expect(store.earthquakes.get(2)?.updated_at_ms).toBe(updateRevision);
		store.setFilter({ hours: 24 });
		await settle();
		expect([...store.earthquakes.keys()]).toEqual([1]);
		store.setFilter({ hours: 168 });
		await settle();
		expect([...store.earthquakes.keys()]).toEqual([1, 2]);
		expect(store.earthquakes.get(2)?.updated_at_ms).toBe(updateRevision);
		expect(fetchMock.mock.calls[3][1]).toEqual({ headers: { 'If-None-Match': '"7d"' } });
		store.disconnect();
	});

	it('trims events by occurrence time and sorts by magnitude', () => {
		const store = new EarthquakeStore();
		store.earthquakes.set(1, makeEarthquake({ id: 1, magnitude: 3 }));
		store.earthquakes.set(2, makeEarthquake({ id: 2, magnitude: 5 }));
		store.earthquakes.set(
			3,
			makeEarthquake({ id: 3, occurred_at_ms: Date.now() - 25 * 60 * 60 * 1000 })
		);
		store.trim();

		expect(store.sorted.map((earthquake) => earthquake.id)).toEqual([2, 1]);
	});

	it('includes null magnitudes only when the all-magnitudes API filter is selected', async () => {
		const unknownMagnitude = makeEarthquake({ id: 5, magnitude: null });
		fetchMock.mockResolvedValue(new Response(JSON.stringify({ earthquakes: [unknownMagnitude] })));
		const store = new EarthquakeStore();
		await store.connect('/recent', '/stream', { minMagnitude: 'all' });
		FakeEventSource.instances[0].open();
		await settle();

		expect(store.earthquakes.has(5)).toBe(true);
		expect(fetchMock).toHaveBeenCalledWith('/recent?hours=24&minmag=all&type=earthquake', {
			headers: undefined
		});
		store.disconnect();
	});

	it('hides a quarry blast under the default filter and shows it with eventType "all"', async () => {
		const blast = makeEarthquake({ id: 6, event_type: 'quarry blast' });
		fetchMock
			.mockResolvedValueOnce(new Response(JSON.stringify({ earthquakes: [blast] })))
			.mockResolvedValueOnce(new Response(JSON.stringify({ earthquakes: [blast] })));
		const store = new EarthquakeStore();
		await store.connect('/recent', '/stream');
		FakeEventSource.instances[0].open();
		await settle();

		expect(store.earthquakes.has(6)).toBe(false);

		store.setFilter({ eventType: 'all' });
		await settle();
		expect(store.earthquakes.has(6)).toBe(true);
		store.disconnect();
	});

	it('fetches and exposes data sources for attribution', async () => {
		fetchMock.mockResolvedValue(
			new Response(
				JSON.stringify({
					sources: [
						{
							id: 'usgs',
							name: 'U.S. Geological Survey',
							homepage: 'https://earthquake.usgs.gov/',
							license: 'public-domain',
							attribution_text: 'Credit: U.S. Geological Survey',
							redistributable: true,
							priority: 100
						}
					]
				})
			)
		);
		const store = new EarthquakeStore();
		await store.fetchSources('/api/v1/sources');

		expect(store.sources.get('usgs')?.name).toBe('U.S. Geological Survey');
	});
});
