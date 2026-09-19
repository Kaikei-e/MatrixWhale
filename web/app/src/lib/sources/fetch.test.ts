import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fetchSourcesShared, clearSourcesInFlight } from './fetch';
import type { DataSource } from '$lib/earthquakes/types';

const mockSources: DataSource[] = [
	{
		id: 'usgs',
		name: 'U.S. Geological Survey',
		homepage: 'https://earthquake.usgs.gov/',
		license: 'public-domain',
		attribution_text: 'Credit: U.S. Geological Survey',
		redistributable: true,
		priority: 100
	},
	{
		id: 'gdacs',
		name: 'GDACS',
		homepage: 'https://www.gdacs.org/',
		license: 'Public domain (GDACS RSS); attribution requested',
		attribution_text: 'Global Disaster Awareness and Coordination System, GDACS',
		redistributable: false,
		priority: 80
	}
];

describe('fetchSourcesShared', () => {
	beforeEach(() => {
		clearSourcesInFlight();
	});

	afterEach(() => {
		clearSourcesInFlight();
		vi.restoreAllMocks();
	});

	it('coalesces concurrent requests to the same URL into a single fetch call', async () => {
		let resolveFetch: (res: Response) => void;
		const fetchPromise = new Promise<Response>((resolve) => {
			resolveFetch = resolve;
		});

		const customFetch = vi.fn().mockReturnValue(fetchPromise);

		// Two concurrent calls to the same endpoint
		const p1 = fetchSourcesShared('/api/v1/sources', customFetch as unknown as typeof fetch);
		const p2 = fetchSourcesShared('/api/v1/sources', customFetch as unknown as typeof fetch);

		expect(customFetch).toHaveBeenCalledTimes(1);

		resolveFetch!(new Response(JSON.stringify({ sources: mockSources })));

		const [res1, res2] = await Promise.all([p1, p2]);

		expect(res1).toEqual(mockSources);
		expect(res2).toEqual(mockSources);
		expect(customFetch).toHaveBeenCalledTimes(1);
	});

	it('triggers a fresh fetch call for subsequent requests after resolution', async () => {
		const customFetch = vi
			.fn()
			.mockImplementation(async () => new Response(JSON.stringify({ sources: mockSources })));

		const res1 = await fetchSourcesShared(
			'/api/v1/sources',
			customFetch as unknown as typeof fetch
		);
		expect(res1).toEqual(mockSources);
		expect(customFetch).toHaveBeenCalledTimes(1);

		// Subsequent call after first completed
		const res2 = await fetchSourcesShared(
			'/api/v1/sources',
			customFetch as unknown as typeof fetch
		);
		expect(res2).toEqual(mockSources);
		expect(customFetch).toHaveBeenCalledTimes(2);
	});

	it('isolates requests to different URLs', async () => {
		const customFetch = vi.fn().mockImplementation(async (url: string) => {
			if (url === '/api/v1/sources?type=geo') {
				return new Response(JSON.stringify({ sources: [mockSources[0]] }));
			}
			return new Response(JSON.stringify({ sources: [mockSources[1]] }));
		});

		const p1 = fetchSourcesShared(
			'/api/v1/sources?type=geo',
			customFetch as unknown as typeof fetch
		);
		const p2 = fetchSourcesShared(
			'/api/v1/sources?type=met',
			customFetch as unknown as typeof fetch
		);

		const [res1, res2] = await Promise.all([p1, p2]);

		expect(customFetch).toHaveBeenCalledTimes(2);
		expect(res1).toHaveLength(1);
		expect(res1[0].id).toBe('usgs');
		expect(res2).toHaveLength(1);
		expect(res2[0].id).toBe('gdacs');
	});

	it('clears in-flight entry on failure and allows retry', async () => {
		const customFetch = vi
			.fn()
			.mockResolvedValueOnce(new Response(null, { status: 500 }))
			.mockResolvedValueOnce(new Response(JSON.stringify({ sources: mockSources })));

		// First call fails
		await expect(
			fetchSourcesShared('/api/v1/sources', customFetch as unknown as typeof fetch)
		).rejects.toThrow('sources request failed with status 500');

		// Second call succeeds as a fresh request
		const res = await fetchSourcesShared('/api/v1/sources', customFetch as unknown as typeof fetch);
		expect(res).toEqual(mockSources);
		expect(customFetch).toHaveBeenCalledTimes(2);
	});

	it('returns empty array if response body does not contain sources', async () => {
		const customFetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({})));

		const res = await fetchSourcesShared('/api/v1/sources', customFetch as unknown as typeof fetch);
		expect(res).toEqual([]);
	});
});
