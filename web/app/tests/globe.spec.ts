import { expect, test } from '@playwright/test';
import { mockBackend } from './fixtures';

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

	// Default alert filters show Extreme and Severe only
	await expect(feedItems).toHaveCount(2);
	await expect(feedItems.nth(0)).toContainText('Tornado Warning');
	await expect(feedItems.nth(1)).toContainText('Flash Flood Warning');

	// Enable Minor and Unknown chips on the Alerts tab to show all 4 alerts
	await sidePanel.getByRole('tab', { name: /Alerts/ }).click();
	await sidePanel.getByRole('button', { name: 'Minor' }).click();
	await sidePanel.getByRole('button', { name: 'Unknown' }).click();
	await sidePanel.getByRole('tab', { name: 'Feed' }).click();

	await expect(feedItems).toHaveCount(4);
	await expect(feedItems.nth(0)).toContainText('Tornado Warning');
	await expect(feedItems.nth(1)).toContainText('Flash Flood Warning');
	await expect(feedItems.nth(2)).toContainText('Frost Advisory');
	await expect(feedItems.nth(3)).toContainText('Wind gust advisory');

	await feedItems.nth(0).click();
	await expect(sidePanel.getByRole('heading', { name: /Tornado Warning/ })).toBeVisible();

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

test('legend: NWS colors summary counts only NOAA alerts and stale dashed/dotted rows are removed', async ({
	page
}) => {
	await mockBackend(page);
	await page.goto('/globe');

	const legend = page.getByTestId('legend');
	await expect(legend).toBeVisible();

	// Stale rows are removed
	await expect(legend.getByText('dashed line')).not.toBeVisible();
	await expect(legend.getByText('dotted line')).not.toBeVisible();

	// Toggle NWS colors on
	await page.evaluate(() => localStorage.setItem('alerts.useNwsColors', 'true'));
	await page.reload();

	const nwsSummary = legend.getByTestId('nws-colors-summary');
	await expect(nwsSummary).toBeVisible();

	// NOAA alerts are present in NWS colors summary
	await expect(nwsSummary.getByText('Tornado Warning')).toBeVisible();
	await expect(nwsSummary.getByText('Flash Flood Warning')).toBeVisible();

	// Non-NOAA alerts (Frost Advisory, Wind Warning) are NOT in NWS colors summary
	await expect(nwsSummary.getByText('Wind Warning')).not.toBeVisible();
	await expect(nwsSummary.getByText('Frost Advisory')).not.toBeVisible();
});

test('renders model forecast section and table in tropical cyclone hazard detail', async ({
	page
}) => {
	await mockBackend(page);
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	await sidePanel.getByRole('tab', { name: /Hazards/ }).click();

	// Click the TC hazard row
	await sidePanel.getByText('Tropical Cyclone Test').click();

	// Check model forecast section appears
	const forecastSection = sidePanel.getByTestId('tc-forecast-tracks');
	await expect(forecastSection).toBeVisible();
	await expect(forecastSection.getByText('Model forecast')).toBeVisible();
	await expect(forecastSection.getByText('ecmwf')).toBeVisible();

	// Check table content
	const forecastTable = sidePanel.getByTestId('forecast-track-table');
	await expect(forecastTable).toBeVisible();
	await expect(forecastTable).toContainText('+0h');
	await expect(forecastTable).toContainText('+24h');
	await expect(forecastTable).toContainText('14.5N 120.5E');
	await expect(forecastTable).toContainText('992');
	await expect(forecastTable).toContainText('29 m/s');

	// Assert the table's scrollWidth <= clientWidth of the pane (no horizontal overflow)
	const tableFitsPane = await forecastTable.evaluate((table) => {
		const pane = table.closest('[data-testid="side-panel"]');
		const paneClientWidth = pane ? pane.clientWidth : 380;
		return table.scrollWidth <= paneClientWidth;
	});
	expect(tableFitsPane).toBe(true);

	const containerFits = await forecastTable.evaluate((table) => {
		const container = table.parentElement;
		return container ? container.scrollWidth <= container.clientWidth : true;
	});
	expect(containerFits).toBe(true);

	// Max wind header and values are fully visible
	await expect(forecastTable.getByText('Max wind')).toBeVisible();
	await expect(forecastTable.getByText('29 m/s')).toBeVisible();

	// Wind radii are available via row tooltip and per-row expandable detail (numbers only, km)
	const row0 = forecastTable.locator('tr', { hasText: '+0h' });
	await expect(row0).toHaveAttribute('title', /18: 180 · 26: 80 km/);
	await row0.click();
	await expect(forecastTable).toContainText('18: 180 · 26: 80 km');

	// Back to list restores hazards list
	await sidePanel.getByRole('button', { name: 'Back to list' }).click();
	await expect(sidePanel.getByText('Tropical Cyclone Test')).toBeVisible();
});

test('filters observed extremes by subtype, toggles hide unconfirmed, and toggles chart layer', async ({
	page
}) => {
	await mockBackend(page);
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	await sidePanel.getByRole('tab', { name: /Hazards/ }).click();

	// Subtype filter chips exist
	await expect(sidePanel.getByTestId('hazard-subtype-chip-gust')).toBeVisible();
	await expect(sidePanel.getByTestId('hazard-subtype-chip-rain_1h')).toBeVisible();

	// Both observed extremes appear initially
	await expect(sidePanel.getByText(/Gust 34\.2 m\/s/)).toBeVisible();
	await expect(sidePanel.getByText(/Rain 52\.0 mm\/h/)).toBeVisible();

	// Test "Hide unconfirmed" checkbox
	const hideUnconfirmedCheckbox = sidePanel.getByTestId('hide-unconfirmed-checkbox');
	await hideUnconfirmedCheckbox.check();

	// Unconfirmed rain extreme is hidden
	await expect(sidePanel.getByText(/Rain 52\.0 mm\/h/)).not.toBeVisible();
	// Confirmed gust extreme remains
	await expect(sidePanel.getByText(/Gust 34\.2 m\/s/)).toBeVisible();

	// Uncheck: unconfirmed extreme reappears
	await hideUnconfirmedCheckbox.uncheck();
	await expect(sidePanel.getByText(/Rain 52\.0 mm\/h/)).toBeVisible();

	// Subtype chip filter: toggle gust off
	await sidePanel.getByTestId('hazard-subtype-chip-gust').click();
	await expect(sidePanel.getByText(/Gust 34\.2 m\/s/)).not.toBeVisible();
	await expect(sidePanel.getByText(/Rain 52\.0 mm\/h/)).toBeVisible();

	// Toggle gust back on
	await sidePanel.getByTestId('hazard-subtype-chip-gust').click();
	await expect(sidePanel.getByText(/Gust 34\.2 m\/s/)).toBeVisible();

	// Inspect detail for observed extreme
	await sidePanel.getByText(/Gust 34\.2 m\/s/).click();
	await expect(sidePanel.getByText('Observed value: 34.2 m/s')).toBeVisible();
	await expect(sidePanel.getByText('Confirmed', { exact: true })).toBeVisible();

	// Chart layer toggle button
	const toggleBtn = page.getByTestId('toggle-observed-extremes');
	await expect(toggleBtn).toBeVisible();
	await expect(toggleBtn).toHaveAttribute('data-active', 'true');
	await toggleBtn.click();
	await expect(toggleBtn).toHaveAttribute('data-active', 'false');
	await toggleBtn.click();
	await expect(toggleBtn).toHaveAttribute('data-active', 'true');
});
