import type { Alert, BlinkState, Severity } from '$lib/alerts/types';
import type { BlinkBucket } from '$lib/alerts/blinkBucket';
import { bucketFor, bucketRank } from '$lib/alerts/blinkBucket';
import { NWS_EVENT_COLORS, DEFAULT_NWS_COLOR } from '$lib/alerts/nwsEventStyle';
import { extractUgc } from '$lib/alerts/geocodes';
import { decodeGeometry } from './geometryTransport';

export interface ZoneState {
	[key: string]: unknown;
	severity: Severity;
	blinkBucket: BlinkBucket;
	nwsColor: string;
}

export interface ZoneEntry {
	ugc: string;
	state: ZoneState;
}

export function createZoneStateCache() {
	let stateCache = new Map<string, ZoneState>();

	return function getZoneEntries(
		filteredAlerts: Alert[],
		zoneSeverity: Map<string, Severity>,
		blinkMap: { get(id: string): BlinkState | undefined },
		stopAll: boolean,
		reducedMotion: boolean
	): ZoneEntry[] {
		const extras = new Map<string, { blinkBucket: BlinkBucket; nwsColor: string }>();
		for (const alert of filteredAlerts) {
			const bucket = bucketFor(blinkMap.get(alert.id), alert.severity, stopAll, reducedMotion);
			const color = NWS_EVENT_COLORS[alert.event] ?? DEFAULT_NWS_COLOR;
			for (const ugc of extractUgc(alert)) {
				const existing = extras.get(ugc);
				if (!existing) {
					extras.set(ugc, { blinkBucket: bucket, nwsColor: color });
				} else if (bucketRank(bucket) < bucketRank(existing.blinkBucket)) {
					extras.set(ugc, { blinkBucket: bucket, nwsColor: existing.nwsColor });
				}
			}
		}

		const nextCache = new Map<string, ZoneState>();
		const entries: ZoneEntry[] = [];

		for (const [ugc, severity] of zoneSeverity.entries()) {
			const blinkBucket = extras.get(ugc)?.blinkBucket ?? 'none';
			const nwsColor = extras.get(ugc)?.nwsColor ?? DEFAULT_NWS_COLOR;
			const cached = stateCache.get(ugc);
			let state: ZoneState;
			if (
				cached &&
				cached.severity === severity &&
				cached.blinkBucket === blinkBucket &&
				cached.nwsColor === nwsColor
			) {
				state = cached;
			} else {
				state = {
					severity,
					blinkBucket,
					nwsColor
				};
			}

			nextCache.set(ugc, state);
			entries.push({ ugc, state });
		}

		stateCache = nextCache;
		return entries;
	};
}

// Versioned local URLs are immutable. Keep fulfilled promises as well as
// in-flight work so remounts and concurrent consumers reuse one download.
const geoJsonCache = new Map<string, Promise<GeoJSON.FeatureCollection>>();
let activeDownloads = 0;
const waitingDownloads: Array<() => void> = [];

export function decodeFeatureCollection(fc: GeoJSON.FeatureCollection): GeoJSON.FeatureCollection {
	if (!fc || typeof fc !== 'object' || !Array.isArray(fc.features)) {
		return fc;
	}
	for (let i = 0; i < fc.features.length; i++) {
		const feature = fc.features[i];
		if (feature && feature.geometry) {
			feature.geometry = decodeGeometry(feature.geometry) as GeoJSON.Geometry;
		}
	}
	return fc;
}

// The stores share one SSE connection. Keep map downloads bounded so snapshots
// can still progress on a slow connection.
async function downloadGeoJson(
	url: string,
	fetchFn: typeof fetch
): Promise<GeoJSON.FeatureCollection> {
	if (activeDownloads >= 4) {
		await new Promise<void>((resolve) => waitingDownloads.push(resolve));
	} else {
		activeDownloads++;
	}
	try {
		const response = await fetchFn(url, { priority: 'low' });
		if (!response.ok) {
			throw new Error(`Failed to fetch GeoJSON from ${url}: HTTP ${response.status}`);
		}
		const data = (await response.json()) as GeoJSON.FeatureCollection;
		return decodeFeatureCollection(data);
	} finally {
		const next = waitingDownloads.shift();
		if (next) next();
		else activeDownloads--;
	}
}

export function fetchGeoJson(
	url: string,
	fetchFn: typeof fetch = fetch
): Promise<GeoJSON.FeatureCollection> {
	const cached = geoJsonCache.get(url);
	if (cached) return cached;

	const pending = Promise.resolve()
		.then(() => downloadGeoJson(url, fetchFn))
		.catch((error) => {
			if (geoJsonCache.get(url) === pending) geoJsonCache.delete(url);
			throw error;
		});
	geoJsonCache.set(url, pending);
	return pending;
}

export function clearGeoJsonCache(): void {
	geoJsonCache.clear();
}
