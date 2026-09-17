/** Normalized event returned by `/api/v1/earthquakes/recent`. */
export interface Earthquake {
	source: string;
	source_id: string;
	contributing_ids: string[];
	net: string | null;
	code: string | null;
	magnitude: number | null;
	magnitude_type: string | null;
	occurred_at: string;
	occurred_at_ms: number;
	updated_at: string;
	updated_at_ms: number;
	place: string | null;
	title: string | null;
	status: string | null;
	event_type: string | null;
	tsunami: 0 | 1 | null;
	significance: number | null;
	alert: string | null;
	mmi: number | null;
	cdi: number | null;
	felt: number | null;
	nst: number | null;
	dmin: number | null;
	rms: number | null;
	gap: number | null;
	url: string | null;
	detail: string | null;
	longitude: number;
	latitude: number;
	depth_km: number | null;
	first_seen_at: string;
	last_seen_at: string;
	/** Present on SSE events; initial/backfill records must never flash. */
	is_backfill?: boolean;
}

export type EarthquakeEventType = 'earthquake' | 'all';

export interface EarthquakeFilter {
	hours: number;
	minMagnitude: number | 'all';
	eventType: EarthquakeEventType;
}

export type EarthquakeBlinkMode = 'arrival' | 'persistent';

export interface EarthquakeBlinkState {
	mode: EarthquakeBlinkMode;
	until: number | null;
}

export function earthquakeKey(earthquake: Pick<Earthquake, 'source' | 'source_id'>): string {
	return `${earthquake.source}:${earthquake.source_id}`;
}
