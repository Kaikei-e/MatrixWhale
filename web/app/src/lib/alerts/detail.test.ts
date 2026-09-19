import { describe, it, expect, vi, beforeEach } from 'vitest';
import { fetchAlertDetail, clearAlertDetailCache, getCachedAlertDetail } from './detail';
import type { AlertDetail } from './types';

describe('fetchAlertDetail', () => {
	beforeEach(() => {
		clearAlertDetailCache();
		vi.restoreAllMocks();
	});

	it('fetches from API and caches the result', async () => {
		const mockDetail: AlertDetail = {
			alert: { id: 'alert-1' } as unknown as AlertDetail['alert'],
			infos: [],
			cap_url: null,
			feed_url: null
		};

		const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
			ok: true,
			status: 200,
			json: async () => mockDetail
		} as Response);

		expect(getCachedAlertDetail('alert-1')).toBeUndefined();

		const result1 = await fetchAlertDetail('alert-1');
		expect(result1).toEqual(mockDetail);
		expect(fetchSpy).toHaveBeenCalledTimes(1);
		expect(getCachedAlertDetail('alert-1')).toEqual(mockDetail);

		// Subsequent call uses cache without fetching again
		const result2 = await fetchAlertDetail('alert-1');
		expect(result2).toEqual(mockDetail);
		expect(fetchSpy).toHaveBeenCalledTimes(1);
	});

	it('deduplicates concurrent in-flight fetches for the same id', async () => {
		const mockDetail: AlertDetail = {
			alert: { id: 'alert-2' } as unknown as AlertDetail['alert'],
			infos: [],
			cap_url: null,
			feed_url: null
		};

		let resolvePromise: (res: Response) => void;
		const delayedPromise = new Promise<Response>((resolve) => {
			resolvePromise = resolve;
		});

		const fetchSpy = vi.spyOn(globalThis, 'fetch').mockReturnValueOnce(delayedPromise);

		const promise1 = fetchAlertDetail('alert-2');
		const promise2 = fetchAlertDetail('alert-2');

		resolvePromise!({
			ok: true,
			status: 200,
			json: async () => mockDetail
		} as Response);

		const [res1, res2] = await Promise.all([promise1, promise2]);
		expect(res1).toEqual(mockDetail);
		expect(res2).toEqual(mockDetail);
		expect(fetchSpy).toHaveBeenCalledTimes(1);
	});

	it('refetches when cache is cleared for retry', async () => {
		const mockDetail: AlertDetail = {
			alert: { id: 'alert-3' } as unknown as AlertDetail['alert'],
			infos: [],
			cap_url: null,
			feed_url: null
		};

		const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue({
			ok: true,
			status: 200,
			json: async () => mockDetail
		} as Response);

		await fetchAlertDetail('alert-3');
		expect(fetchSpy).toHaveBeenCalledTimes(1);

		clearAlertDetailCache('alert-3');
		await fetchAlertDetail('alert-3');
		expect(fetchSpy).toHaveBeenCalledTimes(2);
	});

	it('shared in-flight fetch does not pass AbortSignal to fetch', async () => {
		const mockDetail: AlertDetail = {
			alert: { id: 'alert-shared' } as unknown as AlertDetail['alert'],
			infos: [],
			cap_url: null,
			feed_url: null
		};

		let capturedSignal: AbortSignal | undefined = undefined;
		vi.spyOn(globalThis, 'fetch').mockImplementation(async (_url, init) => {
			capturedSignal = init?.signal as AbortSignal | undefined;
			return {
				ok: true,
				status: 200,
				json: async () => mockDetail
			} as Response;
		});

		const controller = new AbortController();
		await (
			fetchAlertDetail as unknown as (id: string, signal?: AbortSignal) => Promise<AlertDetail>
		)('alert-shared', controller.signal);
		expect(capturedSignal).toBeUndefined();
	});

	it('keys cache on id + last_seen_at so alert updates fetch new detail', async () => {
		const detailV1: AlertDetail = {
			alert: { id: 'alert-v', description: 'version 1' } as unknown as AlertDetail['alert'],
			infos: [],
			cap_url: null,
			feed_url: null
		};
		const detailV2: AlertDetail = {
			alert: { id: 'alert-v', description: 'version 2' } as unknown as AlertDetail['alert'],
			infos: [],
			cap_url: null,
			feed_url: null
		};

		const fetchSpy = vi
			.spyOn(globalThis, 'fetch')
			.mockResolvedValueOnce({
				ok: true,
				status: 200,
				json: async () => detailV1
			} as Response)
			.mockResolvedValueOnce({
				ok: true,
				status: 200,
				json: async () => detailV2
			} as Response);

		const res1 = await fetchAlertDetail('alert-v', '2026-09-19T00:00:00Z');
		expect(res1.alert.description).toBe('version 1');
		expect(fetchSpy).toHaveBeenCalledTimes(1);

		// Same id and same last_seen_at should use cache
		const res1Cached = await fetchAlertDetail('alert-v', '2026-09-19T00:00:00Z');
		expect(res1Cached.alert.description).toBe('version 1');
		expect(fetchSpy).toHaveBeenCalledTimes(1);

		// Same id but newer last_seen_at should refetch
		const res2 = await fetchAlertDetail('alert-v', '2026-09-19T01:00:00Z');
		expect(res2.alert.description).toBe('version 2');
		expect(fetchSpy).toHaveBeenCalledTimes(2);

		expect(getCachedAlertDetail('alert-v', '2026-09-19T00:00:00Z')).toEqual(detailV1);
		expect(getCachedAlertDetail('alert-v', '2026-09-19T01:00:00Z')).toEqual(detailV2);
	});

	it('caps cache at 50 entries and evicts the oldest entry', async () => {
		for (let i = 1; i <= 51; i++) {
			const detail: AlertDetail = {
				alert: { id: `alert-${i}` } as unknown as AlertDetail['alert'],
				infos: [],
				cap_url: null,
				feed_url: null
			};
			vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
				ok: true,
				status: 200,
				json: async () => detail
			} as Response);
			await fetchAlertDetail(`alert-${i}`, '2026-09-19T00:00:00Z');
		}

		// First entry should have been evicted
		expect(getCachedAlertDetail('alert-1', '2026-09-19T00:00:00Z')).toBeUndefined();
		// 2nd and 51st entry should still be in cache
		expect(getCachedAlertDetail('alert-2', '2026-09-19T00:00:00Z')).toBeDefined();
		expect(getCachedAlertDetail('alert-51', '2026-09-19T00:00:00Z')).toBeDefined();
	});
});
