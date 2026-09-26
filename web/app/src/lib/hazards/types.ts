import type { Polygon, MultiPolygon, FeatureCollection } from 'geojson';

export type HazardType =
	| 'earthquake'
	| 'tropical_cyclone'
	| 'flood'
	| 'volcano'
	| 'wildfire'
	| 'drought'
	| 'tsunami'
	| 'observed_extreme';

/** GDACS `eventtype` code or WIS2 extreme type code, as used by the recent/stream query params. */
export type HazardSourceTypeCode =
	'EQ' | 'TC' | 'FL' | 'VO' | 'WF' | 'DR' | 'TS' | 'OE' | 'observed_extreme';

export type AlertLevel = 'green' | 'orange' | 'red';

export type CapSeverity = 'minor' | 'severe' | 'extreme';

export const OBSERVED_EXTREME_SUBTYPES = [
	'wind',
	'gust',
	'rain_1h',
	'rain_24h',
	'low_pressure'
] as const;

export type ObservedExtremeSubtype = (typeof OBSERVED_EXTREME_SUBTYPES)[number];

export const OBSERVED_EXTREME_SUBTYPE_LABELS: Record<ObservedExtremeSubtype, string> = {
	wind: 'Wind',
	gust: 'Gust',
	rain_1h: 'Rain 1h',
	rain_24h: 'Rain 24h',
	low_pressure: 'Low Pressure'
};

export interface ForecastWindRadii {
	threshold_ms: number;
	radii_m: (number | null)[];
}

export interface ForecastPoint {
	lead_hours: number;
	time: string;
	lat: number;
	lon: number;
	mslp_pa: number | null;
	max_wind_ms: number | null;
	max_wind_lat: number | null;
	max_wind_lon: number | null;
	wind_radii: ForecastWindRadii[];
}

export interface ForecastTrack {
	source: string;
	centre_id: string;
	storm_id: string;
	storm_name: string | null;
	analysis_time: string;
	points: ForecastPoint[];
}

/** Hazard returned by `/api/v1/hazards/recent`, the SSE stream, and the detail endpoint. */
export interface Hazard {
	id: string;
	source: string;
	source_id: string;
	source_type_code: HazardSourceTypeCode;
	hazard_type: HazardType;
	hazard_codes: string[];
	glide: string | null;
	alert_level: AlertLevel;
	alert_score: number;
	cap_severity: CapSeverity;
	severity_value: number | null;
	severity_unit: string | null;
	severity_label: string | null;
	estimate_type: string;
	title: string;
	description: string;
	countries: string[];
	report_url: string | null;
	onset_at: string;
	onset_at_ms: number;
	expires_at: string;
	expires_at_ms: number;
	modified_at: string;
	modified_at_ms: number;
	is_current: boolean;
	episode_id: string;
	episode_count: number;
	longitude: number;
	latitude: number;
	bbox: [number, number, number, number];
	primary_geometry: Polygon | MultiPolygon | null;
	/** Full FeatureCollection of the latest episode; present only on the detail endpoint. */
	geometries?: FeatureCollection | null;
	external_ids: string[];
	first_seen_at: string;
	last_seen_at: string;
	subtype?: ObservedExtremeSubtype | string | null;
	confirmed?: boolean | null;
}

export interface HazardEpisode {
	episode_id: string;
	alert_level: AlertLevel;
	alert_score: number;
	severity_value: number | null;
	severity_label: string | null;
	from_at: string;
	to_at: string;
	modified_at: string;
	has_geometry: boolean;
}

export interface HazardDetail {
	hazard: Hazard;
	episodes: HazardEpisode[];
	forecast_tracks?: ForecastTrack[];
}

export interface HazardFilter {
	types: Set<HazardType>;
	levels: Set<AlertLevel>;
	subtypes?: Set<ObservedExtremeSubtype>;
	hideUnconfirmed?: boolean;
}

/** Raw SSE payload, exposed before the store applies its own type/level filter. */
export type RawHazardEvent =
	{ type: 'new'; record: Hazard } | { type: 'update'; record: Hazard } | { type: 'resync' };

export const HAZARD_TYPES: HazardType[] = [
	'earthquake',
	'tropical_cyclone',
	'flood',
	'volcano',
	'wildfire',
	'drought',
	'tsunami',
	'observed_extreme'
];

export const ALERT_LEVELS: AlertLevel[] = ['green', 'orange', 'red'];

export const HAZARD_TYPE_LABELS: Record<HazardType, string> = {
	earthquake: 'Earthquake',
	tropical_cyclone: 'Tropical Cyclone',
	flood: 'Flood',
	volcano: 'Volcano',
	wildfire: 'Wildfire',
	drought: 'Drought',
	tsunami: 'Tsunami',
	observed_extreme: 'Observed Extreme'
};

export const HAZARD_TYPE_CODES: Record<HazardType, HazardSourceTypeCode> = {
	earthquake: 'EQ',
	tropical_cyclone: 'TC',
	flood: 'FL',
	volcano: 'VO',
	wildfire: 'WF',
	drought: 'DR',
	tsunami: 'TS',
	observed_extreme: 'observed_extreme'
};

export const ALERT_LEVEL_COLORS: Record<AlertLevel, string> = {
	green: '#2e7d32',
	orange: '#ef6c00',
	red: '#c62828'
};
