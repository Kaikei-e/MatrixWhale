import type { AlertDetail } from './types';

const MAX_CACHE_ENTRIES = 50;
const detailCache = new Map<string, AlertDetail>();
const inFlight = new Map<string, Promise<AlertDetail>>();

function cacheKey(id: string, lastSeenAt?: string | null): string {
	return `${id}:${lastSeenAt ?? ''}`;
}

export function getCachedAlertDetail(
	id: string,
	lastSeenAt?: string | null
): AlertDetail | undefined {
	return detailCache.get(cacheKey(id, lastSeenAt));
}

export async function fetchAlertDetail(
	id: string,
	lastSeenAt?: string | null
): Promise<AlertDetail> {
	const key = cacheKey(id, lastSeenAt);
	const cached = detailCache.get(key);
	if (cached) return cached;

	let promise = inFlight.get(key);
	if (!promise) {
		promise = fetch(`/api/v1/alerts/detail?id=${encodeURIComponent(id)}`)
			.then(async (res) => {
				if (!res.ok) throw new Error(`Detail fetch failed with status ${res.status}`);
				const data = (await res.json()) as AlertDetail;
				if (detailCache.has(key)) {
					detailCache.delete(key);
				}
				detailCache.set(key, data);
				if (detailCache.size > MAX_CACHE_ENTRIES) {
					const oldestKey = detailCache.keys().next().value;
					if (oldestKey !== undefined) {
						detailCache.delete(oldestKey);
					}
				}
				return data;
			})
			.finally(() => {
				inFlight.delete(key);
			});
		inFlight.set(key, promise);
	}
	return promise;
}

export function clearAlertDetailCache(id?: string, lastSeenAt?: string | null): void {
	if (id) {
		if (lastSeenAt !== undefined) {
			const key = cacheKey(id, lastSeenAt);
			detailCache.delete(key);
			inFlight.delete(key);
		} else {
			for (const key of Array.from(detailCache.keys())) {
				if (key === id || key.startsWith(`${id}:`)) {
					detailCache.delete(key);
				}
			}
			for (const key of Array.from(inFlight.keys())) {
				if (key === id || key.startsWith(`${id}:`)) {
					inFlight.delete(key);
				}
			}
		}
	} else {
		detailCache.clear();
		inFlight.clear();
	}
}
