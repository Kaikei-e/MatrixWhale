import type { Page } from '@playwright/test';

export const ALERTS = [
	{
		id: 'urn:oid:test.1',
		event: 'Tornado Warning',
		severity: 'Extreme',
		urgency: 'Immediate',
		certainty: 'Observed',
		message_type: 'Alert',
		headline: 'Tornado Warning issued',
		area_desc: 'Oklahoma County, OK',
		ugc: ['OKZ140'],
		same: [],
		geometry: {
			type: 'Polygon',
			coordinates: [
				[
					[-97.6, 35.4],
					[-97.4, 35.4],
					[-97.4, 35.6],
					[-97.6, 35.6],
					[-97.6, 35.4]
				]
			]
		},
		sent: '2026-09-17T10:00:00Z',
		effective: '2026-09-17T10:00:00Z',
		expires: '2026-09-17T11:00:00Z',
		ends: null,
		first_seen_at: '2026-09-17T10:00:05Z',
		last_seen_at: '2026-09-17T10:00:05Z',
		ended_at: null
	},
	{
		id: 'urn:oid:test.2',
		event: 'Flash Flood Warning',
		severity: 'Severe',
		urgency: 'Expected',
		certainty: 'Likely',
		message_type: 'Alert',
		headline: null,
		area_desc: 'Oklahoma County, OK',
		ugc: ['OKC143'],
		same: [],
		geometry: null,
		sent: '2026-09-17T09:30:00Z',
		effective: '2026-09-17T09:30:00Z',
		expires: '2026-09-17T12:00:00Z',
		ends: null,
		first_seen_at: '2026-09-17T09:30:05Z',
		last_seen_at: '2026-09-17T09:30:05Z',
		ended_at: null
	},
	{
		id: 'urn:oid:test.3',
		event: 'Frost Advisory',
		severity: 'Minor',
		urgency: 'Expected',
		certainty: 'Likely',
		message_type: 'Alert',
		headline: null,
		area_desc: 'Canadian County, OK',
		ugc: [],
		same: [],
		geometry: null,
		sent: '2026-09-17T08:00:00Z',
		effective: '2026-09-17T08:00:00Z',
		expires: '2026-09-17T14:00:00Z',
		ends: null,
		first_seen_at: '2026-09-17T08:00:05Z',
		last_seen_at: '2026-09-17T08:00:05Z',
		ended_at: null
	}
];

export const PIPELINE_STATUS = {
	last_fetch_at: null,
	last_http_status: null,
	last_received: null,
	last_decoded: null,
	last_dropped: null,
	last_write_at: null,
	last_new: null,
	last_updated: null,
	last_ended: null,
	sse_clients: null,
	active_by_severity: { Extreme: 0, Severe: 0, Moderate: 0, Minor: 0, Unknown: 0 }
};

export const DATA_SOURCES = [
	{
		id: 'usgs',
		name: 'U.S. Geological Survey',
		homepage: 'https://earthquake.usgs.gov/',
		license: 'public-domain',
		attribution_text: 'Credit: U.S. Geological Survey',
		redistributable: true,
		priority: 100
	},
	{
		id: 'emsc',
		name: 'EMSC',
		homepage: 'https://www.seismicportal.eu/',
		license: 'CC-BY-4.0',
		attribution_text: 'Credit: EMSC/CSEM, https://www.emsc-csem.org',
		redistributable: true,
		priority: 90
	},
	{
		id: 'gdacs',
		name: 'GDACS',
		homepage: 'https://www.gdacs.org/',
		license: 'Public domain (GDACS RSS); attribution requested',
		attribution_text: 'Global Disaster Awareness and Coordination System, GDACS',
		redistributable: false,
		priority: 80
	}
];

export const EARTHQUAKES = [
	{
		id: 4821,
		kind: 'earthquake',
		magnitude: 5.3,
		magnitude_type: 'mww',
		occurred_at: new Date().toISOString(),
		occurred_at_ms: Date.now(),
		updated_at: new Date().toISOString(),
		updated_at_ms: Date.now(),
		place: 'VALPARAISO, CHILE',
		title: 'M 5.3 - Valparaiso, Chile',
		status: 'reviewed',
		event_type: 'earthquake',
		tsunami: 1,
		significance: 432,
		alert: null,
		mmi: null,
		cdi: null,
		felt: null,
		nst: null,
		dmin: null,
		rms: null,
		gap: null,
		net: 'us',
		code: 'test-5',
		url: 'https://earthquake.usgs.gov/earthquakes/eventpage/us-test-5',
		detail: null,
		longitude: 142.2,
		latitude: 36.1,
		depth_km: 18.4,
		preferred_source: 'usgs',
		sources: ['usgs', 'emsc'],
		members: [
			{
				source: 'usgs',
				source_id: 'us-test-5',
				magnitude: 5.3,
				magnitude_type: 'mww',
				occurred_at_ms: Date.now(),
				updated_at_ms: Date.now(),
				latitude: 36.1,
				longitude: 142.2,
				depth_km: 18.4,
				place: 'VALPARAISO, CHILE',
				status: 'reviewed',
				url: 'https://earthquake.usgs.gov/earthquakes/eventpage/us-test-5',
				matched_by: 'origin',
				misfit: null
			},
			{
				source: 'emsc',
				source_id: 'emsc-test-5',
				magnitude: 5.2,
				magnitude_type: 'mw',
				occurred_at_ms: Date.now(),
				updated_at_ms: Date.now(),
				latitude: 36.05,
				longitude: 142.15,
				depth_km: 15.0,
				place: 'VALPARAISO, CHILE',
				status: 'automatic',
				url: 'https://www.seismicportal.eu/eventdetails.html?unid=emsc-test-5',
				matched_by: 'misfit',
				misfit: 0.31
			}
		],
		first_seen_at: new Date().toISOString(),
		last_seen_at: new Date().toISOString()
	},
	{
		id: 4822,
		kind: 'earthquake',
		magnitude: 3.2,
		magnitude_type: 'ml',
		occurred_at: new Date(Date.now() - 60 * 60 * 1000).toISOString(),
		occurred_at_ms: Date.now() - 60 * 60 * 1000,
		updated_at: new Date().toISOString(),
		updated_at_ms: Date.now(),
		place: 'Test Ridge',
		title: 'M 3.2 - Test Ridge',
		status: 'automatic',
		event_type: 'earthquake',
		tsunami: 0,
		significance: 158,
		alert: null,
		mmi: null,
		cdi: null,
		felt: null,
		nst: null,
		dmin: null,
		rms: null,
		gap: null,
		net: 'us',
		code: 'test-3',
		url: 'https://earthquake.usgs.gov/earthquakes/eventpage/us-test-3',
		detail: null,
		longitude: 139.7,
		latitude: 35.6,
		depth_km: 8.2,
		preferred_source: 'usgs',
		sources: ['usgs'],
		members: [
			{
				source: 'usgs',
				source_id: 'us-test-3',
				magnitude: 3.2,
				magnitude_type: 'ml',
				occurred_at_ms: Date.now() - 60 * 60 * 1000,
				updated_at_ms: Date.now(),
				latitude: 35.6,
				longitude: 139.7,
				depth_km: 8.2,
				place: 'Test Ridge',
				status: 'automatic',
				url: 'https://earthquake.usgs.gov/earthquakes/eventpage/us-test-3',
				matched_by: 'origin',
				misfit: null
			}
		],
		first_seen_at: new Date().toISOString(),
		last_seen_at: new Date().toISOString()
	}
];

export const HAZARDS = [
	{
		id: 'gdacs:TC-1000001',
		source: 'gdacs',
		source_id: 'TC-1000001',
		source_type_code: 'TC',
		hazard_type: 'tropical_cyclone',
		hazard_codes: ['glide:TC'],
		glide: null,
		alert_level: 'orange',
		alert_score: 1.5,
		cap_severity: 'severe',
		severity_value: 120,
		severity_unit: 'km/h',
		severity_label: 'Wind speed 120 km/h',
		estimate_type: 'primary',
		title: 'Tropical Cyclone Test',
		description: 'Tropical cyclone test description',
		countries: ['PHL'],
		report_url: 'https://www.gdacs.org/report.aspx?eventid=1000001&episodeid=1&eventtype=TC',
		onset_at: new Date().toISOString(),
		onset_at_ms: Date.now(),
		expires_at: new Date().toISOString(),
		expires_at_ms: Date.now(),
		modified_at: new Date().toISOString(),
		modified_at_ms: Date.now(),
		is_current: true,
		episode_id: '1',
		episode_count: 1,
		longitude: 120.5,
		latitude: 14.5,
		bbox: [120.5, 14.5, 120.5, 14.5],
		primary_geometry: null,
		external_ids: [],
		first_seen_at: new Date().toISOString(),
		last_seen_at: new Date().toISOString()
	}
];

export async function mockBackend(page: Page): Promise<void> {
	await page.route('**/api/v1/alerts/active', (route) => route.fulfill({ json: ALERTS }));
	await page.route('**/api/v1/alerts/stream', (route) =>
		route.fulfill({
			contentType: 'text/event-stream',
			body: 'event: heartbeat\nid: 1\ndata: {}\n\n'
		})
	);
	await page.route('**/api/v1/pipeline/status', (route) =>
		route.fulfill({ json: PIPELINE_STATUS })
	);
	await page.route('**/api/v1/alerts/history**', (route) => route.fulfill({ json: [] }));
	await page.route('**/api/v1/earthquakes/recent**', (route) =>
		route.fulfill({ json: { earthquakes: EARTHQUAKES } })
	);
	await page.route('**/api/v1/earthquakes/stream', (route) =>
		route.fulfill({ contentType: 'text/event-stream', body: 'event: heartbeat\ndata: {}\n\n' })
	);
	await page.route('**/api/v1/hazards/recent**', (route) =>
		route.fulfill({ json: { hazards: HAZARDS } })
	);
	await page.route('**/api/v1/hazards/stream', (route) =>
		route.fulfill({ contentType: 'text/event-stream', body: 'event: heartbeat\ndata: {}\n\n' })
	);
	await page.route('**/api/v1/sources', (route) =>
		route.fulfill({ json: { sources: DATA_SOURCES } })
	);
}

/**
 * Lets a test push SSE events onto a live EventSource stream. `route.fulfill`
 * can only answer a single request, so this exploits the browser's native SSE
 * auto-reconnect (sped up via `retry:`): each reconnect drains the queue.
 */
export class SseInjector {
	#queue: string[] = [];

	constructor(
		private readonly page: Page,
		private readonly urlPattern: string
	) {}

	async install(): Promise<void> {
		await this.page.route(this.urlPattern, (route) => {
			const events = this.#queue.join('');
			this.#queue = [];
			route.fulfill({
				contentType: 'text/event-stream',
				body: `retry: 50\nevent: heartbeat\ndata: {}\n\n${events}`
			});
		});
	}

	push(eventType: string, data: unknown): void {
		this.#queue.push(`event: ${eventType}\ndata: ${JSON.stringify(data)}\n\n`);
	}
}
