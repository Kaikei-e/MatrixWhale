import type { MultiPolygon, Polygon } from 'geojson';

export const SEVERITIES = ['Extreme', 'Severe', 'Moderate', 'Minor', 'Unknown'] as const;

export type Severity = (typeof SEVERITIES)[number];

export interface Geocode {
	name: string;
	value: string;
}

export interface Alert {
	id: string;
	source: string;
	source_id: string;
	source_name: string;
	attribution: string;
	countries: string[];
	sender: string | null;
	sender_name: string | null;
	message_type: string | null;
	event: string;
	category: string[];
	severity: Severity;
	urgency: string;
	certainty: string;
	headline: string | null;
	language: string | null;
	web: string | null;
	area_desc: string;
	geocodes: Geocode[];
	geometry: MultiPolygon | Polygon | null;
	sent: string | null;
	effective: string | null;
	onset: string | null;
	expires: string | null;
	ends: string | null;
	active_until: string;
	first_seen_at: string;
	last_seen_at: string;
	ended_at: string | null;
	end_reason: string | null;
	superseded_by: string | null;
}

export interface AlertDetailAlert extends Alert {
	description: string | null;
	instruction: string | null;
	contact: string | null;
}

export interface CapArea {
	areaDesc: string;
	polygon?: string[];
	circle?: string[];
	geocode?: { valueName: string; value: string }[];
	altitude?: number | null;
	ceiling?: number | null;
}

export interface CapInfo {
	language?: string | null;
	category?: string[];
	event?: string;
	responseType?: string[];
	urgency?: string;
	severity?: string;
	certainty?: string;
	audience?: string | null;
	eventCode?: { valueName: string; value: string }[];
	effective?: string | null;
	onset?: string | null;
	expires?: string | null;
	senderName?: string | null;
	headline?: string | null;
	description?: string | null;
	instruction?: string | null;
	web?: string | null;
	contact?: string | null;
	parameter?: { valueName: string; value: string }[];
	resource?: {
		resourceDesc: string;
		mimeType: string;
		size?: number | null;
		uri?: string | null;
		digest?: string | null;
	}[];
	area?: CapArea[];
}

export interface AlertDetail {
	alert: AlertDetailAlert;
	infos: CapInfo[];
	cap_url: string | null;
	feed_url: string | null;
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
export type RawAlertEvent =
	{ type: 'new' | 'update' | 'ended'; record: Alert } | { type: 'resync'; record?: undefined };
