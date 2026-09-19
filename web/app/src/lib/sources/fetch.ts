import type { DataSource } from '$lib/earthquakes/types';

const inFlightSources = new Map<string, Promise<DataSource[]>>();

/**
 * Fetches data sources from the specified URL, coalescing concurrent in-flight
 * requests for the same URL so that duplicate HTTP calls are eliminated.
 *
 * - Concurrent requests share the same in-flight Promise.
 * - Once resolved or rejected, the in-flight entry is cleared so subsequent
 *   retries or updates make a fresh request.
 * - Different URLs are isolated.
 */
export async function fetchSourcesShared(
	url: string,
	customFetch: typeof fetch = fetch
): Promise<DataSource[]> {
	const existing = inFlightSources.get(url);
	if (existing) {
		return existing;
	}

	const promise = (async () => {
		const response = await customFetch(url);
		if (!response.ok) {
			throw new Error(`sources request failed with status ${response.status}`);
		}
		const body = (await response.json()) as { sources?: DataSource[] };
		return body.sources ?? [];
	})();

	inFlightSources.set(url, promise);

	try {
		return await promise;
	} finally {
		inFlightSources.delete(url);
	}
}

/**
 * Resets the in-flight map. Intended for tests.
 */
export function clearSourcesInFlight(): void {
	inFlightSources.clear();
}
