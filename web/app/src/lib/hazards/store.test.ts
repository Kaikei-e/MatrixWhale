import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { clearSourcesInFlight } from '$lib/sources/fetch';
import { resetSharedLiveStream } from '$lib/api/liveStream';
import { encodePolygon, encodeMultiPolygon } from '../../../scripts/geodata/geometry-transport.mjs';
import { HazardStore } from './store.svelte';
import type { Hazard } from './types';

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

function makeHazard(overrides: Partial<Hazard> = {}): Hazard {
	const now = Date.now();
	return {
		id: 'gdacs:TC-1000001',
		source: 'gdacs',
		source_id: 'TC-1000001',
		source_type_code: 'TC',
		hazard_type: 'tropical_cyclone',
		hazard_codes: ['glide:TC'],
		glide: null,
		alert_level: 'orange',
		alert_score: 1.5,
		cap_severity: 'severe',
		severity_value: 120,
		severity_unit: 'km/h',
		severity_label: 'Wind speed 120 km/h',
		estimate_type: 'primary',
		title: 'Tropical Cyclone Test',
		description: 'Tropical cyclone test description',
		countries: ['PHL'],
		report_url: 'https://www.gdacs.org/report.aspx?eventid=1000001&episodeid=1&eventtype=TC',
		onset_at: new Date(now).toISOString(),
		onset_at_ms: now,
		expires_at: new Date(now).toISOString(),
		expires_at_ms: now,
		modified_at: new Date(now).toISOString(),
		modified_at_ms: now,
		is_current: true,
		episode_id: '1',
		episode_count: 1,
		longitude: 120.5,
		latitude: 14.5,
		bbox: [120.5, 14.5, 120.5, 14.5],
		primary_geometry: null,
		external_ids: [],
		first_seen_at: new Date(now).toISOString(),
		last_seen_at: new Date(now).toISOString(),
		...overrides
	};
}

async function settle(): Promise<void> {
	for (let index = 0; index < 8; index += 1) await Promise.resolve();
}

describe('HazardStore', () => {
	const fetchMock = vi.fn();

	beforeEach(() => {
		resetSharedLiveStream();
		clearSourcesInFlight();
		vi.useFakeTimers();
		FakeEventSource.instances = [];
		vi.stubGlobal('EventSource', FakeEventSource);
		vi.stubGlobal('fetch', fetchMock);
		fetchMock.mockReset();
	});

	afterEach(() => {
		resetSharedLiveStream();
		clearSourcesInFlight();
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	it('waits until SSE is open before loading the initial snapshot', async () => {
		fetchMock.mockResolvedValue(new Response(JSON.stringify({ hazards: [] })));
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');

		expect(fetchMock).not.toHaveBeenCalled();
		FakeEventSource.instances[0].open();
		await settle();
		expect(fetchMock).toHaveBeenCalledTimes(1);
		expect(fetchMock.mock.calls[0][0]).toContain('/api/v1/hazards/recent');
		store.disconnect();
	});

	it('loads the snapshot into the map, sorted by modified_at_ms desc', async () => {
		const older = makeHazard({ id: 'gdacs:TC-1', modified_at_ms: 10 });
		const newer = makeHazard({ id: 'gdacs:FL-2', hazard_type: 'flood', modified_at_ms: 20 });
		fetchMock.mockResolvedValue(new Response(JSON.stringify({ hazards: [older, newer] })));
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		FakeEventSource.instances[0].open();
		await settle();

		expect(store.sorted.map((hazard) => hazard.id)).toEqual(['gdacs:FL-2', 'gdacs:TC-1']);
		store.disconnect();
	});

	it('adds a hazard on a "new" SSE event', async () => {
		fetchMock.mockResolvedValue(new Response(JSON.stringify({ hazards: [] })));
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		const stream = FakeEventSource.instances[0];
		stream.open();
		await settle();

		stream.emit('new', makeHazard({ id: 'gdacs:TC-9' }));
		expect(store.hazards.has('gdacs:TC-9')).toBe(true);
		store.disconnect();
	});

	it('applies a higher-revision update and ignores a lower-revision one, keyed by id', async () => {
		fetchMock.mockResolvedValue(new Response(JSON.stringify({ hazards: [] })));
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		const stream = FakeEventSource.instances[0];
		stream.open();
		await settle();

		stream.emit('new', makeHazard({ id: 'gdacs:TC-9', modified_at_ms: 10, alert_level: 'orange' }));
		expect(store.hazards.get('gdacs:TC-9')?.alert_level).toBe('orange');

		stream.emit('update', makeHazard({ id: 'gdacs:TC-9', modified_at_ms: 5, alert_level: 'red' }));
		expect(store.hazards.get('gdacs:TC-9')?.alert_level).toBe('orange');

		stream.emit('update', makeHazard({ id: 'gdacs:TC-9', modified_at_ms: 20, alert_level: 'red' }));
		expect(store.hazards.get('gdacs:TC-9')?.alert_level).toBe('red');
		store.disconnect();
	});

	it('uses the resync snapshot as a baseline while preserving later SSE events', async () => {
		const first = makeHazard({ id: 'gdacs:TC-1' });
		const removed = makeHazard({ id: 'gdacs:FL-2', hazard_type: 'flood' });
		fetchMock
			.mockResolvedValueOnce(new Response(JSON.stringify({ hazards: [first, removed] })))
			.mockResolvedValueOnce(new Response(JSON.stringify({ hazards: [first] })));
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		const stream = FakeEventSource.instances[0];
		stream.open();
		await settle();
		expect(store.hazards.size).toBe(2);

		stream.emit('resync', { reason: 'event_gap' });
		await settle();
		expect([...store.hazards.keys()]).toEqual(['gdacs:TC-1']);
		store.disconnect();
	});

	it('excludes earthquake-type hazards by default and includes them once the filter re-enables them', async () => {
		const quake = makeHazard({
			id: 'gdacs:EQ-1',
			hazard_type: 'earthquake',
			source_type_code: 'EQ'
		});
		// A fresh Response per call: bodies are single-use streams, and this test
		// fetches the snapshot twice (initial connect, then setFilter).
		fetchMock.mockImplementation(async () => new Response(JSON.stringify({ hazards: [quake] })));
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		FakeEventSource.instances[0].open();
		await settle();

		expect(store.hazards.has('gdacs:EQ-1')).toBe(false);

		store.setFilter({ types: new Set([...store.filter.types, 'earthquake']) });
		await settle();
		expect(store.hazards.has('gdacs:EQ-1')).toBe(true);
		store.disconnect();
	});

	it('removes a hazard from the map when its alert level no longer matches the filter', async () => {
		fetchMock.mockImplementation(async () => new Response(JSON.stringify({ hazards: [] })));
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		FakeEventSource.instances[0].open();
		await settle();

		store.setFilter({ levels: new Set(['green']) });
		await settle();
		store.hazards.clear();
		FakeEventSource.instances[0].emit('new', makeHazard({ id: 'gdacs:TC-3', alert_level: 'red' }));
		expect(store.hazards.has('gdacs:TC-3')).toBe(false);

		FakeEventSource.instances[0].emit(
			'new',
			makeHazard({ id: 'gdacs:TC-4', alert_level: 'green' })
		);
		expect(store.hazards.has('gdacs:TC-4')).toBe(true);
		store.disconnect();
	});

	it('fetches hazard detail by splitting id into source and source_id', async () => {
		const detailHazard = makeHazard({ id: 'gdacs:EQ-1565193', source_id: 'EQ-1565193' });
		fetchMock.mockResolvedValueOnce(
			new Response(
				JSON.stringify({
					hazard: detailHazard,
					episodes: [
						{
							episode_id: '1732972',
							alert_level: 'green',
							alert_score: 1,
							severity_value: 5.5,
							severity_label: 'Magnitude 5.5M',
							from_at: detailHazard.onset_at,
							to_at: detailHazard.expires_at,
							modified_at: detailHazard.modified_at,
							has_geometry: true
						}
					]
				})
			)
		);
		const store = new HazardStore();
		const detail = await store.fetchDetail('gdacs:EQ-1565193');

		expect(fetchMock).toHaveBeenCalledWith('/api/v1/hazards/gdacs/EQ-1565193');
		expect(detail?.episodes).toHaveLength(1);
		expect(detail?.hazard.id).toBe('gdacs:EQ-1565193');
	});

	it('returns null when the detail request fails', async () => {
		fetchMock.mockResolvedValueOnce(new Response(null, { status: 404 }));
		const store = new HazardStore();

		const detail = await store.fetchDetail('gdacs:EQ-9999999');
		expect(detail).toBeNull();
	});

	it('subscribeRaw delivers the raw record even when the store filter would drop it', async () => {
		fetchMock.mockResolvedValue(new Response(JSON.stringify({ hazards: [] })));
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		const stream = FakeEventSource.instances[0];
		stream.open();
		await settle();

		const received: Hazard[] = [];
		const unsubscribe = store.subscribeRaw((event) => {
			if (event.type === 'new') received.push(event.record);
		});

		// The default filter excludes GDACS earthquake hazards; the timeline still needs them.
		const earthquakeHazard = makeHazard({ id: 'gdacs:EQ-1', hazard_type: 'earthquake' });
		stream.emit('new', earthquakeHazard);

		expect(received).toEqual([earthquakeHazard]);
		expect(store.hazards.has('gdacs:EQ-1')).toBe(false);
		unsubscribe();
		store.disconnect();
	});

	it('fetches and exposes data sources for attribution', async () => {
		fetchMock.mockResolvedValue(
			new Response(
				JSON.stringify({
					sources: [
						{
							id: 'gdacs',
							name: 'GDACS',
							homepage: 'https://www.gdacs.org/',
							license: 'Public domain (GDACS RSS); attribution requested',
							attribution_text: 'Global Disaster Awareness and Coordination System, GDACS',
							redistributable: false,
							priority: 80
						}
					]
				})
			)
		);
		const store = new HazardStore();
		await store.fetchSources('/api/v1/sources');

		expect(store.sources.get('gdacs')?.name).toBe('GDACS');
	});

	it('discards sources response if disconnect is called while request is in flight', async () => {
		let resolveSources: (res: Response) => void;
		const sourcesPromise = new Promise<Response>((resolve) => {
			resolveSources = resolve;
		});
		fetchMock.mockReturnValue(sourcesPromise);

		const store = new HazardStore();
		const fetchTask = store.fetchSources('/api/v1/sources');

		store.disconnect();

		resolveSources!(
			new Response(
				JSON.stringify({
					sources: [
						{
							id: 'late-gdacs',
							name: 'Late GDACS',
							homepage: '',
							license: '',
							attribution_text: '',
							redistributable: false,
							priority: 1
						}
					]
				})
			)
		);
		await fetchTask;

		expect(store.sources.has('late-gdacs')).toBe(false);
	});

	it('shares in-flight fetch across multiple concurrent calls', async () => {
		let resolveSources: (res: Response) => void;
		const sourcesPromise = new Promise<Response>((resolve) => {
			resolveSources = resolve;
		});
		fetchMock.mockReturnValue(sourcesPromise);

		const store1 = new HazardStore();
		const store2 = new HazardStore();

		const p1 = store1.fetchSources('/api/v1/sources');
		const p2 = store2.fetchSources('/api/v1/sources');

		expect(fetchMock).toHaveBeenCalledTimes(1);

		resolveSources!(
			new Response(
				JSON.stringify({
					sources: [
						{
							id: 'gdacs',
							name: 'GDACS',
							homepage: '',
							license: '',
							attribution_text: '',
							redistributable: false,
							priority: 80
						}
					]
				})
			)
		);

		await Promise.all([p1, p2]);

		expect(store1.sources.get('gdacs')?.name).toBe('GDACS');
		expect(store2.sources.get('gdacs')?.name).toBe('GDACS');
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});

	it('appends geometry=polyline query parameter to the snapshot URL only, not SSE or detail', async () => {
		fetchMock.mockResolvedValue(new Response(JSON.stringify({ hazards: [] })));
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/custom/hazards/stream');
		const stream = FakeEventSource.instances[0];
		expect(stream.url).toBe('/custom/hazards/stream');
		expect(stream.url).not.toContain('geometry=polyline');

		stream.open();
		await settle();

		expect(fetchMock).toHaveBeenCalledTimes(1);
		const snapshotUrl = fetchMock.mock.calls[0][0] as string;
		expect(snapshotUrl).toContain('/api/v1/hazards/recent');
		expect(snapshotUrl).toContain('geometry=polyline');

		// Check detail request does not have geometry=polyline
		fetchMock.mockResolvedValueOnce(new Response(null, { status: 404 }));
		await store.fetchDetail('gdacs:TC-1234');
		const detailUrl = fetchMock.mock.calls[1][0] as string;
		expect(detailUrl).toBe('/api/v1/hazards/gdacs/TC-1234');
		expect(detailUrl).not.toContain('geometry=polyline');

		store.disconnect();
	});

	it('decodes encoded polyline Polygon from snapshot before storing in hazards', async () => {
		const polygonGeoJson: GeoJSON.Polygon = {
			type: 'Polygon',
			coordinates: [
				[
					[120.5123, 14.5123],
					[121.5123, 14.5123],
					[121.5123, 15.5123],
					[120.5123, 15.5123],
					[120.5123, 14.5123]
				]
			]
		};
		const encodedGeom = encodePolygon(polygonGeoJson, 4);
		const rawHazard = makeHazard({
			id: 'gdacs:TC-101',
			primary_geometry: encodedGeom as unknown as GeoJSON.Polygon
		});

		fetchMock.mockResolvedValue(new Response(JSON.stringify({ hazards: [rawHazard] })));
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		FakeEventSource.instances[0].open();
		await settle();

		const stored = store.hazards.get('gdacs:TC-101');
		expect(stored).toBeDefined();
		expect(stored?.primary_geometry).toEqual(polygonGeoJson);
		expect(stored?.primary_geometry?.type).toBe('Polygon');
		expect(
			(stored?.primary_geometry as unknown as Record<string, unknown>).encoding
		).toBeUndefined();

		store.disconnect();
	});

	it('decodes encoded polyline MultiPolygon from snapshot before storing in hazards', async () => {
		const multiPolygonGeoJson: GeoJSON.MultiPolygon = {
			type: 'MultiPolygon',
			coordinates: [
				[
					[
						[10.0, 20.0],
						[11.0, 20.0],
						[11.0, 21.0],
						[10.0, 20.0]
					]
				],
				[
					[
						[30.0, 40.0],
						[31.0, 40.0],
						[31.0, 41.0],
						[30.0, 40.0]
					]
				]
			]
		};
		const encodedGeom = encodeMultiPolygon(multiPolygonGeoJson, 1);
		const rawHazard = makeHazard({
			id: 'gdacs:FL-202',
			hazard_type: 'flood',
			primary_geometry: encodedGeom as unknown as GeoJSON.MultiPolygon
		});

		fetchMock.mockResolvedValue(new Response(JSON.stringify({ hazards: [rawHazard] })));
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		FakeEventSource.instances[0].open();
		await settle();

		const stored = store.hazards.get('gdacs:FL-202');
		expect(stored).toBeDefined();
		expect(stored?.primary_geometry).toEqual(multiPolygonGeoJson);
		expect(stored?.primary_geometry?.type).toBe('MultiPolygon');

		store.disconnect();
	});

	it('preserves ordinary GeoJSON fixtures and null geometry without error (legacy fallback)', async () => {
		const ordinaryPoly: GeoJSON.Polygon = {
			type: 'Polygon',
			coordinates: [
				[
					[0, 0],
					[1, 0],
					[1, 1],
					[0, 0]
				]
			]
		};
		const hazardOrdinary = makeHazard({ id: 'gdacs:TC-legacy-1', primary_geometry: ordinaryPoly });
		const hazardNull = makeHazard({ id: 'gdacs:TC-legacy-2', primary_geometry: null });

		fetchMock.mockResolvedValue(
			new Response(JSON.stringify({ hazards: [hazardOrdinary, hazardNull] }))
		);
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		FakeEventSource.instances[0].open();
		await settle();

		expect(store.hazards.get('gdacs:TC-legacy-1')?.primary_geometry).toEqual(ordinaryPoly);
		expect(store.hazards.get('gdacs:TC-legacy-2')?.primary_geometry).toBeNull();

		store.disconnect();
	});

	it('sets snapshotError when snapshot contains malformed encoded geometry', async () => {
		const malformedHazard = makeHazard({
			id: 'gdacs:TC-bad',
			primary_geometry: {
				type: 'Polygon',
				encoding: 'polyline',
				precision: 4,
				coordinates: ['invalid_char_$$$']
			} as unknown as GeoJSON.Polygon
		});

		fetchMock.mockResolvedValue(new Response(JSON.stringify({ hazards: [malformedHazard] })));
		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		FakeEventSource.instances[0].open();
		await settle();

		expect(store.snapshotError).toBeTruthy();
		expect(store.hazards.has('gdacs:TC-bad')).toBe(false);

		store.disconnect();
	});

	it('preserves decoded GeoJSON across 304 Not Modified cache hits', async () => {
		const polyGeoJson: GeoJSON.Polygon = {
			type: 'Polygon',
			coordinates: [
				[
					[10.0, 20.0],
					[15.0, 20.0],
					[15.0, 25.0],
					[10.0, 20.0]
				]
			]
		};
		const encoded = encodePolygon(polyGeoJson, 1);
		const rawHazard = makeHazard({
			id: 'gdacs:TC-cached',
			primary_geometry: encoded as unknown as GeoJSON.Polygon
		});

		fetchMock
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ hazards: [rawHazard] }), {
					headers: { etag: '"etag-1"' }
				})
			)
			.mockResolvedValueOnce(new Response(null, { status: 304 }));

		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		FakeEventSource.instances[0].open();
		await settle();

		expect(store.hazards.get('gdacs:TC-cached')?.primary_geometry).toEqual(polyGeoJson);

		// Trigger resync which causes a 304 Not Modified
		FakeEventSource.instances[0].emit('resync', {});
		await settle();

		expect(store.hazards.get('gdacs:TC-cached')?.primary_geometry).toEqual(polyGeoJson);
		expect(store.snapshotError).toBeNull();

		store.disconnect();
	});

	it('invalidates pending snapshot on reconnect so deferred old response does not count as fresh baseline', async () => {
		let resolveOldSnapshot!: (res: Response) => void;
		const oldSnapshotPromise = new Promise<Response>((resolve) => {
			resolveOldSnapshot = resolve;
		});

		let resolveNewSnapshot!: (res: Response) => void;
		const newSnapshotPromise = new Promise<Response>((resolve) => {
			resolveNewSnapshot = resolve;
		});

		let fetchCalls = 0;
		fetchMock.mockImplementation(() => {
			fetchCalls++;
			if (fetchCalls === 1) return oldSnapshotPromise;
			return newSnapshotPromise;
		});

		const store = new HazardStore();
		await store.connect('/api/v1/hazards/recent', '/api/v1/hazards/stream');
		const stream = FakeEventSource.instances[0];

		// Initial connection starts snapshot 1
		stream.open();
		expect(fetchCalls).toBe(1);

		// Native reconnect triggers new open while snapshot 1 is still pending
		stream.open();
		expect(fetchCalls).toBe(2);

		// Subsequent resync coalesces into the new post-subscription snapshot
		stream.emit('resync', {});
		expect(fetchCalls).toBe(2);

		// SSE update arrives on the reconnected stream
		const streamHazard = makeHazard({
			id: 'gdacs:TC-1',
			title: 'Fresh SSE Cyclone',
			modified_at_ms: 50
		});
		stream.emit('new', streamHazard);
		expect(store.hazards.get('gdacs:TC-1')?.title).toBe('Fresh SSE Cyclone');

		// The old deferred snapshot (begun before reconnect) now resolves with stale data
		resolveOldSnapshot(
			new Response(
				JSON.stringify({
					hazards: [
						makeHazard({
							id: 'gdacs:TC-1',
							title: 'Stale Pre-Reconnect Cyclone',
							modified_at_ms: 10
						})
					]
				})
			)
		);
		await settle();

		// Old snapshot must NOT overwrite the fresh SSE event
		expect(store.hazards.get('gdacs:TC-1')?.title).toBe('Fresh SSE Cyclone');

		// Fresh post-reconnect snapshot resolves
		resolveNewSnapshot(
			new Response(
				JSON.stringify({
					hazards: [
						makeHazard({
							id: 'gdacs:TC-1',
							title: 'Fresh SSE Cyclone',
							modified_at_ms: 50
						})
					]
				})
			)
		);
		await settle();
		expect(store.hazards.get('gdacs:TC-1')?.title).toBe('Fresh SSE Cyclone');

		store.disconnect();
	});
});
