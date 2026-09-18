/** Member match provenance within a canonical event. */
export type MemberMatchedBy = 'origin' | 'id' | 'misfit';

export interface EarthquakeMember {
	source: string;
	source_id: string;
	magnitude: number | null;
	magnitude_type: string | null;
	occurred_at_ms: number;
	updated_at_ms: number;
	latitude: number;
	longitude: number;
	depth_km: number | null;
	place: string | null;
	status: string | null;
	url: string | null;
	matched_by: MemberMatchedBy;
	misfit: number | null;
}

/** Canonical event returned by `/api/v1/earthquakes/recent` and the SSE stream. */
export interface Earthquake {
	id: number;
	kind: string;
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
	net: string | null;
	code: string | null;
	url: string | null;
	detail: string | null;
	longitude: number;
	latitude: number;
	depth_km: number | null;
	preferred_source: string;
	sources: string[];
	members: EarthquakeMember[];
	first_seen_at: string;
	last_seen_at: string;
	/** Present on SSE events; initial/backfill records must never flash. */
	is_backfill?: boolean;
}

/** Attribution/license entry returned by `/api/v1/sources`. */
export interface DataSource {
	id: string;
	name: string;
	homepage: string;
	license: string;
	attribution_text: string;
	redistributable: boolean;
	priority: number;
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

/** Raw SSE payload, exposed before the store applies its own window/magnitude filter. */
export type RawEarthquakeEvent =
	{ type: 'new'; record: Earthquake } | { type: 'update'; record: Earthquake } | { type: 'resync' };
