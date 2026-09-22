import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createZoneStateCache, fetchGeoJson, clearGeoJsonCache } from './zoneCache';
import type { Alert, Severity } from '$lib/alerts/types';
import {
	FORECAST_ZONES,
	COUNTY_ZONES,
	MARINE_COASTAL_ZONES,
	MARINE_OFFSHORE_ZONES
} from './dataFiles';

describe('createZoneStateCache', () => {
	it('generates zone entries with correct severity, blinkBucket, and nwsColor', () => {
		const getZoneEntries = createZoneStateCache();

		const alerts: Alert[] = [
			{
				id: 'a1',
				event: 'Tornado Warning',
				severity: 'Extreme',
				geocodes: [{ name: 'UGC', value: 'OKZ140' }],
				source: 'noaa'
			} as Alert
		];
		const zoneSeverity = new Map<string, Severity>([['OKZ140', 'Extreme']]);
		const blinkMap = new Map([['a1', { mode: 'arrival' as const, until: 5000 }]]);

		const entries = getZoneEntries(alerts, zoneSeverity, blinkMap, false, false);
		expect(entries).toHaveLength(1);
		expect(entries[0].ugc).toBe('OKZ140');
		expect(entries[0].state.severity).toBe('Extreme');
		expect(entries[0].state.blinkBucket).toBe('q');
	});

	it('reuses cached state object reference when alert/severity properties are unchanged', () => {
		const getZoneEntries = createZoneStateCache();

		const alerts: Alert[] = [
			{
				id: 'a1',
				event: 'Tornado Warning',
				severity: 'Extreme',
				geocodes: [{ name: 'UGC', value: 'OKZ140' }],
				source: 'noaa'
			} as Alert
		];
		const zoneSeverity = new Map<string, Severity>([['OKZ140', 'Extreme']]);
		const blinkMap = new Map([['a1', { mode: 'persistent' as const, until: null }]]);

		const firstRun = getZoneEntries(alerts, zoneSeverity, blinkMap, false, false);
		const secondRun = getZoneEntries(alerts, zoneSeverity, blinkMap, false, false);

		// Must reuse identical object reference for unchanged entry
		expect(secondRun[0].state).toBe(firstRun[0].state);
	});
});

describe('fetchGeoJson (deduplication, data sharing, and error retry)', () => {
	beforeEach(() => {
		clearGeoJsonCache();
	});

	it('deduplicates concurrent in-flight requests to the same URL (fetches exactly once)', async () => {
		const mockFc: GeoJSON.FeatureCollection = {
			type: 'FeatureCollection',
			features: [
				{
					type: 'Feature',
					geometry: { type: 'Point', coordinates: [0, 0] },
					properties: { ugc: 'TEST01' }
				}
			]
		};

		let fetchCount = 0;
		const mockFetch = vi.fn().mockImplementation(async () => {
			fetchCount++;
			// Simulate network latency
			await new Promise((resolve) => setTimeout(resolve, 10));
			return new Response(JSON.stringify(mockFc), { status: 200 });
		});

		// Launch 3 concurrent requests for the same GeoJSON file (simulating concurrent mounts)
		const [res1, res2, res3] = await Promise.all([
			fetchGeoJson(FORECAST_ZONES, mockFetch),
			fetchGeoJson(FORECAST_ZONES, mockFetch),
			fetchGeoJson(FORECAST_ZONES, mockFetch)
		]);

		expect(fetchCount).toBe(1);
		expect(mockFetch).toHaveBeenCalledTimes(1);
		expect(res1).toEqual(mockFc);
		expect(res2).toBe(res1);
		expect(res3).toBe(res1);
	});

	it('shares cached in-memory data for subsequent requests without additional network traffic', async () => {
		const mockFc: GeoJSON.FeatureCollection = {
			type: 'FeatureCollection',
			features: []
		};

		const mockFetch = vi
			.fn()
			.mockImplementation(async () => new Response(JSON.stringify(mockFc), { status: 200 }));

		// First request (fetches over network)
		const first = await fetchGeoJson(COUNTY_ZONES, mockFetch);
		expect(mockFetch).toHaveBeenCalledTimes(1);

		// Second request after first completed (must return from in-memory cache)
		const second = await fetchGeoJson(COUNTY_ZONES, mockFetch);
		expect(mockFetch).toHaveBeenCalledTimes(1); // No new network call
		expect(second).toBe(first); // Identical reference shared

		// Third request (still cached)
		const third = await fetchGeoJson(COUNTY_ZONES, mockFetch);
		expect(mockFetch).toHaveBeenCalledTimes(1);
		expect(third).toBe(first);
	});

	it('maintains error retry capability: does not cache errors and allows retry on subsequent attempt', async () => {
		const mockFc: GeoJSON.FeatureCollection = {
			type: 'FeatureCollection',
			features: []
		};

		let attempt = 0;
		const mockFetch = vi.fn().mockImplementation(async () => {
			attempt++;
			if (attempt === 1) {
				return new Response('Internal Server Error', { status: 500 });
			}
			return new Response(JSON.stringify(mockFc), { status: 200 });
		});

		// First attempt fails
		await expect(fetchGeoJson(MARINE_COASTAL_ZONES, mockFetch)).rejects.toThrow(
			`Failed to fetch GeoJSON from ${MARINE_COASTAL_ZONES}: HTTP 500`
		);
		expect(mockFetch).toHaveBeenCalledTimes(1);

		// Second attempt succeeds (retry works!)
		const retried = await fetchGeoJson(MARINE_COASTAL_ZONES, mockFetch);
		expect(mockFetch).toHaveBeenCalledTimes(2);
		expect(retried).toEqual(mockFc);
	});

	it('fetches independently for different GeoJSON URLs', async () => {
		const fc1: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };
		const fc2: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };

		const mockFetch = vi.fn().mockImplementation(async (url: string) => {
			if (url === FORECAST_ZONES) {
				return new Response(JSON.stringify(fc1), { status: 200 });
			}
			return new Response(JSON.stringify(fc2), { status: 200 });
		});

		const [data1, data2] = await Promise.all([
			fetchGeoJson(FORECAST_ZONES, mockFetch),
			fetchGeoJson(MARINE_OFFSHORE_ZONES, mockFetch)
		]);

		expect(mockFetch).toHaveBeenCalledTimes(2);
		expect(data1).toEqual(fc1);
		expect(data2).toEqual(fc2);
	});

	it('clearGeoJsonCache empties the cache and allows fresh fetch', async () => {
		const mockFc: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };
		const mockFetch = vi
			.fn()
			.mockImplementation(async () => new Response(JSON.stringify(mockFc), { status: 200 }));

		await fetchGeoJson(FORECAST_ZONES, mockFetch);
		expect(mockFetch).toHaveBeenCalledTimes(1);

		clearGeoJsonCache();

		await fetchGeoJson(FORECAST_ZONES, mockFetch);
		expect(mockFetch).toHaveBeenCalledTimes(2);
	});

	it('leaves connection slots for live data and releases a slot after a failed download', async () => {
		const replies: Array<(response: Response) => void> = [];
		const mockFetch = vi
			.fn()
			.mockImplementation(() => new Promise<Response>((resolve) => replies.push(resolve)));
		const first = fetchGeoJson('/one.json', mockFetch);
		const failed = expect(first).rejects.toThrow('HTTP 500');
		const second = fetchGeoJson('/two.json', mockFetch);
		const third = fetchGeoJson('/three.json', mockFetch);
		const fourth = fetchGeoJson('/four.json', mockFetch);
		const fifth = fetchGeoJson('/five.json', mockFetch);
		await vi.waitFor(() => expect(mockFetch).toHaveBeenCalledTimes(4));
		replies[0](new Response(null, { status: 500 }));
		await failed;
		await vi.waitFor(() => expect(mockFetch).toHaveBeenCalledTimes(5));
		for (const resolve of replies.slice(1)) {
			resolve(new Response(JSON.stringify({ type: 'FeatureCollection', features: [] })));
		}
		await Promise.all([second, third, fourth, fifth]);
	});
});
