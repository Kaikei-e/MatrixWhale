import type { ForecastWindRadii, Hazard } from './types';

export const OBSERVED_EXTREME_COLORS: Record<string, string> = {
	wind: '#00bcd4',
	gust: '#ff9800',
	rain_1h: '#2196f3',
	rain_24h: '#3f51b5',
	low_pressure: '#9c27b0'
};

export const DEFAULT_EXTREME_COLOR = '#607d8b';

export function observedExtremeColor(subtype?: string | null): string {
	if (!subtype) return DEFAULT_EXTREME_COLOR;
	return OBSERVED_EXTREME_COLORS[subtype] ?? DEFAULT_EXTREME_COLOR;
}

export function formatObservedExtremeSubtype(subtype?: string | null): string {
	if (!subtype) return 'Observed Extreme';
	switch (subtype) {
		case 'wind':
			return 'Wind';
		case 'gust':
			return 'Wind Gust';
		case 'rain_1h':
			return 'Rain 1h';
		case 'rain_24h':
			return 'Rain 24h';
		case 'low_pressure':
			return 'Low Pressure';
		default:
			return subtype;
	}
}

/**
 * Encodes each path segment for hazard detail requests so source IDs
 * containing slashes (e.g. "06L/2026") are routed correctly.
 */
export function encodeHazardDetailPath(source: string, sourceId: string): string {
	const encodedSource = encodeURIComponent(source);
	const encodedSegments = sourceId
		.split('/')
		.map((seg) => encodeURIComponent(seg))
		.join('/');
	return `/api/v1/hazards/${encodedSource}/${encodedSegments}`;
}

/** Formats a track lead hour into a "+24h"-style label. */
export function formatTrackLeadLabel(leadHours: number): string {
	return `+${leadHours}h`;
}

/** Whether a forecast lead time is a positive 24-hour step (+24h, +48h, etc.). */
export function is24HourStep(leadHours: number): boolean {
	return leadHours > 0 && leadHours % 24 === 0;
}

/**
 * Filter predicate for observed extremes: non-extreme hazards always match;
 * observed extremes must match active subtypes and unconfirmed visibility.
 */
export function matchesObservedExtremeFilter(
	hazard: Hazard,
	selectedSubtypes: ReadonlySet<string>,
	hideUnconfirmed: boolean
): boolean {
	if (hazard.hazard_type !== 'observed_extreme') return true;
	if (hideUnconfirmed && hazard.confirmed === false) return false;
	if (hazard.subtype && !selectedSubtypes.has(hazard.subtype)) return false;
	return true;
}

/**
 * Formats latitude and longitude to one decimal with N/S/E/W suffixes and no degree clutter.
 * E.g. (17.1, -108.8) -> "17.1N 108.8W"
 *      (14.5, 120.5) -> "14.5N 120.5E"
 */
export function formatLatLon(lat: number | null, lon: number | null): string {
	if (lat === null || lon === null || isNaN(lat) || isNaN(lon)) return '—';
	const latDir = lat >= 0 ? 'N' : 'S';
	const lonDir = lon >= 0 ? 'E' : 'W';
	return `${Math.abs(lat).toFixed(1)}${latDir} ${Math.abs(lon).toFixed(1)}${lonDir}`;
}

/** Formats MSLP from Pa to integer hPa. */
export function formatMslp(mslpPa: number | null): string {
	if (mslpPa === null) return '—';
	return `${Math.round(mslpPa / 100)}`;
}

/** Formats MSLP from Pa to hPa string with unit for tooltips. */
export function formatMslpWithUnit(mslpPa: number | null): string {
	if (mslpPa === null) return '—';
	return `${Math.round(mslpPa / 100)} hPa`;
}

/** Formats max wind speed as integer m/s. */
export function formatMaxWind(maxWindMs: number | null): string {
	if (maxWindMs === null) return '—';
	return `${Math.round(maxWindMs)} m/s`;
}

/**
 * Formats wind radii for thresholds 18, 26, 33 m/s into km (numbers only, km).
 * E.g. "18: 240 · 26: 150 · 33: 75 km" or "18: 100 km" or "—".
 */
export function formatWindRadiiSummary(radii: ForecastWindRadii[]): string {
	if (!radii || radii.length === 0) return '—';
	const parts: string[] = [];
	for (const threshold of [18, 26, 33]) {
		const item = radii.find((r) => Math.round(r.threshold_ms) === threshold);
		if (item && item.radii_m && item.radii_m.some((r) => r !== null && r > 0)) {
			const maxKm = Math.round(Math.max(...item.radii_m.map((r) => r ?? 0)) / 1000);
			parts.push(`${threshold}: ${maxKm}`);
		}
	}
	return parts.length > 0 ? `${parts.join(' · ')} km` : '—';
}

/** Formats alert source badge for display (e.g. "WIS2 · <centre_id>"). */
export function formatAlertSourceBadge(source: string, sourceName?: string | null): string {
	if (source.startsWith('wis2-')) {
		return `WIS2 · ${source.slice(5)}`;
	}
	return sourceName || source;
}
