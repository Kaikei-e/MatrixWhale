import { afterEach, beforeEach, describe, it, expect, vi } from 'vitest';
import { AlertStore, nextBlinkAfterArrival } from './store.svelte';
import type { Alert } from './types';

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

	emit(type: string, body: unknown): void {
		for (const listener of this.listeners.get(type) ?? []) {
			listener(new MessageEvent(type, { data: JSON.stringify(body) }));
		}
	}
}

function makeAlert(overrides: Partial<Alert>): Alert {
	return {
		id: 'a1',
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
		headline: null,
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

describe('nextBlinkAfterArrival', () => {
	it('is persistent for Extreme when not acknowledged', () => {
		expect(nextBlinkAfterArrival('Extreme', false)).toBe('persistent');
	});

	it('is persistent for Severe when not acknowledged', () => {
		expect(nextBlinkAfterArrival('Severe', false)).toBe('persistent');
	});

	it('is static for Moderate/Minor/Unknown regardless of acknowledgement', () => {
		expect(nextBlinkAfterArrival('Moderate', false)).toBe('static');
		expect(nextBlinkAfterArrival('Minor', false)).toBe('static');
		expect(nextBlinkAfterArrival('Unknown', false)).toBe('static');
	});

	it('is static for any severity once acknowledged', () => {
		expect(nextBlinkAfterArrival('Extreme', true)).toBe('static');
		expect(nextBlinkAfterArrival('Severe', true)).toBe('static');
	});
});

describe('AlertStore derived state', () => {
	it('countsBySeverity counts active alerts per severity', () => {
		const store = new AlertStore();
		store.activeAlerts.set('a1', makeAlert({ id: 'a1', severity: 'Extreme' }));
		store.activeAlerts.set('a2', makeAlert({ id: 'a2', severity: 'Extreme' }));
		store.activeAlerts.set('a3', makeAlert({ id: 'a3', severity: 'Minor' }));

		expect(store.countsBySeverity).toEqual({
			Extreme: 2,
			Severe: 0,
			Moderate: 0,
			Minor: 1,
			Unknown: 0
		});
	});

	it('zoneSeverity keeps the highest severity per UGC from geocodes', () => {
		const store = new AlertStore();
		store.activeAlerts.set(
			'a1',
			makeAlert({
				id: 'a1',
				severity: 'Minor',
				geocodes: [{ name: 'UGC', value: 'OKC143' }]
			})
		);
		store.activeAlerts.set(
			'a2',
			makeAlert({
				id: 'a2',
				severity: 'Extreme',
				geocodes: [{ name: 'UGC', value: 'OKC143' }]
			})
		);

		expect(store.zoneSeverity.get('OKC143')).toBe('Extreme');
	});

	it('filters alerts by default severities and country', () => {
		const store = new AlertStore();
		store.activeAlerts.set('a1', makeAlert({ id: 'a1', severity: 'Extreme', countries: ['USA'] }));
		store.activeAlerts.set(
			'a2',
			makeAlert({ id: 'a2', event: 'Frost Advisory', severity: 'Minor', countries: ['USA'] })
		);
		store.activeAlerts.set(
			'a3',
			makeAlert({
				id: 'a3',
				source: 'cap-dwd',
				event: 'Wind Warning',
				severity: 'Moderate',
				countries: ['DEU']
			})
		);

		// Default severity filter is Extreme, Severe, Moderate; country is 'all'
		expect(store.filtered.map((a) => a.id)).toEqual(['a1', 'a3']);

		// Select country DEU
		store.countryFilter = 'DEU';
		expect(store.filtered.map((a) => a.id)).toEqual(['a3']);

		// Toggle Minor on
		store.toggleSeverity('Minor');
		store.countryFilter = 'all';
		expect(store.filtered.map((a) => a.id)).toEqual(['a1', 'a3', 'a2']);
	});

	it('hasAnyBlinking is false when stopAll is set', () => {
		const store = new AlertStore();
		store.blink.set('a1', { mode: 'arrival', until: 1000 });
		store.stopAll = true;

		expect(store.hasAnyBlinking).toBe(false);
	});

	it('hasAnyBlinking is false when reducedMotion is set', () => {
		const store = new AlertStore();
		store.blink.set('a1', { mode: 'persistent', until: null });
		store.reducedMotion = true;

		expect(store.hasAnyBlinking).toBe(false);
	});

	it('hasAnyBlinking is true when an alert is arriving/persistent/updating', () => {
		const store = new AlertStore();
		store.blink.set('a1', { mode: 'static', until: null });
		store.blink.set('a2', { mode: 'update', until: 500 });

		expect(store.hasAnyBlinking).toBe(true);
	});

	it('sorted orders active alerts by NWS priority', () => {
		const store = new AlertStore();
		store.activeAlerts.set(
			'a1',
			makeAlert({ id: 'a1', event: 'Flood Advisory', sent: '2026-09-17T10:00:00Z' })
		);
		store.activeAlerts.set(
			'a2',
			makeAlert({ id: 'a2', event: 'Tornado Warning', sent: '2026-09-17T09:00:00Z' })
		);

		expect(store.sorted.map((a) => a.id)).toEqual(['a2', 'a1']);
	});
});

describe('AlertStore.subscribeRaw', () => {
	beforeEach(() => {
		FakeEventSource.instances = [];
		vi.stubGlobal('EventSource', FakeEventSource);
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify([]))));
	});

	afterEach(() => {
		vi.unstubAllGlobals();
	});

	it('delivers every raw lifecycle event with its record, independent of acknowledgement', async () => {
		const store = new AlertStore();
		await store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');
		const stream = FakeEventSource.instances[0];

		const received: Array<{ type: string; id?: string }> = [];
		const unsubscribe = store.subscribeRaw((event) => {
			received.push({
				type: event.type,
				id: event.type === 'resync' ? undefined : event.record.id
			});
		});

		const alert = makeAlert({ id: 'raw-1', severity: 'Minor' });
		store.activeAlerts.set(alert.id, alert);
		store.acknowledge('raw-1');
		stream.emit('alert.new', alert);
		stream.emit('alert.update', alert);
		stream.emit('alert.ended', { ...alert, ended_at: '2026-09-18T00:00:00Z' });

		expect(received).toEqual([
			{ type: 'new', id: 'raw-1' },
			{ type: 'update', id: 'raw-1' },
			{ type: 'ended', id: 'raw-1' }
		]);
		unsubscribe();
		store.disconnect();
	});

	it('ignores ended event for alerts that are not active', async () => {
		const store = new AlertStore();
		await store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');
		const stream = FakeEventSource.instances[0];

		const inactiveAlert = makeAlert({ id: 'inactive-1', severity: 'Extreme' });
		stream.emit('alert.ended', inactiveAlert);

		expect(store.activeAlerts.has('inactive-1')).toBe(false);
		expect(store.blink.has('inactive-1')).toBe(false);
		store.disconnect();
	});

	it('handles resync by refetching snapshot while preserving events in flight', async () => {
		const first = makeAlert({ id: 'snap-1', severity: 'Extreme' });
		const second = makeAlert({ id: 'snap-2', severity: 'Severe' });

		let resolveSecondFetch: (value: Response) => void;
		const secondFetchPromise = new Promise<Response>((resolve) => {
			resolveSecondFetch = resolve;
		});

		const mockFetch = vi
			.fn()
			.mockResolvedValueOnce(new Response(JSON.stringify([first, second])))
			.mockImplementationOnce(() => secondFetchPromise);

		vi.stubGlobal('fetch', mockFetch);

		const store = new AlertStore();
		await store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');
		const stream = FakeEventSource.instances[0];

		expect(store.activeAlerts.size).toBe(2);

		// Trigger resync
		stream.emit('resync', {});

		// While second fetch is in flight, an ended event arrives for snap-2
		stream.emit('alert.ended', { ...second, ended_at: '2026-09-18T00:00:00Z' });

		// Complete the second fetch (which returns [first, second])
		resolveSecondFetch!(new Response(JSON.stringify([first, second])));
		for (let i = 0; i < 10; i++) await Promise.resolve();

		// snap-2 had ended while snapshot was in flight, so it should be in fading state and deleted after timeout
		expect(store.blink.get('snap-2')?.mode).toBe('fading');

		store.disconnect();
	});

	it('resets countryFilter to "all" when the selected country disappears', () => {
		const store = new AlertStore();
		store.activeAlerts.set('a1', makeAlert({ id: 'a1', countries: ['FRA'], severity: 'Extreme' }));
		store.activeAlerts.set('a2', makeAlert({ id: 'a2', countries: ['DEU'], severity: 'Minor' }));

		store.countryFilter = 'FRA';
		expect(store.countryFilter).toBe('FRA');

		// Toggle off Extreme: FRA alerts are no longer in activeCountries matching severity filter
		store.toggleSeverity('Extreme');
		expect(store.countryFilter).toBe('all');
	});

	it('zoneSeverity reflects the filtered alerts rather than all active alerts', () => {
		const store = new AlertStore();
		store.activeAlerts.set(
			'a1',
			makeAlert({
				id: 'a1',
				severity: 'Minor',
				countries: ['USA'],
				geocodes: [{ name: 'UGC', value: 'OKZ140' }]
			})
		);
		store.activeAlerts.set(
			'a2',
			makeAlert({
				id: 'a2',
				severity: 'Extreme',
				countries: ['FRA'],
				geocodes: [{ name: 'UGC', value: 'FRZ001' }]
			})
		);
		store.activeAlerts.set(
			'a3',
			makeAlert({
				id: 'a3',
				severity: 'Extreme',
				countries: ['DEU'],
				geocodes: [{ name: 'UGC', value: 'DEZ002' }]
			})
		);

		// Default severity filter is Extreme, Severe, Moderate.
		// a1 is Minor, so not in filtered. a2 (FRZ001) and a3 (DEZ002) are in filtered.
		expect(store.zoneSeverity.has('OKZ140')).toBe(false);
		expect(store.zoneSeverity.get('FRZ001')).toBe('Extreme');
		expect(store.zoneSeverity.get('DEZ002')).toBe('Extreme');

		// Filter by country: FRA only
		store.countryFilter = 'FRA';
		expect(store.zoneSeverity.has('FRZ001')).toBe(true);
		expect(store.zoneSeverity.has('DEZ002')).toBe(false);

		// Reset to all and enable Minor: a1 now matches
		store.countryFilter = 'all';
		store.toggleSeverity('Minor');
		expect(store.zoneSeverity.get('OKZ140')).toBe('Minor');
	});

	it('opens the stream first and buffers events that arrive before snapshot finishes', async () => {
		let resolveSnapshot: (res: Response) => void;
		const snapshotPromise = new Promise<Response>((resolve) => {
			resolveSnapshot = resolve;
		});
		vi.stubGlobal(
			'fetch',
			vi.fn().mockImplementation(() => snapshotPromise)
		);

		const store = new AlertStore();
		const connectPromise = store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');

		expect(FakeEventSource.instances.length).toBe(1);
		const stream = FakeEventSource.instances[0];

		const bufferedAlert = makeAlert({
			id: 'race-1',
			severity: 'Extreme',
			last_seen_at: '2026-09-17T12:00:00Z'
		});
		stream.emit('alert.new', bufferedAlert);

		expect(store.activeAlerts.has('race-1')).toBe(false);

		const snapshotAlert = makeAlert({
			id: 'snap-1',
			severity: 'Severe',
			last_seen_at: '2026-09-17T11:00:00Z'
		});
		resolveSnapshot!(new Response(JSON.stringify([snapshotAlert])));
		await connectPromise;

		expect(store.activeAlerts.has('snap-1')).toBe(true);
		expect(store.activeAlerts.has('race-1')).toBe(true);
		store.disconnect();
	});

	it('bails out of connect and closes EventSource if disconnect runs while snapshot is in flight', async () => {
		let resolveSnapshot: (res: Response) => void;
		const snapshotPromise = new Promise<Response>((resolve) => {
			resolveSnapshot = resolve;
		});
		vi.stubGlobal(
			'fetch',
			vi.fn().mockImplementation(() => snapshotPromise)
		);

		const store = new AlertStore();
		const connectPromise = store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');

		expect(FakeEventSource.instances.length).toBe(1);
		const stream = FakeEventSource.instances[0];
		expect(stream.closed).toBe(false);

		store.disconnect();
		expect(stream.closed).toBe(true);
		expect(store.connected).toBe('closed');

		resolveSnapshot!(new Response(JSON.stringify([makeAlert({ id: 'abandoned-1' })])));
		await connectPromise;

		expect(store.activeAlerts.size).toBe(0);
		expect(store.connected).toBe('closed');

		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue(new Response(JSON.stringify([makeAlert({ id: 'reconnect-1' })])))
		);
		await store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');
		expect(FakeEventSource.instances.length).toBe(2);
		expect(store.activeAlerts.has('reconnect-1')).toBe(true);
		store.disconnect();
	});

	it('skips buffered records whose last_seen_at is older than the snapshot row', async () => {
		let resolveSnapshot: (res: Response) => void;
		const snapshotPromise = new Promise<Response>((resolve) => {
			resolveSnapshot = resolve;
		});
		vi.stubGlobal(
			'fetch',
			vi.fn().mockImplementation(() => snapshotPromise)
		);

		const store = new AlertStore();
		const connectPromise = store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');
		const stream = FakeEventSource.instances[0];

		const olderEvent = makeAlert({
			id: 'alert-1',
			headline: 'Old Headline',
			last_seen_at: '2026-09-17T10:00:00Z'
		});
		stream.emit('alert.update', olderEvent);

		const newerSnapshot = makeAlert({
			id: 'alert-1',
			headline: 'New Snapshot Headline',
			last_seen_at: '2026-09-17T11:00:00Z'
		});
		resolveSnapshot!(new Response(JSON.stringify([newerSnapshot])));
		await connectPromise;

		expect(store.activeAlerts.get('alert-1')?.headline).toBe('New Snapshot Headline');
		store.disconnect();
	});

	it('successful snapshot clears previous alertTimers and guards timer callbacks', async () => {
		vi.useFakeTimers();
		try {
			const store = new AlertStore();
			const alert1 = makeAlert({ id: 'timer-1', severity: 'Extreme' });
			store.activeAlerts.set('timer-1', alert1);
			store.blink.set('timer-1', { mode: 'arrival', until: 5000 });

			vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify([]))));
			await store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');

			vi.advanceTimersByTime(10000);

			expect(store.blink.has('timer-1')).toBe(false);
			store.disconnect();
		} finally {
			vi.useRealTimers();
		}
	});

	it('countryFilter actually resets to "all" and does not snap back when new alerts arrive', () => {
		const store = new AlertStore();
		store.activeAlerts.set('a1', makeAlert({ id: 'a1', countries: ['FRA'], severity: 'Extreme' }));
		store.countryFilter = 'FRA';
		expect(store.countryFilter).toBe('FRA');

		store.toggleSeverity('Extreme');
		expect(store.countryFilter).toBe('all');

		const moderateFra = makeAlert({ id: 'a2', countries: ['FRA'], severity: 'Moderate' });
		store.activeAlerts.set('a2', moderateFra);
		store.toggleSeverity('Moderate');
		expect(store.countryFilter).toBe('all');
	});

	it('acknowledge does not clear removal timer or change blink when alert is fading after ended', async () => {
		vi.useFakeTimers();
		try {
			const store = new AlertStore();
			await store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');
			const stream = FakeEventSource.instances[0];

			const alert = makeAlert({ id: 'fading-1', severity: 'Extreme' });
			store.activeAlerts.set(alert.id, alert);

			stream.emit('alert.ended', { ...alert, ended_at: '2026-09-18T00:00:00Z' });
			expect(store.blink.get('fading-1')?.mode).toBe('fading');

			store.acknowledge('fading-1');
			expect(store.blink.get('fading-1')?.mode).toBe('fading');

			vi.advanceTimersByTime(1100);

			expect(store.activeAlerts.has('fading-1')).toBe(false);
			expect(store.blink.has('fading-1')).toBe(false);

			store.disconnect();
		} finally {
			vi.useRealTimers();
		}
	});

	it('does not catch errors thrown inside listeners or apply code in SSE handlers', async () => {
		const store = new AlertStore();
		await store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');
		const stream = FakeEventSource.instances[0];

		store.subscribeRaw(() => {
			throw new Error('listener failure');
		});

		const alert = makeAlert({ id: 'throw-1' });
		expect(() => stream.emit('alert.new', alert)).toThrow('listener failure');

		store.disconnect();
	});

	it('does not abort snapshot when chunks arrive steadily even if total duration exceeds 10 seconds', async () => {
		vi.useFakeTimers();
		try {
			const alert1 = makeAlert({ id: 'slow-1', severity: 'Extreme' });
			const fullJson = JSON.stringify([alert1]);
			const half = Math.floor(fullJson.length / 2);
			const chunk1 = fullJson.slice(0, half);
			const chunk2 = fullJson.slice(half);

			const encoder = new TextEncoder();
			let controllerRef: ReadableStreamDefaultController<Uint8Array>;
			const stream = new ReadableStream<Uint8Array>({
				start(controller) {
					controllerRef = controller;
				}
			});

			vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(stream)));

			const store = new AlertStore();
			const connectPromise = store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');

			// Let fetch resolve and start reading the body
			await vi.advanceTimersByTimeAsync(100);

			// First chunk at 6 seconds
			await vi.advanceTimersByTimeAsync(6000);
			controllerRef!.enqueue(encoder.encode(chunk1));

			// Second chunk at 12 seconds total (6 seconds since last chunk) - would have aborted with 10s fixed timeout!
			await vi.advanceTimersByTimeAsync(6000);
			controllerRef!.enqueue(encoder.encode(chunk2));
			controllerRef!.close();

			await vi.advanceTimersByTimeAsync(100);
			await connectPromise;

			expect(store.snapshotError).toBeNull();
			expect(store.activeAlerts.has('slow-1')).toBe(true);
			store.disconnect();
		} finally {
			vi.useRealTimers();
		}
	});

	it('aborts snapshot if chunk arrival stalls for 10 seconds of inactivity', async () => {
		vi.useFakeTimers();
		try {
			const encoder = new TextEncoder();
			let controllerRef: ReadableStreamDefaultController<Uint8Array>;
			const stream = new ReadableStream<Uint8Array>({
				start(controller) {
					controllerRef = controller;
				}
			});

			vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(stream)));

			const store = new AlertStore();
			const connectPromise = store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');

			await vi.advanceTimersByTimeAsync(100);

			// First chunk arrives
			controllerRef!.enqueue(encoder.encode('['));

			// Stalls for 10001 ms without any data
			await vi.advanceTimersByTimeAsync(10001);
			await connectPromise;

			expect(store.snapshotError).toContain('timed out due to inactivity');
			expect(store.activeAlerts.size).toBe(0);
			store.disconnect();
		} finally {
			vi.useRealTimers();
		}
	});

	it('successfully recovers via retrySnapshot after an idle timeout', async () => {
		vi.useFakeTimers();
		try {
			const alert1 = makeAlert({ id: 'retry-1', severity: 'Extreme' });
			const encoder = new TextEncoder();

			let controllerRef: ReadableStreamDefaultController<Uint8Array>;
			const stalledStream = new ReadableStream<Uint8Array>({
				start(controller) {
					controllerRef = controller;
				}
			});

			const fetchMock = vi
				.fn()
				.mockResolvedValueOnce(new Response(stalledStream))
				.mockResolvedValueOnce(new Response(JSON.stringify([alert1])));

			vi.stubGlobal('fetch', fetchMock);

			const store = new AlertStore();
			const connectPromise = store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');

			await vi.advanceTimersByTimeAsync(100);
			controllerRef!.enqueue(encoder.encode('['));

			// Advance beyond idle timeout
			await vi.advanceTimersByTimeAsync(10001);
			await connectPromise;

			expect(store.snapshotError).toContain('timed out due to inactivity');
			expect(store.activeAlerts.size).toBe(0);

			// Retry snapshot
			store.retrySnapshot();
			await vi.advanceTimersByTimeAsync(100);

			expect(store.snapshotError).toBeNull();
			expect(store.activeAlerts.has('retry-1')).toBe(true);
			store.disconnect();
		} finally {
			vi.useRealTimers();
		}
	});

	it('buffers and replays SSE events arriving during a prolonged snapshot download', async () => {
		vi.useFakeTimers();
		try {
			const alertSnap = makeAlert({ id: 'snap-event', last_seen_at: '2026-09-17T10:00:00Z' });
			const alertNewSse = makeAlert({
				id: 'snap-event',
				headline: 'Updated by SSE',
				last_seen_at: '2026-09-17T11:00:00Z'
			});

			const encoder = new TextEncoder();
			let controllerRef: ReadableStreamDefaultController<Uint8Array>;
			const stream = new ReadableStream<Uint8Array>({
				start(controller) {
					controllerRef = controller;
				}
			});

			vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(stream)));

			const store = new AlertStore();
			const connectPromise = store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');

			await vi.advanceTimersByTimeAsync(100);
			const sseStream = FakeEventSource.instances[0];

			// SSE event arrives while snapshot is downloading
			sseStream.emit('alert.update', alertNewSse);

			// Snapshot finishes at 15s (2 chunks at 7.5s intervals)
			await vi.advanceTimersByTimeAsync(7500);
			const fullJson = JSON.stringify([alertSnap]);
			controllerRef!.enqueue(encoder.encode(fullJson.slice(0, 10)));

			await vi.advanceTimersByTimeAsync(7500);
			controllerRef!.enqueue(encoder.encode(fullJson.slice(10)));
			controllerRef!.close();

			await vi.advanceTimersByTimeAsync(100);
			await connectPromise;

			// SSE event must have won the revision race over older snapshot record
			expect(store.activeAlerts.get('snap-event')?.headline).toBe('Updated by SSE');
			store.disconnect();
		} finally {
			vi.useRealTimers();
		}
	});

	it('aborts active body stream reading and cleans up cleanly on disconnect', async () => {
		vi.useFakeTimers();
		try {
			let cancelled = false;
			const stream = new ReadableStream<Uint8Array>({
				start() {},
				cancel() {
					cancelled = true;
				}
			});

			vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(stream)));

			const store = new AlertStore();
			const connectPromise = store.connect('/api/v1/alerts/active', '/api/v1/alerts/stream');

			await vi.advanceTimersByTimeAsync(100);
			expect(store.connected).toBe('connecting');

			store.disconnect();
			expect(store.connected).toBe('closed');
			expect(cancelled).toBe(true);

			await vi.advanceTimersByTimeAsync(100);
			await connectPromise;
			expect(store.snapshotError).toBeNull();
			expect(store.activeAlerts.size).toBe(0);
		} finally {
			vi.useRealTimers();
		}
	});
});
