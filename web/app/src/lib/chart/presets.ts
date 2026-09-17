import type { Alert } from '$lib/alerts/types';
import { alertPoints } from './alertPoints';

export type Bbox = [west: number, south: number, east: number, north: number];

export const REGION_PRESETS: Record<string, Bbox> = {
	CONUS: [-125, 24, -66, 50],
	AK: [-170, 51, -129, 72],
	'HI-Pac': [-161, 18, -154, 23],
	Carib: [-85, 9, -60, 27]
};

export function bboxOfAlerts(
	alerts: Alert[],
	centroids: Record<string, [number, number]>
): Bbox | null {
	let minLon = Infinity;
	let minLat = Infinity;
	let maxLon = -Infinity;
	let maxLat = -Infinity;
	let found = false;

	for (const alert of alerts) {
		for (const [lon, lat] of alertPoints(alert, centroids)) {
			found = true;
			if (lon < minLon) minLon = lon;
			if (lon > maxLon) maxLon = lon;
			if (lat < minLat) minLat = lat;
			if (lat > maxLat) maxLat = lat;
		}
	}

	return found ? [minLon, minLat, maxLon, maxLat] : null;
}

/**
 * Initial extent for the chart. Alaska's marine zones are under some advisory
 * almost every day, so fitting every active alert would zoom out to the whole
 * Pacific and merge the markers into one blob; never start wider than CONUS.
 */
export function initialViewBbox(
	alerts: Alert[],
	centroids: Record<string, [number, number]>
): Bbox {
	const bbox = bboxOfAlerts(alerts, centroids);
	if (!bbox) return REGION_PRESETS.CONUS;

	const [west, south, east, north] = bbox;
	const [conusWest, conusSouth, conusEast, conusNorth] = REGION_PRESETS.CONUS;
	const widerThanConus = east - west > conusEast - conusWest;
	const tallerThanConus = north - south > conusNorth - conusSouth;
	return widerThanConus || tallerThanConus ? REGION_PRESETS.CONUS : bbox;
}
