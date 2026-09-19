import type { Alert } from '$lib/alerts/types';
import { extractUgc } from '$lib/alerts/geocodes';

type LonLat = [number, number];

function ringBboxCentroid(ring: number[][]): LonLat {
	let minLon = Infinity;
	let minLat = Infinity;
	let maxLon = -Infinity;
	let maxLat = -Infinity;
	for (const [lon, lat] of ring) {
		if (lon < minLon) minLon = lon;
		if (lon > maxLon) maxLon = lon;
		if (lat < minLat) minLat = lat;
		if (lat > maxLat) maxLat = lat;
	}
	return [(minLon + maxLon) / 2, (minLat + maxLat) / 2];
}

export function alertPoints(alert: Alert, centroids: Record<string, LonLat>): LonLat[] {
	if (alert.geometry) {
		if (alert.geometry.type === 'Polygon') {
			return [ringBboxCentroid(alert.geometry.coordinates[0])];
		}
		return alert.geometry.coordinates.map((polygon) => ringBboxCentroid(polygon[0]));
	}

	return extractUgc(alert)
		.map((ugc) => centroids[ugc])
		.filter((point): point is LonLat => point !== undefined);
}

/**
 * One representative point per alert: the mean of `alertPoints`. Longitudes
 * are unwrapped around the first point so a zone set straddling the
 * antimeridian (Aleutian marine zones) averages near 180, not near 0.
 */
export function alertCentroid(alert: Alert, centroids: Record<string, LonLat>): LonLat | null {
	const points = alertPoints(alert, centroids);
	if (points.length === 0) return null;

	const [lon0] = points[0];
	let sumLon = 0;
	let sumLat = 0;
	for (const [lon, lat] of points) {
		let unwrapped = lon;
		if (unwrapped - lon0 > 180) unwrapped -= 360;
		else if (lon0 - unwrapped > 180) unwrapped += 360;
		sumLon += unwrapped;
		sumLat += lat;
	}

	let lon = sumLon / points.length;
	if (lon > 180) lon -= 360;
	else if (lon < -180) lon += 360;
	return [lon, sumLat / points.length];
}
