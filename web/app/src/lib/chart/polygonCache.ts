import type { Alert, BlinkState, Severity } from '$lib/alerts/types';
import type { BlinkBucket } from '$lib/alerts/blinkBucket';
import { bucketFor } from '$lib/alerts/blinkBucket';
import { NWS_EVENT_COLORS, DEFAULT_NWS_COLOR } from '$lib/alerts/nwsEventStyle';

export function geometryKey(geom: NonNullable<Alert['geometry']>): string {
	return `${geom.type}:${JSON.stringify(geom.coordinates)}`;
}

export interface PolygonState {
	[key: string]: unknown;
	severity: Severity;
	blinkBucket: BlinkBucket;
	nwsColor: string;
}

export interface StateEntry {
	id: string;
	state: PolygonState;
}

interface AlertShape {
	id: string;
	severity: Severity;
	source: string;
	geometry: NonNullable<Alert['geometry']>;
	geomKey: string;
}

interface CachedFeature {
	geometry: NonNullable<Alert['geometry']>;
	geomKey: string;
	severity: Severity;
	source: string;
	feature: GeoJSON.Feature;
}

export function createPolygonFeatureCache() {
	let cachedFeatures = new Map<string, CachedFeature>();
	let cachedCollection: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };
	let cachedIds: string[] = [];

	return function getFeatureCollection(filteredAlerts: Alert[]): GeoJSON.FeatureCollection {
		const shapes: AlertShape[] = [];
		for (const alert of filteredAlerts) {
			if (alert.geometry && alert.geometry.coordinates && alert.geometry.coordinates.length > 0) {
				const prev = cachedFeatures.get(alert.id);
				const geomKey =
					prev && prev.geometry === alert.geometry ? prev.geomKey : geometryKey(alert.geometry);
				shapes.push({
					id: alert.id,
					severity: alert.severity,
					source: alert.source,
					geometry: alert.geometry,
					geomKey
				});
			}
		}

		let unchanged = shapes.length === cachedIds.length;
		if (unchanged) {
			for (let i = 0; i < shapes.length; i++) {
				const shape = shapes[i];
				if (cachedIds[i] !== shape.id) {
					unchanged = false;
					break;
				}
				const prev = cachedFeatures.get(shape.id);
				if (
					!prev ||
					prev.geomKey !== shape.geomKey ||
					prev.severity !== shape.severity ||
					prev.source !== shape.source
				) {
					unchanged = false;
					break;
				}
			}
		}

		if (unchanged) {
			return cachedCollection;
		}

		const nextFeatures = new Map<string, CachedFeature>();
		const features: GeoJSON.Feature[] = [];
		const nextIds: string[] = [];

		for (const shape of shapes) {
			nextIds.push(shape.id);
			const prev = cachedFeatures.get(shape.id);
			if (
				prev &&
				prev.geomKey === shape.geomKey &&
				prev.severity === shape.severity &&
				prev.source === shape.source
			) {
				nextFeatures.set(shape.id, prev);
				features.push(prev.feature);
			} else {
				const feature: GeoJSON.Feature = {
					type: 'Feature',
					properties: { id: shape.id, severity: shape.severity, source: shape.source },
					geometry: shape.geometry
				};
				nextFeatures.set(shape.id, {
					geometry: shape.geometry,
					geomKey: shape.geomKey,
					severity: shape.severity,
					source: shape.source,
					feature
				});
				features.push(feature);
			}
		}

		cachedFeatures = nextFeatures;
		cachedIds = nextIds;
		cachedCollection = { type: 'FeatureCollection', features };
		return cachedCollection;
	};
}

export function createPolygonStateCache() {
	let stateCache = new Map<string, PolygonState>();

	return function getStateEntries(
		filteredAlerts: Alert[],
		blinkMap: { get(id: string): BlinkState | undefined },
		stopAll: boolean,
		reducedMotion: boolean
	): StateEntry[] {
		const nextCache = new Map<string, PolygonState>();
		const result: StateEntry[] = [];

		for (const alert of filteredAlerts) {
			if (
				!alert.geometry ||
				!alert.geometry.coordinates ||
				alert.geometry.coordinates.length === 0
			) {
				continue;
			}
			const bucket = bucketFor(blinkMap.get(alert.id), alert.severity, stopAll, reducedMotion);
			const color = NWS_EVENT_COLORS[alert.event] ?? DEFAULT_NWS_COLOR;

			const cached = stateCache.get(alert.id);
			let state: PolygonState;
			if (
				cached &&
				cached.severity === alert.severity &&
				cached.blinkBucket === bucket &&
				cached.nwsColor === color
			) {
				state = cached;
			} else {
				state = {
					severity: alert.severity,
					blinkBucket: bucket,
					nwsColor: color
				};
			}

			nextCache.set(alert.id, state);
			result.push({ id: alert.id, state });
		}

		stateCache = nextCache;
		return result;
	};
}
