import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { TimelineStore } from './store.svelte';
import { itemFromRecord } from './severity';
import type { TimelineItem, TimelinePage } from './types';
import type { Earthquake } from '$lib/earthquakes/types';
import type { Hazard } from '$lib/hazards/types';
import type { Alert } from '$lib/alerts/types';

class FakeRawSource<E> {
	#listeners = new Set<(event: E) => void>();

	subscribeRaw(listener: (event: E) => void): () => void {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	}

	emit(event: E): void {
		for (const listener of this.#listeners) listener(event);
	}
}

function makeEarthquake(overrides: Partial<Earthquake> = {}): Earthquake {
	const now = new Date().toISOString();
	return {
		id: 1,
		kind: 'earthquake',
		magnitude: 5,
		magnitude_type: 'mb',
		occurred_at: now,
		occurred_at_ms: Date.now(),
		updated_at: now,
		updated_at_ms: Date.now(),
		place: 'Test location',
		title: 'M 5.0 - Test location',
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
		url: null,
		detail: null,
		longitude: 139.7,
		latitude: 35.6,
		depth_km: 12,
		preferred_source: 'usgs',
		sources: ['usgs'],
		members: [],
		first_seen_at: now,
		last_seen_at: now,
		...overrides
	};
}

function makeHazard(overrides: Partial<Hazard> = {}): Hazard {
	const now = new Date().toISOString();
	return {
		id: 'gdacs:TC-1',
		source: 'gdacs',
		source_id: 'TC-1',
		source_type_code: 'TC',
		hazard_type: 'tropical_cyclone',
		hazard_codes: [],
		glide: null,
		alert_level: 'orange',
		alert_score: 1.5,
		cap_severity: 'severe',
		severity_value: 120,
		severity_unit: 'km/h',
		severity_label: 'Wind speed 120 km/h',
		estimate_type: 'primary',
		title: 'Tropical Cyclone Test',
		description: 'Test description',
		countries: ['PHL'],
		report_url: null,
		onset_at: now,
		onset_at_ms: Date.now(),
		expires_at: now,
		expires_at_ms: Date.now(),
		modified_at: now,
		modified_at_ms: Date.now(),
		is_current: true,
		episode_id: 'e1',
		episode_count: 1,
		longitude: 120,
		latitude: 12,
		bbox: [119, 11, 121, 13],
		primary_geometry: null,
		external_ids: [],
		first_seen_at: now,
		last_seen_at: now,
		...overrides
	};
}

function makeAlert(overrides: Partial<Alert> = {}): Alert {
	const now = new Date().toISOString();
	return {
		id: 'urn:oid:test.1',
		event: 'Tornado Warning',
		severity: 'Extreme',
		urgency: 'Immediate',
		certainty: 'Observed',
		message_type: null,
		headline: null,
		area_desc: 'Test Area',
		ugc: [],
		same: [],
		geometry: null,
		sent: now,
		effective: null,
		expires: null,
		ends: null,
		first_seen_at: now,
		last_seen_at: now,
		ended_at: null,
		...overrides
	};
}

function page(items: TimelineItem[], nextCursor: string | null = null): TimelinePage {
	return { items, next_cursor: nextCursor, generated_at: new Date().toISOString() };
}

function jsonResponse(body: unknown): Response {
	return new Response(JSON.stringify(body));
}

async function settle(): Promise<void> {
	for (let index = 0; index < 8; index += 1) await Promise.resolve();
}

describe('TimelineStore', () => {
	let earthquakeSource: FakeRawSource<
		{ type: 'new' | 'update'; record: Earthquake } | { type: 'resync' }
	>;
	let hazardSource: FakeRawSource<{ type: 'new' | 'update'; record: Hazard } | { type: 'resync' }>;
	let alertSource: FakeRawSource<{ type: 'new' | 'update' | 'ended'; record: Alert }>;
	let fetchMock: ReturnType<typeof vi.fn>;

	beforeEach(() => {
		earthquakeSource = new FakeRawSource();
		hazardSource = new FakeRawSource();
		alertSource = new FakeRawSource();
		fetchMock = vi.fn();
		vi.stubGlobal('fetch', fetchMock);
	});

	afterEach(() => {
		vi.unstubAllGlobals();
	});

	function makeStore(): TimelineStore {
		return new TimelineStore(earthquakeSource, hazardSource, alertSource);
	}

	it('loads page 1 and keeps the server-given newest-first order', async () => {
		const eq = itemFromRecord('earthquake', makeEarthquake({ id: 1 }));
		const hz = itemFromRecord('hazard', makeHazard({ id: 'gdacs:TC-2' }));
		fetchMock.mockResolvedValue(jsonResponse(page([eq, hz], 'cursor-1')));
		const store = makeStore();

		await store.connect('/api/v1/timeline');

		expect(store.items).toEqual([eq, hz]);
		expect(store.nextCursor).toBe('cursor-1');
		expect(store.loading).toBe(false);
		store.disconnect();
	});

	it('builds the request URL with limit/kinds/minmag and omits min_severity when all', async () => {
		fetchMock.mockResolvedValue(jsonResponse(page([])));
		const store = makeStore();
		await store.connect('/api/v1/timeline');

		const url = fetchMock.mock.calls[0][0] as string;
		expect(url).toBe('/api/v1/timeline?limit=50&kinds=earthquake%2Chazard%2Calert&minmag=2.5');
		store.disconnect();
	});

	it('loadMore appends, stops at a null cursor, and ignores concurrent calls', async () => {
		const first = itemFromRecord('earthquake', makeEarthquake({ id: 1 }));
		const second = itemFromRecord('earthquake', makeEarthquake({ id: 2 }));
		fetchMock.mockResolvedValueOnce(jsonResponse(page([first], 'cursor-1')));
		const store = makeStore();
		await store.connect('/api/v1/timeline');

		let resolveSecondPage: (response: Response) => void;
		fetchMock.mockReturnValueOnce(
			new Promise<Response>((resolve) => {
				resolveSecondPage = resolve;
			})
		);
		const firstCall = store.loadMore();
		const secondCall = store.loadMore();
		resolveSecondPage!(jsonResponse(page([second], null)));
		await Promise.all([firstCall, secondCall]);

		expect(fetchMock).toHaveBeenCalledTimes(2);
		expect(store.items).toEqual([first, second]);
		expect(store.nextCursor).toBeNull();

		await store.loadMore();
		expect(fetchMock).toHaveBeenCalledTimes(2);
		store.disconnect();
	});

	it('sends a new SSE arrival to pending, not items', async () => {
		fetchMock.mockResolvedValue(jsonResponse(page([])));
		const store = makeStore();
		await store.connect('/api/v1/timeline');

		const record = makeEarthquake({ id: 99, magnitude: 5.5 });
		earthquakeSource.emit({ type: 'new', record });

		expect(store.items).toEqual([]);
		expect(store.pending).toHaveLength(1);
		expect(store.pending[0].key).toBe('earthquake:99');
		store.disconnect();
	});

	it('does not queue a new arrival that fails the current filters', async () => {
		fetchMock.mockResolvedValue(jsonResponse(page([])));
		const store = makeStore();
		await store.connect('/api/v1/timeline');

		hazardSource.emit({ type: 'new', record: makeHazard({ hazard_type: 'earthquake' }) });

		expect(store.pending).toHaveLength(0);
		store.disconnect();
	});

	it('flushPending inserts in sorted order and dedupes by key', async () => {
		fetchMock.mockResolvedValue(jsonResponse(page([])));
		const store = makeStore();
		await store.connect('/api/v1/timeline');

		const older = makeEarthquake({ id: 1, first_seen_at: '2026-09-18T00:00:00Z' });
		const newer = makeEarthquake({ id: 2, first_seen_at: '2026-09-18T01:00:00Z' });
		earthquakeSource.emit({ type: 'new', record: older });
		earthquakeSource.emit({ type: 'new', record: newer });
		// A duplicate key arriving in pending before flush must not create two rows.
		store.pending.push(itemFromRecord('earthquake', older));

		store.flushPending();

		expect(store.items.map((item) => item.key)).toEqual(['earthquake:2', 'earthquake:1']);
		expect(store.pending).toEqual([]);
		store.disconnect();
	});

	it('update replaces the record in place and marks the key as updated', async () => {
		const original = itemFromRecord('earthquake', makeEarthquake({ id: 1, magnitude: 5 }));
		fetchMock.mockResolvedValue(jsonResponse(page([original])));
		const store = makeStore();
		await store.connect('/api/v1/timeline');

		earthquakeSource.emit({
			type: 'update',
			record: makeEarthquake({ id: 1, magnitude: 6.2, title: 'Revised' })
		});

		expect(store.items).toHaveLength(1);
		expect(store.items[0].kind).toBe('earthquake');
		expect((store.items[0] as typeof original).earthquake.title).toBe('Revised');
		expect(store.updatedKeys.has('earthquake:1')).toBe(true);
		store.disconnect();
	});

	it('removes an item whose update no longer passes filters (magnitude revised below floor)', async () => {
		const original = itemFromRecord('earthquake', makeEarthquake({ id: 1, magnitude: 5 }));
		fetchMock.mockResolvedValue(jsonResponse(page([original])));
		const store = makeStore();
		await store.connect('/api/v1/timeline');

		earthquakeSource.emit({ type: 'update', record: makeEarthquake({ id: 1, magnitude: 1.0 }) });

		expect(store.items).toEqual([]);
		expect(store.updatedKeys.has('earthquake:1')).toBe(false);
		store.disconnect();
	});

	it('removes an item whose update marks the earthquake deleted', async () => {
		const original = itemFromRecord('earthquake', makeEarthquake({ id: 1, magnitude: 5 }));
		fetchMock.mockResolvedValue(jsonResponse(page([original])));
		const store = makeStore();
		await store.connect('/api/v1/timeline');

		earthquakeSource.emit({
			type: 'update',
			record: makeEarthquake({ id: 1, magnitude: 5, status: 'deleted' })
		});

		expect(store.items).toEqual([]);
		store.disconnect();
	});

	it('ended marks the key updated and ended without changing its position', async () => {
		const alertA = itemFromRecord(
			'alert',
			makeAlert({ id: 'a', first_seen_at: '2026-09-18T02:00:00Z' })
		);
		const alertB = itemFromRecord(
			'alert',
			makeAlert({ id: 'b', first_seen_at: '2026-09-18T01:00:00Z' })
		);
		fetchMock.mockResolvedValue(jsonResponse(page([alertA, alertB])));
		const store = makeStore();
		await store.connect('/api/v1/timeline');

		alertSource.emit({
			type: 'ended',
			record: makeAlert({
				id: 'b',
				first_seen_at: '2026-09-18T01:00:00Z',
				ended_at: '2026-09-18T03:00:00Z'
			})
		});

		expect(store.items.map((item) => item.key)).toEqual(['alert:a', 'alert:b']);
		expect(store.items[1].ended).toBe(true);
		expect(store.updatedKeys.has('alert:b')).toBe(true);
		store.disconnect();
	});

	it('ignores an update for a key it has never seen', async () => {
		fetchMock.mockResolvedValue(jsonResponse(page([])));
		const store = makeStore();
		await store.connect('/api/v1/timeline');

		earthquakeSource.emit({ type: 'update', record: makeEarthquake({ id: 404 }) });

		expect(store.items).toEqual([]);
		expect(store.pending).toEqual([]);
		store.disconnect();
	});

	it('a resync on the earthquake stream refetches page 1 and upserts by key', async () => {
		const original = itemFromRecord('earthquake', makeEarthquake({ id: 1, magnitude: 5 }));
		fetchMock.mockResolvedValueOnce(jsonResponse(page([original])));
		const store = makeStore();
		await store.connect('/api/v1/timeline');

		const revised = itemFromRecord('earthquake', makeEarthquake({ id: 1, magnitude: 6.5 }));
		fetchMock.mockResolvedValueOnce(jsonResponse(page([revised])));
		earthquakeSource.emit({ type: 'resync' });
		await settle();

		expect(store.items).toHaveLength(1);
		expect(store.items[0]).toEqual(revised);
		store.disconnect();
	});

	it('changing filters clears state and refetches with the new query', async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(page([itemFromRecord('alert', makeAlert())])));
		const store = makeStore();
		await store.connect('/api/v1/timeline');
		store.updatedKeys.add('alert:urn:oid:test.1');

		fetchMock.mockResolvedValueOnce(jsonResponse(page([])));
		store.setFilters({ kinds: new Set(['alert']) });

		expect(store.items).toEqual([]);
		expect(store.updatedKeys.size).toBe(0);
		await settle();

		const url = fetchMock.mock.calls[1][0] as string;
		expect(url).toContain('kinds=alert');
		store.disconnect();
	});

	it('refetchHead upserts page-1 records without creating duplicates', async () => {
		const a = itemFromRecord(
			'earthquake',
			makeEarthquake({ id: 1, first_seen_at: '2026-09-18T02:00:00Z' })
		);
		const b = itemFromRecord(
			'earthquake',
			makeEarthquake({ id: 2, first_seen_at: '2026-09-18T01:00:00Z' })
		);
		fetchMock.mockResolvedValueOnce(jsonResponse(page([a, b])));
		const store = makeStore();
		await store.connect('/api/v1/timeline');

		const aRevised = itemFromRecord(
			'earthquake',
			makeEarthquake({ id: 1, first_seen_at: '2026-09-18T02:00:00Z', magnitude: 7.2 })
		);
		const c = itemFromRecord(
			'earthquake',
			makeEarthquake({ id: 3, first_seen_at: '2026-09-18T03:00:00Z' })
		);
		fetchMock.mockResolvedValueOnce(jsonResponse(page([c, aRevised, b])));
		await store.refetchHead();

		expect(store.items.map((item) => item.key)).toEqual([
			'earthquake:3',
			'earthquake:1',
			'earthquake:2'
		]);
		expect(store.items).toHaveLength(3);
		store.disconnect();
	});
});
