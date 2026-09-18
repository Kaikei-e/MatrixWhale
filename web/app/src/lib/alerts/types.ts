import type { Polygon, MultiPolygon } from 'geojson';

export const SEVERITIES = ['Extreme', 'Severe', 'Moderate', 'Minor', 'Unknown'] as const;

export type Severity = (typeof SEVERITIES)[number];

export interface Alert {
	id: string;
	event: string;
	severity: Severity;
	urgency: string;
	certainty: string;
	message_type: string | null;
	headline: string | null;
	area_desc: string;
	ugc: string[];
	same: string[];
	geometry: Polygon | MultiPolygon | null;
	sent: string | null;
	effective: string | null;
	expires: string | null;
	ends: string | null;
	first_seen_at: string;
	last_seen_at: string;
	ended_at: string | null;
}

export type BlinkMode = 'arrival' | 'persistent' | 'update' | 'fading' | 'static';

export interface BlinkState {
	mode: BlinkMode;
	until: number | null;
}

export interface PipelineStatus {
	last_fetch_at: string | null;
	last_http_status: number | null;
	last_received: number | null;
	last_decoded: number | null;
	last_dropped: number | null;
	last_write_at: string | null;
	last_new: number | null;
	last_updated: number | null;
	last_ended: number | null;
	sse_clients: number | null;
	active_by_severity: Record<Severity, number>;
}

export interface HistoryBucket {
	hour_start: string;
	counts: Record<Severity, number>;
}

/** Raw SSE payload, exposed before the store applies acknowledgement/blink state. */
export interface RawAlertEvent {
	type: 'new' | 'update' | 'ended';
	record: Alert;
}
