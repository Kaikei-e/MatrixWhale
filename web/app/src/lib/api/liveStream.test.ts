import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	DEFAULT_SHARED_STREAM_URL,
	openStreamChannel,
	resetSharedLiveStream,
	getSharedLiveStream
} from './liveStream';
import { AlertStore } from '$lib/alerts/store.svelte';
import { EarthquakeStore } from '$lib/earthquakes/store.svelte';
import { HazardStore } from '$lib/hazards/store.svelte';
import { encodePolygon } from '../../../scripts/geodata/geometry-transport.mjs';
import type { Alert } from '$lib/alerts/types';
import type { Earthquake } from '$lib/earthquakes/types';
import type { Hazard } from '$lib/hazards/types';

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

	removeEventListener(type: string, listener: (event: MessageEvent<string>) => void): void {
		const list = this.listeners.get(type);
		if (list) {
			this.listeners.set(
				type,
				list.filter((l) => l !== listener)
			);
		}
	}

	close(): void {
		this.closed = true;
	}

	open(): void {
		this.onopen?.(new Event('open'));
	}

	error(): void {
		this.onerror?.(new Event('error'));
	}

	emit(type: string, body: unknown, lastEventId = ''): void {
		const data = typeof body === 'string' ? body : JSON.stringify(body);
		for (const listener of this.listeners.get(type) ?? []) {
			listener(new MessageEvent(type, { data, lastEventId, origin: 'http://localhost' }));
		}
	}
}

function makeAlert(overrides: Partial<Alert> = {}): Alert {
	return {
		id: 'alert-1',
		source: 'noaa',
		source_id: 'a1',
		source_name: 'National Weather Service',
		attribution: 'NWS',
		countries: ['USA'],
		sender: 'test',
		sender_name: 'test',
		message_type: null,
		event: 'Tornado Warning',
		category: ['Met'],
		severity: 'Extreme',
		urgency: 'Immediate',
		certainty: 'Observed',
		headline: 'Test Headline',
		language: 'en-US',
		web: null,
		area_desc: 'Test Area',
		geocodes: [],
		geometry: null,
		sent: '2026-09-17T00:00:00Z',
		effective: null,
		onset: null,
		expires: null,
		ends: null,
		active_until: '2026-09-18T00:00:00Z',
		first_seen_at: '2026-09-17T00:00:00Z',
		last_seen_at: '2026-09-17T00:00:00Z',
		ended_at: null,
		end_reason: null,
		superseded_by: null,
		...overrides
	};
}

function makeEarthquake(overrides: Partial<Earthquake> = {}): Earthquake {
	const now = Date.now();
	return {
		id: 101,
		kind: 'earthquake',
		magnitude: 5.5,
		magnitude_type: 'mb',
		occurred_at: new Date(now).toISOString(),
		occurred_at_ms: now,
		updated_at: new Date(now).toISOString(),
		updated_at_ms: now,
		place: 'Test Location',
		title: 'M 5.5 - Test Location',
		status: 'reviewed',
		event_type: 'earthquake',
		tsunami: 0,
		significance: 300,
		alert: null,
		mmi: null,
		cdi: null,
		felt: null,
		nst: null,
		dmin: null,
		rms: null,
		gap: null,
		net: 'us',
		code: '101',
		url: null,
		detail: null,
		longitude: 139.7,
		latitude: 35.6,
		depth_km: 10,
		preferred_source: 'usgs',
		sources: ['usgs'],
		members: [],
		first_seen_at: new Date(now).toISOString(),
		last_seen_at: new Date(now).toISOString(),
		...overrides
	};
}

function makeHazard(overrides: Partial<Hazard> = {}): Hazard {
	const now = Date.now();
	return {
		id: 'gdacs:TC-101',
		source: 'gdacs',
		source_id: 'TC-101',
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
		description: 'Tropical cyclone description',
		countries: ['PHL'],
		report_url: null,
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

describe('Shared LiveStream Transport', () => {
	beforeEach(() => {
		resetSharedLiveStream();
		FakeEventSource.instances = [];
		vi.stubGlobal('EventSource', FakeEventSource);
		vi.stubGlobal(
			'fetch',
			vi.fn().mockImplementation((url: string) => {
				if (typeof url === 'string' && url.includes('/alerts/')) {
					return Promise.resolve(new Response(JSON.stringify([])));
				}
				return Promise.resolve(new Response(JSON.stringify({ earthquakes: [], hazards: [] })));
			})
		);
	});

	afterEach(() => {
		resetSharedLiveStream();
		vi.unstubAllGlobals();
	});

	it('replaces a pre-disconnect alert snapshot and coalesces the reconnect resync', async () => {
		let resolveOld!: (response: Response) => void;
		const oldResponse = new Promise<Response>((resolve) => {
			resolveOld = resolve;
		});
		const fetchMock = vi
			.fn()
			.mockReturnValueOnce(oldResponse)
			.mockResolvedValueOnce(new Response(JSON.stringify([makeAlert({ id: 'fresh' })])));
		vi.stubGlobal('fetch', fetchMock);
		const store = new AlertStore();
		await store.connect();
		const socket = FakeEventSource.instances[0];
		socket.open();
		expect(fetchMock).toHaveBeenCalledTimes(1);
		socket.error();
		socket.open();
		socket.emit('alerts.resync', {});
		expect(fetchMock).toHaveBeenCalledTimes(2);
		await vi.waitFor(() => expect(store.activeAlerts.has('fresh')).toBe(true));
		resolveOld(new Response(JSON.stringify([makeAlert({ id: 'stale' })])));
		await new Promise((resolve) => setTimeout(resolve, 0));
		expect([...store.activeAlerts.keys()]).toEqual(['fresh']);
		store.disconnect();
	});

	it('creates only a single EventSource socket across alerts, earthquakes, and hazards stores', async () => {
		const alertStore = new AlertStore();
		const earthquakeStore = new EarthquakeStore();
		const hazardStore = new HazardStore();

		await alertStore.connect();
		await earthquakeStore.connect();
		await hazardStore.connect();

		// All three stores must share exactly 1 underlying EventSource
		expect(FakeEventSource.instances.length).toBe(1);
		const sharedSocket = FakeEventSource.instances[0];
		expect(sharedSocket.url).toBe(DEFAULT_SHARED_STREAM_URL);
		expect(sharedSocket.closed).toBe(false);

		// Shared connection manager tracks 3 active channel subscriptions
		const manager = getSharedLiveStream();
		expect(manager.subscriberCount).toBe(3);

		alertStore.disconnect();
		earthquakeStore.disconnect();
		hazardStore.disconnect();
	});

	it('dispatches namespaced events to the respective stores over the single socket', async () => {
		const alertStore = new AlertStore();
		const earthquakeStore = new EarthquakeStore();
		const hazardStore = new HazardStore();

		await alertStore.connect();
		await earthquakeStore.connect();
		await hazardStore.connect();

		const sharedSocket = FakeEventSource.instances[0];
		sharedSocket.open();

		// Emit alerts.new
		const alert = makeAlert({ id: 'alert-shared-1', headline: 'Shared Alert' });
		sharedSocket.emit('alerts.new', alert);
		await vi.waitFor(() =>
			expect(alertStore.activeAlerts.get('alert-shared-1')?.headline).toBe('Shared Alert')
		);

		// Emit earthquakes.new
		const eq = makeEarthquake({ id: 555, place: 'Shared Quake' });
		sharedSocket.emit('earthquakes.new', eq);
		expect(earthquakeStore.earthquakes.get(555)?.place).toBe('Shared Quake');

		// Emit hazards.new
		const hz = makeHazard({ id: 'gdacs:TC-555', title: 'Shared Hazard' });
		sharedSocket.emit('hazards.new', hz);
		expect(hazardStore.hazards.get('gdacs:TC-555')?.title).toBe('Shared Hazard');

		alertStore.disconnect();
		earthquakeStore.disconnect();
		hazardStore.disconnect();
	});

	it('manages refcounted teardown and only closes the network connection when the final subscriber disconnects', async () => {
		const alertStore = new AlertStore();
		const earthquakeStore = new EarthquakeStore();
		const hazardStore = new HazardStore();

		await alertStore.connect();
		await earthquakeStore.connect();
		await hazardStore.connect();

		const sharedSocket = FakeEventSource.instances[0];
		expect(sharedSocket.closed).toBe(false);

		// Disconnect first store (alerts) -> refcount 2, socket stays open
		alertStore.disconnect();
		expect(sharedSocket.closed).toBe(false);
		expect(getSharedLiveStream().subscriberCount).toBe(2);

		// Disconnect second store (earthquakes) -> refcount 1, socket stays open
		earthquakeStore.disconnect();
		expect(sharedSocket.closed).toBe(false);
		expect(getSharedLiveStream().subscriberCount).toBe(1);

		// Disconnect final store (hazards) -> refcount 0, socket closes!
		hazardStore.disconnect();
		expect(sharedSocket.closed).toBe(true);
		expect(getSharedLiveStream().subscriberCount).toBe(0);

		// Next subscriber creates a fresh EventSource
		await alertStore.connect();
		expect(FakeEventSource.instances.length).toBe(2);
		expect(FakeEventSource.instances[1].closed).toBe(false);

		alertStore.disconnect();
		expect(FakeEventSource.instances[1].closed).toBe(true);
	});

	it('notifies late subscribers via microtask if the shared stream is already open', async () => {
		const store1 = new AlertStore();
		await store1.connect();

		const sharedSocket = FakeEventSource.instances[0];
		sharedSocket.open();
		expect(getSharedLiveStream().isOpen).toBe(true);

		// Late subscriber: earthquakeStore connects to an already open stream
		const store2 = new EarthquakeStore();
		let openCalled = false;
		const channel = openStreamChannel('earthquakes');
		channel.onopen = () => {
			openCalled = true;
		};

		expect(openCalled).toBe(false);

		// Wait for microtask
		await Promise.resolve();
		expect(openCalled).toBe(true);

		channel.close();
		store1.disconnect();
	});

	it('guards late subscriber open notification if channel is closed before microtask runs', async () => {
		const store1 = new AlertStore();
		await store1.connect();

		const sharedSocket = FakeEventSource.instances[0];
		sharedSocket.open();

		let openCalled = false;
		const channel = openStreamChannel('earthquakes');
		channel.onopen = () => {
			openCalled = true;
		};

		// Close immediately in same synchronous turn
		channel.close();

		await Promise.resolve();
		expect(openCalled).toBe(false);

		store1.disconnect();
	});

	it('forwards MessageEvent lastEventId and data without swallowing listener exceptions', () => {
		const channel = openStreamChannel('alerts');
		let receivedLastEventId = '';
		let receivedData = '';

		channel.addEventListener('alert.new', (event) => {
			receivedLastEventId = event.lastEventId;
			receivedData = event.data;
		});

		const sharedSocket = FakeEventSource.instances[0];
		sharedSocket.emit('alerts.new', { id: 'evt-1' }, 'custom-event-id-99');

		expect(receivedLastEventId).toBe('custom-event-id-99');
		expect(receivedData).toContain('evt-1');

		// Verify exceptions are not swallowed
		channel.addEventListener('alert.update', () => {
			throw new Error('deliberate-listener-error');
		});

		expect(() => {
			sharedSocket.emit('alerts.update', { id: 'evt-1' });
		}).toThrow('deliberate-listener-error');

		channel.close();
	});

	it('restarts a closed/stuck stream via watchdog without leaking listeners', async () => {
		const store = new EarthquakeStore();
		await store.connect();

		const socket1 = FakeEventSource.instances[0];
		socket1.open();
		expect(store.connected).toBe('open');

		// Trigger restart (e.g. from watchdog)
		const channel = openStreamChannel('earthquakes');
		channel.restart();

		expect(socket1.closed).toBe(true);
		expect(FakeEventSource.instances.length).toBe(2);

		const socket2 = FakeEventSource.instances[1];
		expect(socket2.closed).toBe(false);

		// Re-opening new socket delivers open event
		socket2.open();
		expect(store.connected).toBe('open');

		channel.close();
		store.disconnect();
		expect(socket2.closed).toBe(true);
	});

	it('decodes hazard polyline geometry on SSE events preserving exact coordinates and metadata', async () => {
		const hazardStore = new HazardStore();
		await hazardStore.connect();

		const sharedSocket = FakeEventSource.instances[0];
		sharedSocket.open();

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
			id: 'gdacs:TC-geom-test',
			title: 'Exact Geo Cyclone',
			alert_level: 'red',
			primary_geometry: encodedGeom as unknown as GeoJSON.Polygon
		});

		let rawDelivered: Hazard | null = null;
		const unsubRaw = hazardStore.subscribeRaw((event) => {
			if (event.type === 'new') rawDelivered = event.record;
		});

		sharedSocket.emit('hazards.new', rawHazard);

		// Raw timeline listener must receive decoded GeoJSON
		expect(rawDelivered).not.toBeNull();
		expect(rawDelivered!.id).toBe('gdacs:TC-geom-test');
		expect(rawDelivered!.title).toBe('Exact Geo Cyclone');
		expect(rawDelivered!.alert_level).toBe('red');
		expect(rawDelivered!.primary_geometry).toEqual(polygonGeoJson);
		expect(
			(rawDelivered!.primary_geometry as unknown as Record<string, unknown>).encoding
		).toBeUndefined();

		// Store merge must also receive decoded GeoJSON
		const stored = hazardStore.hazards.get('gdacs:TC-geom-test');
		expect(stored).toBeDefined();
		expect(stored?.title).toBe('Exact Geo Cyclone');
		expect(stored?.primary_geometry).toEqual(polygonGeoJson);

		unsubRaw();
		hazardStore.disconnect();
	});

	it('creates dedicated connection when an explicit custom stream URL is passed', async () => {
		const alertStore = new AlertStore();
		await alertStore.connect('/api/v1/alerts/active'); // shared default

		const customAlertStore = new AlertStore();
		await customAlertStore.connect('/custom/snapshot', '/custom/stream'); // explicit custom URL

		// Two distinct EventSource instances: 1 shared, 1 dedicated custom
		expect(FakeEventSource.instances.length).toBe(2);
		expect(FakeEventSource.instances[0].url).toBe(DEFAULT_SHARED_STREAM_URL);
		expect(FakeEventSource.instances[1].url).toBe('/custom/stream');

		// Closing the custom store does not affect the shared stream
		customAlertStore.disconnect();
		expect(FakeEventSource.instances[1].closed).toBe(true);
		expect(FakeEventSource.instances[0].closed).toBe(false);

		alertStore.disconnect();
		expect(FakeEventSource.instances[0].closed).toBe(true);
	});

	it('deduplicates in-flight snapshots when native reconnect triggers open + resync', async () => {
		let fetchCallCount = 0;
		let resolveSnapshot: (res: Response) => void;
		const snapshotPromise = new Promise<Response>((resolve) => {
			resolveSnapshot = resolve;
		});

		vi.stubGlobal(
			'fetch',
			vi.fn().mockImplementation(() => {
				fetchCallCount++;
				return snapshotPromise;
			})
		);

		const earthquakeStore = new EarthquakeStore();
		await earthquakeStore.connect();

		const sharedSocket = FakeEventSource.instances[0];

		// Native reconnect triggers open and immediately resync
		sharedSocket.open();
		sharedSocket.emit('earthquakes.resync', {});

		// Despite both open and resync firing, only 1 fetch was started
		expect(fetchCallCount).toBe(1);

		// Resolve snapshot
		resolveSnapshot!(new Response(JSON.stringify({ earthquakes: [makeEarthquake({ id: 999 })] })));
		for (let i = 0; i < 8; i++) await Promise.resolve();

		expect(earthquakeStore.earthquakes.has(999)).toBe(true);
		earthquakeStore.disconnect();
	});

	it('coalesces multiple watchdog restarts while a new socket is connecting into a single transport generation', async () => {
		const store1 = new EarthquakeStore();
		const store2 = new HazardStore();
		await store1.connect();
		await store2.connect();

		const socket1 = FakeEventSource.instances[0];
		socket1.open();

		const manager = getSharedLiveStream();

		// Store 1 watchdog triggers restart
		const ch1 = openStreamChannel('earthquakes');
		ch1.restart();

		expect(FakeEventSource.instances.length).toBe(2);
		expect(manager.isConnecting).toBe(true);

		// Store 2 watchdog triggers restart while socket 2 is still connecting
		const ch2 = openStreamChannel('hazards');
		ch2.restart();

		// MUST coalesce: no third socket created!
		expect(FakeEventSource.instances.length).toBe(2);

		// Socket 2 finishes connecting
		const socket2 = FakeEventSource.instances[1];
		socket2.open();
		expect(manager.isConnecting).toBe(false);

		ch1.close();
		ch2.close();
		store1.disconnect();
		store2.disconnect();
	});

	it('notifies all active channel subscribers of reconnect so watchdogs reset', async () => {
		const store1 = new EarthquakeStore();
		const store2 = new HazardStore();
		await store1.connect();
		await store2.connect();

		const socket1 = FakeEventSource.instances[0];
		socket1.open();
		expect(store1.connected).toBe('open');
		expect(store2.connected).toBe('open');

		// Watchdog triggers restart
		const channel = openStreamChannel('earthquakes');
		channel.restart();

		// Both stores must be notified of reconnect and transition to connecting
		expect(store1.connected).toBe('connecting');
		expect(store2.connected).toBe('connecting');

		const socket2 = FakeEventSource.instances[1];
		socket2.open();
		expect(store1.connected).toBe('open');
		expect(store2.connected).toBe('open');

		channel.close();
		store1.disconnect();
		store2.disconnect();
	});

	it('dedicated channel add/remove/add does not duplicate listeners and suppresses events from old sockets', async () => {
		const channel = openStreamChannel('alerts', '/custom/stream');
		const socket1 = FakeEventSource.instances[0] as FakeEventSource;

		let calls1 = 0;
		const listener1 = () => {
			calls1++;
		};

		// Add then remove
		channel.addEventListener('custom.evt', listener1);
		channel.removeEventListener('custom.evt', listener1);

		// Add new listener for the same type
		let calls2 = 0;
		const listener2 = () => {
			calls2++;
		};
		channel.addEventListener('custom.evt', listener2);

		// Emit on socket1
		socket1.emit('custom.evt', { foo: 'bar' });
		// listener2 must be called exactly ONCE (not stacked)
		expect(calls1).toBe(0);
		expect(calls2).toBe(1);

		// Restart dedicated channel -> closes socket1, creates socket2
		channel.restart();
		expect(FakeEventSource.instances.length).toBe(2);
		const socket2 = FakeEventSource.instances[1] as FakeEventSource;

		// Emitting on old closed socket1 must be suppressed!
		socket1.emit('custom.evt', { foo: 'bar' });
		expect(calls2).toBe(1);

		// Emitting on active socket2 must be received
		socket2.emit('custom.evt', { foo: 'bar' });
		expect(calls2).toBe(2);

		channel.close();
	});

	it('defers alert snapshot on shared stream until open, and refetches snapshot on shared watchdog restart without resync', async () => {
		let alertsFetched = 0;
		vi.stubGlobal(
			'fetch',
			vi.fn().mockImplementation((url: string) => {
				if (typeof url === 'string' && url.includes('/alerts/')) {
					alertsFetched++;
					return Promise.resolve(
						new Response(JSON.stringify([makeAlert({ id: `alert-${alertsFetched}` })]))
					);
				}
				return Promise.resolve(new Response(JSON.stringify({ earthquakes: [], hazards: [] })));
			})
		);

		const alertStore = new AlertStore();
		await alertStore.connect();

		// On shared stream, snapshot does NOT fetch before open
		expect(alertsFetched).toBe(0);

		const socket1 = FakeEventSource.instances[0];
		socket1.open();
		await vi.waitFor(() => expect(alertStore.activeAlerts.size).toBeGreaterThan(0));

		// Snapshot fetched after open
		expect(alertsFetched).toBe(1);
		expect(alertStore.activeAlerts.has('alert-1')).toBe(true);

		// Watchdog restart occurs (fresh socket, no Last-Event-ID, no resync event)
		const channel = openStreamChannel('alerts');
		channel.restart();

		const socket2 = FakeEventSource.instances[1];
		socket2.open();
		await vi.waitFor(() => expect(alertStore.activeAlerts.has('alert-2')).toBe(true));

		// Must have refetched snapshot on shared open even without resync event!
		expect(alertsFetched).toBe(2);
		expect(alertStore.activeAlerts.has('alert-2')).toBe(true);

		channel.close();
		alertStore.disconnect();
	});

	it('strictly enforces the backend namespaced events contract and drops unnamespaced new/update fallbacks', async () => {
		const earthquakeStore = new EarthquakeStore();
		const hazardStore = new HazardStore();
		await earthquakeStore.connect();
		await hazardStore.connect();

		const sharedSocket = FakeEventSource.instances[0];
		sharedSocket.open();

		// Emitting unnamespaced 'new' or 'update' must NOT match either store on shared socket
		sharedSocket.emit('new', makeEarthquake({ id: 888 }));
		expect(earthquakeStore.earthquakes.has(888)).toBe(false);

		sharedSocket.emit('new', makeHazard({ id: 'hz-888' }));
		expect(hazardStore.hazards.has('hz-888')).toBe(false);

		// Emitting namespaced events works correctly
		sharedSocket.emit('earthquakes.new', makeEarthquake({ id: 888 }));
		expect(earthquakeStore.earthquakes.has(888)).toBe(true);

		sharedSocket.emit('hazards.new', makeHazard({ id: 'hz-888' }));
		expect(hazardStore.hazards.has('hz-888')).toBe(true);

		earthquakeStore.disconnect();
		hazardStore.disconnect();
	});
});
