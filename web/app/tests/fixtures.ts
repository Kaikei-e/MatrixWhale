import type { Page } from '@playwright/test';

export const ALERTS = [
	{
		id: 'noaa:https://api.weather.gov/alerts/urn:oid:2.49.0.1.840.0.1',
		source: 'noaa',
		source_id: 'https://api.weather.gov/alerts/urn:oid:2.49.0.1.840.0.1',
		source_name: 'National Weather Service',
		attribution: 'NOAA / National Weather Service',
		countries: ['USA'],
		sender: 'w-nws.webmaster@noaa.gov',
		sender_name: 'NWS Norman OK',
		message_type: 'Alert',
		event: 'Tornado Warning',
		category: ['Met'],
		severity: 'Extreme',
		urgency: 'Immediate',
		certainty: 'Observed',
		headline: 'Tornado Warning issued',
		language: 'en-US',
		web: 'https://alerts.weather.gov',
		area_desc: 'Oklahoma County, OK',
		geocodes: [{ name: 'UGC', value: 'OKZ140' }],
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
		ended_at: null,
		end_reason: null,
		superseded_by: null
	},
	{
		id: 'noaa:https://api.weather.gov/alerts/urn:oid:2.49.0.1.840.0.2',
		source: 'noaa',
		source_id: 'https://api.weather.gov/alerts/urn:oid:2.49.0.1.840.0.2',
		source_name: 'National Weather Service',
		attribution: 'NOAA / National Weather Service',
		countries: ['USA'],
		sender: 'w-nws.webmaster@noaa.gov',
		sender_name: 'NWS Norman OK',
		message_type: 'Alert',
		event: 'Flash Flood Warning',
		category: ['Met'],
		severity: 'Severe',
		urgency: 'Expected',
		certainty: 'Likely',
		headline: null,
		language: 'en-US',
		web: null,
		area_desc: 'Oklahoma County, OK',
		geocodes: [{ name: 'UGC', value: 'OKC143' }],
		geometry: null,
		sent: '2026-09-17T09:30:00Z',
		effective: '2026-09-17T09:30:00Z',
		expires: '2026-09-17T12:00:00Z',
		ends: null,
		first_seen_at: '2026-09-17T09:30:05Z',
		last_seen_at: '2026-09-17T09:30:05Z',
		ended_at: null,
		end_reason: null,
		superseded_by: null
	},
	{
		id: 'cap-2.49.0.0.250.0:contact@meteo.fr,2.49.0.0.250.0.MF.20260917',
		source: 'cap-2.49.0.0.250.0',
		source_id: 'contact@meteo.fr,2.49.0.0.250.0.MF.20260917',
		source_name: 'Météo-France',
		attribution: 'Météo-France (France), via the WMO Register of Alerting Authorities',
		countries: ['FRA'],
		sender: 'contact@meteo.fr',
		sender_name: 'Météo-France Toulouse',
		message_type: 'Alert',
		event: 'Frost Advisory',
		category: ['Met'],
		severity: 'Minor',
		urgency: 'Expected',
		certainty: 'Likely',
		headline: null,
		language: 'fr-FR',
		web: 'https://meteofrance.com',
		area_desc: 'Paris',
		geocodes: [],
		geometry: { type: 'MultiPolygon', coordinates: [] },
		sent: '2026-09-17T08:00:00Z',
		effective: '2026-09-17T08:00:00Z',
		expires: '2026-09-17T14:00:00Z',
		ends: null,
		first_seen_at: '2026-09-17T08:00:05Z',
		last_seen_at: '2026-09-17T08:00:05Z',
		ended_at: null,
		end_reason: null,
		superseded_by: null
	},
	{
		id: 'cap-2.49.0.0.276.0:opendata@dwd.de,2.49.0.0.276.0.DWD.PVW.20260917',
		source: 'cap-2.49.0.0.276.0',
		source_id: 'opendata@dwd.de,2.49.0.0.276.0.DWD.PVW.20260917',
		source_name: 'Deutscher Wetterdienst',
		attribution: 'Deutscher Wetterdienst (Germany), via the WMO Register of Alerting Authorities',
		countries: ['DEU'],
		sender: 'opendata@dwd.de',
		sender_name: 'DWD Zentrale Offenbach',
		message_type: 'Alert',
		event: 'Wind Warning',
		category: ['Met'],
		severity: 'Minor',
		urgency: 'Expected',
		certainty: 'Likely',
		headline: 'Wind gust advisory',
		language: 'de-DE',
		web: 'https://www.dwd.de',
		area_desc: 'Kreis Borken',
		geocodes: [],
		geometry: {
			type: 'MultiPolygon',
			coordinates: [
				[
					[
						[6.8, 51.8],
						[7.0, 51.8],
						[7.0, 52.0],
						[6.8, 52.0],
						[6.8, 51.8]
					]
				]
			]
		},
		sent: '2026-09-17T07:30:00Z',
		effective: '2026-09-17T07:30:00Z',
		expires: '2026-09-17T13:00:00Z',
		ends: null,
		first_seen_at: '2026-09-17T07:30:05Z',
		last_seen_at: '2026-09-17T07:30:05Z',
		ended_at: null,
		end_reason: null,
		superseded_by: null
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
	},
	{
		id: 'wis2-jma:obs-gust-1',
		source: 'wis2-jma',
		source_id: 'obs-gust-1',
		source_type_code: 'OE',
		hazard_type: 'observed_extreme',
		subtype: 'gust',
		confirmed: true,
		hazard_codes: ['wis2:OE'],
		glide: null,
		alert_level: 'orange',
		alert_score: 1.8,
		cap_severity: 'severe',
		severity_value: 34.2,
		severity_unit: 'm/s',
		severity_label: 'Gust 34.2 m/s',
		estimate_type: 'primary',
		title: 'Gust 34.2 m/s at 0-20000-0-47662',
		description: 'Extreme gust observed at station 47662',
		countries: ['JPN'],
		report_url: null,
		onset_at: new Date().toISOString(),
		onset_at_ms: Date.now(),
		expires_at: new Date().toISOString(),
		expires_at_ms: Date.now(),
		modified_at: new Date().toISOString(),
		modified_at_ms: Date.now(),
		is_current: true,
		episode_id: '1',
		episode_count: 1,
		longitude: 139.75,
		latitude: 35.68,
		bbox: [139.75, 35.68, 139.75, 35.68],
		primary_geometry: {
			type: 'Point',
			coordinates: [139.75, 35.68]
		},
		external_ids: [],
		first_seen_at: new Date().toISOString(),
		last_seen_at: new Date().toISOString()
	},
	{
		id: 'wis2-dwd:obs-rain-2',
		source: 'wis2-dwd',
		source_id: 'obs-rain-2',
		source_type_code: 'OE',
		hazard_type: 'observed_extreme',
		subtype: 'rain_1h',
		confirmed: false,
		hazard_codes: ['wis2:OE'],
		glide: null,
		alert_level: 'orange',
		alert_score: 1.6,
		cap_severity: 'severe',
		severity_value: 52.0,
		severity_unit: 'mm',
		severity_label: 'Rain 52.0 mm/h',
		estimate_type: 'primary',
		title: 'Rain 52.0 mm/h at 0-20000-0-10382',
		description: 'Extreme hourly precipitation observed at station 10382',
		countries: ['DEU'],
		report_url: null,
		onset_at: new Date().toISOString(),
		onset_at_ms: Date.now(),
		expires_at: new Date().toISOString(),
		expires_at_ms: Date.now(),
		modified_at: new Date().toISOString(),
		modified_at_ms: Date.now(),
		is_current: true,
		episode_id: '1',
		episode_count: 1,
		longitude: 13.4,
		latitude: 52.5,
		bbox: [13.4, 52.5, 13.4, 52.5],
		primary_geometry: {
			type: 'Point',
			coordinates: [13.4, 52.5]
		},
		external_ids: [],
		first_seen_at: new Date().toISOString(),
		last_seen_at: new Date().toISOString()
	}
];

export const CAP_FEEDS = [
	{
		url: 'https://warnungen.dwd.de/api/cap/v1/feed',
		health: 'ok',
		authority: {
			oid: '2.49.0.0.276.0',
			source: 'cap-2.49.0.0.276.0',
			name: 'Deutscher Wetterdienst',
			country_name: 'Germany',
			country_iso3: 'DEU'
		},
		authority_oids: ['2.49.0.0.276.0'],
		language: 'de-DE',
		subscribed: true,
		exclusion_reason: null,
		format: 'atom',
		last_polled_at: '2026-09-17T10:00:00Z',
		last_success_at: '2026-09-17T10:00:00Z',
		last_http_status: 200,
		last_error: null,
		consecutive_failures: 0,
		item_count: 12,
		newest_item_at: '2026-09-17T09:45:00Z',
		active_alerts: 5,
		failed_items: 0
	},
	{
		url: 'https://vigilance.meteofrance.fr/cap/feed.atom',
		health: 'failing',
		authority: {
			oid: '2.49.0.0.250.0',
			source: 'cap-2.49.0.0.250.0',
			name: 'Météo-France',
			country_name: 'France',
			country_iso3: 'FRA'
		},
		authority_oids: ['2.49.0.0.250.0'],
		language: 'fr-FR',
		subscribed: true,
		exclusion_reason: null,
		format: 'atom',
		last_polled_at: '2026-09-17T10:05:00Z',
		last_success_at: '2026-09-16T12:00:00Z',
		last_http_status: 502,
		last_error: 'HTTP 502 Bad Gateway',
		consecutive_failures: 4,
		item_count: 0,
		newest_item_at: null,
		active_alerts: 0,
		failed_items: 0
	},
	{
		url: 'https://metoffice.gov.uk/cap/rss',
		health: 'degraded',
		authority: {
			oid: '2.49.0.0.826.0',
			source: 'cap-2.49.0.0.826.0',
			name: 'Met Office',
			country_name: 'United Kingdom',
			country_iso3: 'GBR'
		},
		authority_oids: ['2.49.0.0.826.0'],
		language: 'en-GB',
		subscribed: true,
		exclusion_reason: null,
		format: 'rss',
		last_polled_at: '2026-09-17T10:02:00Z',
		last_success_at: '2026-09-17T10:02:00Z',
		last_http_status: 200,
		last_error: 'Connection timeout after 30s',
		consecutive_failures: 1,
		item_count: 3,
		newest_item_at: '2026-09-17T09:30:00Z',
		active_alerts: 2,
		failed_items: 1
	},
	{
		url: 'https://inmet.gov.br/cap/feed',
		health: 'excluded',
		authority: {
			oid: '2.49.0.0.076.0',
			source: 'cap-2.49.0.0.076.0',
			name: 'INMET',
			country_name: 'Brazil',
			country_iso3: 'BRA'
		},
		authority_oids: ['2.49.0.0.076.0'],
		language: 'pt-BR',
		subscribed: false,
		exclusion_reason: 'Excluded by operator config: TLS certificate expired',
		format: 'atom',
		last_polled_at: null,
		last_success_at: null,
		last_http_status: null,
		last_error: null,
		consecutive_failures: 0,
		item_count: null,
		newest_item_at: null,
		active_alerts: 0,
		failed_items: 0
	},
	{
		url: 'https://protezionecivile.gov.it/cap.atom',
		health: 'pending',
		authority: {
			oid: '2.49.0.0.380.0',
			source: 'cap-2.49.0.0.380.0',
			name: 'Dipartimento Protezione Civile',
			country_name: 'Italy',
			country_iso3: 'ITA'
		},
		authority_oids: ['2.49.0.0.380.0'],
		language: 'it-IT',
		subscribed: true,
		exclusion_reason: null,
		format: 'atom',
		last_polled_at: null,
		last_success_at: null,
		last_http_status: null,
		last_error: null,
		consecutive_failures: 0,
		item_count: null,
		newest_item_at: null,
		active_alerts: 0,
		failed_items: 0
	}
];

export const ALERT_DETAILS: Record<
	string,
	{ alert: unknown; infos: unknown[]; cap_url: string | null; feed_url: string | null }
> = {
	'noaa:https://api.weather.gov/alerts/urn:oid:2.49.0.1.840.0.1': {
		alert: {
			...ALERTS[0],
			description: 'A tornado was reported near Oklahoma City moving east at 35 mph.',
			instruction: 'Take cover immediately in a basement or storm shelter.',
			contact: 'NWS Norman OK',
			parameter: []
		},
		infos: [],
		cap_url: 'https://alerts.weather.gov/cap/urn:oid:2.49.0.1.840.0.1.cap',
		feed_url: 'https://alerts.weather.gov/cap/feed.atom'
	},
	'cap-2.49.0.0.276.0:opendata@dwd.de,2.49.0.0.276.0.DWD.PVW.20260917': {
		alert: {
			...ALERTS[3],
			description: 'Es treten Windböen mit Geschwindigkeiten bis 60 km/h auf.',
			instruction: 'Achten Sie auf herabfallende Äste.',
			contact: 'DWD Zentrale Offenbach',
			parameter: []
		},
		infos: [],
		cap_url: 'https://warnungen.dwd.de/cap/urn:oid:2.49.0.0.276.0.dwd.cap.20260917',
		feed_url: 'https://warnungen.dwd.de/api/cap/v1/feed'
	}
};

export const WIS2_HEALTH = {
	broker: {
		url: 'mqtts://globalbroker.meteo.fr:8883',
		connected: true,
		last_report_at: '2026-09-25T15:00:00Z',
		error: null
	},
	channels: [
		{
			centre_id: 'eu-eumetnet-warnings',
			kind: 'warnings',
			received_24h: 450,
			duplicates_24h: 50,
			download_failed_24h: 1,
			decode_failed_24h: 0,
			integrity_failed_24h: 0,
			last_received_at: '2026-09-25T14:55:00Z',
			status: 'ok'
		},
		{
			centre_id: 'ecmwf',
			kind: 'trajectory',
			received_24h: 120,
			duplicates_24h: 10,
			download_failed_24h: 0,
			decode_failed_24h: 2,
			integrity_failed_24h: 1,
			last_received_at: '2026-09-25T13:00:00Z',
			status: 'stale'
		},
		{
			centre_id: 'in-imd',
			kind: 'synop',
			received_24h: 80,
			duplicates_24h: 5,
			download_failed_24h: 4,
			decode_failed_24h: 1,
			integrity_failed_24h: 0,
			last_received_at: '2026-09-25T11:00:00Z',
			status: 'failing'
		}
	]
};

export const HAZARD_DETAILS = {
	'gdacs:TC-1000001': {
		hazard: HAZARDS[0],
		episodes: [],
		forecast_tracks: [
			{
				source: 'wis2-ecmwf',
				centre_id: 'ecmwf',
				storm_id: 'TC-1000001',
				storm_name: 'Test Storm',
				analysis_time: '2026-09-25T12:00:00Z',
				points: [
					{
						lead_hours: 0,
						time: '2026-09-25T12:00:00Z',
						lat: 14.5,
						lon: 120.5,
						mslp_pa: 99200,
						max_wind_ms: 28.5,
						max_wind_lat: 14.5,
						max_wind_lon: 120.5,
						wind_radii: [
							{ threshold_ms: 18, radii_m: [180000, 160000, 140000, 150000] },
							{ threshold_ms: 26, radii_m: [80000, 70000, 60000, 75000] },
							{ threshold_ms: 33, radii_m: [0, 0, 0, 0] }
						]
					},
					{
						lead_hours: 24,
						time: '2026-09-26T12:00:00Z',
						lat: 16.0,
						lon: 119.2,
						mslp_pa: 97500,
						max_wind_ms: 38.0,
						max_wind_lat: 16.0,
						max_wind_lon: 119.2,
						wind_radii: [
							{ threshold_ms: 18, radii_m: [240000, 220000, 200000, 210000] },
							{ threshold_ms: 26, radii_m: [140000, 130000, 120000, 130000] },
							{ threshold_ms: 33, radii_m: [60000, 50000, 40000, 55000] }
						]
					}
				]
			}
		]
	}
};

export async function mockBackend(page: Page): Promise<void> {
	await page.route('**/api/v1/alerts/active*', (route) => route.fulfill({ json: ALERTS }));
	await page.route('**/api/v1/alerts/detail**', (route) => {
		const url = new URL(route.request().url());
		const id = url.searchParams.get('id');
		if (id && ALERT_DETAILS[id]) {
			return route.fulfill({ json: ALERT_DETAILS[id] });
		}
		const alert = (id ? ALERTS.find((a) => a.id === id) : null) ?? ALERTS[0];
		return route.fulfill({
			json: {
				alert: {
					...alert,
					description: `Detailed description for ${alert.headline || alert.event}.`,
					instruction: 'Follow local authority safety guidance.',
					contact: alert.sender,
					parameter: []
				},
				infos: [],
				cap_url: `https://example.org/cap/${encodeURIComponent(id ?? 'unknown')}`,
				feed_url: 'https://example.org/cap/feed'
			}
		});
	});
	await page.route('**/api/v1/stream*', (route) =>
		route.fulfill({
			contentType: 'text/event-stream',
			body: 'event: alerts.heartbeat\nid: 1\ndata: {}\n\nevent: earthquakes.heartbeat\ndata: {}\n\nevent: hazards.heartbeat\ndata: {}\n\n'
		})
	);
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
	await page.route('**/api/v1/cap/feeds', (route) =>
		route.fulfill({
			json: {
				generated_at: '2026-09-17T10:10:00Z',
				registry_fetched_at: '2026-09-17T10:00:00Z',
				counts: {
					ok: 1,
					empty: 0,
					stale: 0,
					degraded: 1,
					failing: 1,
					pending: 1,
					excluded: 1
				},
				feeds: CAP_FEEDS
			}
		})
	);
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
	await page.route('**/api/v1/wis2/health*', (route) => route.fulfill({ json: WIS2_HEALTH }));
	await page.route('**/api/v1/hazards/*/**', (route) => {
		const url = new URL(route.request().url());
		if (url.pathname.includes('/recent') || url.pathname.includes('/stream')) {
			return route.fallback();
		}
		const path = url.pathname.replace(/^\/api\/v1\/hazards\//, '');
		const firstSlash = path.indexOf('/');
		if (firstSlash === -1) return route.fallback();
		const source = decodeURIComponent(path.slice(0, firstSlash));
		const sourceId = path
			.slice(firstSlash + 1)
			.split('/')
			.map(decodeURIComponent)
			.join('/');
		const id = `${source}:${sourceId}`;
		if (HAZARD_DETAILS[id as keyof typeof HAZARD_DETAILS]) {
			return route.fulfill({ json: HAZARD_DETAILS[id as keyof typeof HAZARD_DETAILS] });
		}
		const found = HAZARDS.find((h) => h.id === id) ?? HAZARDS[0];
		return route.fulfill({
			json: {
				hazard: found,
				episodes: [],
				forecast_tracks: []
			}
		});
	});
}

/**
 * Lets a test push SSE events onto a live EventSource stream. `route.fulfill`
 * can only answer a single request, so this exploits the browser's native SSE
 * auto-reconnect (sped up via `retry:`): each reconnect drains the queue.
 */
export class SseInjector {
	#queue: string[] = [];
	#started = false;
	#wake: (() => void) | undefined;

	constructor(
		private readonly page: Page,
		private readonly urlPattern: string = '**/api/v1/stream*'
	) {}

	async install(): Promise<void> {
		// When tests specify a legacy pattern, also route the shared stream default
		const patterns = [this.urlPattern];
		if (this.urlPattern !== '**/api/v1/stream*') {
			patterns.push('**/api/v1/stream*');
		}

		for (const pattern of patterns) {
			await this.page.route(pattern, async (route) => {
				// Hold the reconnect until the next injected event. Completing an
				// empty stream every 50ms would continuously refetch snapshots.
				if (this.#started && this.#queue.length === 0) {
					await new Promise<void>((resolve) => {
						this.#wake = resolve;
					});
				}
				this.#started = true;
				const events = this.#queue.join('');
				this.#queue = [];
				route.fulfill({
					contentType: 'text/event-stream',
					body: `retry: 50\nevent: alerts.heartbeat\ndata: {}\n\nevent: earthquakes.heartbeat\ndata: {}\n\nevent: hazards.heartbeat\ndata: {}\n\nevent: heartbeat\ndata: {}\n\n${events}`
				});
			});
		}
	}

	push(eventType: string, data: unknown): void {
		this.#queue.push(`event: ${eventType}\ndata: ${JSON.stringify(data)}\n\n`);
		this.#wake?.();
		this.#wake = undefined;
	}
}
