import { expect, test, type Page } from '@playwright/test';

const ALERTS = [
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

const PIPELINE_STATUS = {
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

const DATA_SOURCES = [
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
	}
];

const EARTHQUAKES = [
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

async function mockBackend(page: Page): Promise<void> {
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
	await page.route('**/api/v1/sources', (route) =>
		route.fulfill({ json: { sources: DATA_SOURCES } })
	);
}

test('renders the legend, feed order, alert detail, and the stop-blink toggle', async ({
	page
}) => {
	await mockBackend(page);
	await page.goto('/globe');

	const legend = page.getByTestId('legend');
	await expect(legend).toBeVisible();
	await expect(legend).toContainText('Q');
	await expect(legend).toContainText('Fl 2s');
	await expect(legend).toContainText('Fl 4s');
	await expect(legend).toContainText('F');

	// The mobile bottom-sheet renders its own (hidden) copy of the feed and
	// detail panel, so scope queries to the visible desktop side panel.
	const sidePanel = page.getByTestId('side-panel');
	// The legacy feed list lives under the "Feed" tab now that the pane is tabbed.
	await sidePanel.getByRole('tab', { name: 'Feed' }).click();
	const feedItems = sidePanel.getByTestId('feed-item');
	await expect(feedItems).toHaveCount(3);
	await expect(feedItems.nth(0)).toContainText('Tornado Warning');
	await expect(feedItems.nth(1)).toContainText('Flash Flood Warning');
	await expect(feedItems.nth(2)).toContainText('Frost Advisory');

	await feedItems.nth(0).click();
	await expect(sidePanel.getByRole('heading', { name: 'Tornado Warning' })).toBeVisible();

	await expect(legend).not.toHaveAttribute('data-motion', 'static');
	await page.getByRole('button', { name: 'Stop blinking' }).click();
	await expect(legend).toHaveAttribute('data-motion', 'static');
});

test('respects prefers-reduced-motion: no live blink animation and only arrivals show New', async ({
	page
}) => {
	await page.emulateMedia({ reducedMotion: 'reduce' });
	await mockBackend(page);
	await page.goto('/globe');

	const legend = page.getByTestId('legend');
	await expect(legend).toHaveAttribute('data-motion', 'static');

	const dot = legend.locator('.legend-dot-q');
	await expect(dot).toHaveCSS('animation-name', 'none');

	// None of the fixture alerts came in as a live SSE arrival, so the
	// reduced-motion "New" substitute for the flash must not appear anywhere.
	await expect(page.getByText('New', { exact: true })).toHaveCount(0);
});

test('renders USGS points with filters and a correctly labelled event detail', async ({ page }) => {
	const pageErrors: Error[] = [];
	page.on('pageerror', (error) => pageErrors.push(error));
	await mockBackend(page);
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	const earthquakes = sidePanel.getByTestId('earthquake-feed-item');
	await expect(earthquakes).toHaveCount(2);
	await expect(earthquakes.nth(0)).toContainText('M5.3');
	await expect(page.locator('.maplibregl-canvas')).toBeVisible();
	await expect(page.getByTestId('earthquake-map-layer')).toHaveAttribute('data-ready', 'true');
	expect(pageErrors).toEqual([]);

	await earthquakes.nth(0).click();
	await expect(
		sidePanel.getByText('USGS tsunami screening flag; this is not a tsunami warning.')
	).toBeVisible();
	await expect(sidePanel.getByRole('link', { name: 'USGS event' })).toHaveAttribute(
		'href',
		'https://earthquake.usgs.gov/earthquakes/eventpage/us-test-5'
	);
	await expect(
		sidePanel.getByTestId('earthquake-event-sources').getByText('Credit: U.S. Geological Survey')
	).toBeVisible();

	// The detail view is a drill-in that replaces the list (no layout shift);
	// going back must restore it with every row intact.
	await sidePanel.getByRole('button', { name: 'Back to list' }).click();
	await expect(earthquakes.nth(1)).toBeVisible();

	const sevenDaySnapshot = page.waitForRequest((request) =>
		request.url().includes('/api/v1/earthquakes/recent?hours=168&minmag=2.5&type=earthquake')
	);
	await sidePanel.getByRole('button', { name: '7d' }).click();
	await sevenDaySnapshot;
	const allTypesSnapshot = page.waitForRequest((request) =>
		request.url().includes('/api/v1/earthquakes/recent?hours=168&minmag=2.5&type=all')
	);
	await sidePanel.getByRole('button', { name: 'All types' }).click();
	await allTypesSnapshot;
	const allMagnitudeSnapshot = page.waitForRequest((request) =>
		request.url().includes('/api/v1/earthquakes/recent?hours=168&minmag=all&type=all')
	);
	await sidePanel.getByRole('button', { name: 'All magnitudes' }).click();
	await allMagnitudeSnapshot;
});

test('lists both members of a matched event with their source, magnitude, and match method', async ({
	page
}) => {
	await mockBackend(page);
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	await sidePanel.getByTestId('earthquake-feed-item').nth(0).click();

	await expect(sidePanel.getByText(/U\.S\. Geological Survey.*M5\.3 mww.*origin/)).toBeVisible();
	await expect(sidePanel.getByText(/EMSC.*M5\.2 mw.*misfit \(misfit 0\.31\)/)).toBeVisible();
});

test('renders attribution for every source contributing to the selected event', async ({
	page
}) => {
	await mockBackend(page);
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	await sidePanel.getByTestId('earthquake-feed-item').nth(0).click();

	const eventSources = sidePanel.getByTestId('earthquake-event-sources');
	const usgsCredit = eventSources.getByRole('link', { name: 'Credit: U.S. Geological Survey' });
	await expect(usgsCredit).toHaveAttribute('href', 'https://earthquake.usgs.gov/');
	const emscCredit = eventSources.getByRole('link', {
		name: 'Credit: EMSC/CSEM, https://www.emsc-csem.org'
	});
	await expect(emscCredit).toHaveAttribute('href', 'https://www.seismicportal.eu/');
});

test('always shows attribution for every loaded source, ordered by priority, with no selection', async ({
	page
}) => {
	await mockBackend(page);
	await page.goto('/globe');

	const footer = page.getByTestId('side-panel').getByTestId('earthquake-attribution');
	const links = footer.getByRole('link');
	await expect(links).toHaveCount(2);
	await expect(links.nth(0)).toHaveText('Credit: U.S. Geological Survey');
	await expect(links.nth(1)).toHaveText('Credit: EMSC/CSEM, https://www.emsc-csem.org');
});

test('focuses an earthquake event by id from the query string', async ({ page }) => {
	await mockBackend(page);
	await page.goto('/globe?focus=4821');

	const sidePanel = page.getByTestId('side-panel');
	await expect(sidePanel.getByRole('heading', { name: 'Valparaiso, Chile' })).toBeVisible();
});
