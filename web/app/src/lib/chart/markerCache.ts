import type { Feature, Point } from 'geojson';
import type { Alert, BlinkState, Severity } from '$lib/alerts/types';
import type { BlinkBucket } from '$lib/alerts/blinkBucket';
import { bucketFor } from '$lib/alerts/blinkBucket';
import { NWS_EVENT_COLORS, DEFAULT_NWS_COLOR } from '$lib/alerts/nwsEventStyle';
import { alertCentroid } from './alertPoints';

type LonLat = [number, number];

export interface MarkerState {
	[key: string]: unknown;
	severity: Severity;
	blinkBucket: BlinkBucket;
	nwsColor: string;
}

export interface MarkerStateEntry {
	id: string;
	state: MarkerState;
}

interface AlertMarkerShape {
	id: string;
	severity: Severity;
	source: string;
	lon: number;
	lat: number;
}

interface CachedPoint {
	lon: number;
	lat: number;
	severity: Severity;
	source: string;
	feature: Feature<Point>;
}

const SEVERITY_RANK: Record<Severity, number> = {
	Extreme: 5,
	Severe: 4,
	Moderate: 3,
	Minor: 2,
	Unknown: 1
};

export function createMarkerPointCache() {
	let cachedPoints = new Map<string, CachedPoint>();
	let cachedCollection: GeoJSON.FeatureCollection<Point> = {
		type: 'FeatureCollection',
		features: []
	};
	let cachedIds: string[] = [];

	return function getMarkerCollection(
		filteredAlerts: Alert[],
		centroids: Record<string, LonLat>
	): GeoJSON.FeatureCollection<Point> {
		const shapes: AlertMarkerShape[] = [];
		for (const alert of filteredAlerts) {
			const point = alertCentroid(alert, centroids);
			if (!point) continue;
			shapes.push({
				id: alert.id,
				severity: alert.severity,
				source: alert.source,
				lon: point[0],
				lat: point[1]
			});
		}

		let unchanged = shapes.length === cachedIds.length;
		if (unchanged) {
			for (let i = 0; i < shapes.length; i++) {
				const shape = shapes[i];
				if (cachedIds[i] !== shape.id) {
					unchanged = false;
					break;
				}
				const prev = cachedPoints.get(shape.id);
				if (
					!prev ||
					prev.lon !== shape.lon ||
					prev.lat !== shape.lat ||
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

		const nextPoints = new Map<string, CachedPoint>();
		const features: Feature<Point>[] = [];
		const nextIds: string[] = [];

		for (const shape of shapes) {
			nextIds.push(shape.id);
			const prev = cachedPoints.get(shape.id);
			if (
				prev &&
				prev.lon === shape.lon &&
				prev.lat === shape.lat &&
				prev.severity === shape.severity &&
				prev.source === shape.source
			) {
				nextPoints.set(shape.id, prev);
				features.push(prev.feature);
			} else {
				const feature: Feature<Point> = {
					type: 'Feature',
					properties: {
						id: shape.id,
						severity: shape.severity,
						severityRank: SEVERITY_RANK[shape.severity],
						source: shape.source
					},
					geometry: {
						type: 'Point',
						coordinates: [shape.lon, shape.lat]
					}
				};
				nextPoints.set(shape.id, {
					lon: shape.lon,
					lat: shape.lat,
					severity: shape.severity,
					source: shape.source,
					feature
				});
				features.push(feature);
			}
		}

		cachedPoints = nextPoints;
		cachedIds = nextIds;
		cachedCollection = { type: 'FeatureCollection', features };
		return cachedCollection;
	};
}

export function createMarkerStateCache() {
	let stateCache = new Map<string, MarkerState>();

	return function getMarkerStateEntries(
		filteredAlerts: Alert[],
		centroids: Record<string, LonLat>,
		blinkMap: { get(id: string): BlinkState | undefined },
		stopAll: boolean,
		reducedMotion: boolean
	): MarkerStateEntry[] {
		const nextCache = new Map<string, MarkerState>();
		const result: MarkerStateEntry[] = [];

		for (const alert of filteredAlerts) {
			const point = alertCentroid(alert, centroids);
			if (!point) continue;

			const bucket = bucketFor(blinkMap.get(alert.id), alert.severity, stopAll, reducedMotion);
			const color = NWS_EVENT_COLORS[alert.event] ?? DEFAULT_NWS_COLOR;

			const cached = stateCache.get(alert.id);
			let state: MarkerState;
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
