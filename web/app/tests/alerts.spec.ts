import { expect, test } from '@playwright/test';
import { ALERTS, mockBackend, SseInjector } from './fixtures';

test.describe('Alerts tab in SidePane', () => {
	test('shows count badge, filters by severity and country, and opens alert detail', async ({
		page
	}) => {
		await mockBackend(page);
		await page.goto('/globe');

		const sidePanel = page.getByTestId('side-panel');
		const alertsTab = sidePanel.getByRole('tab', { name: /Alerts/ });
		await expect(alertsTab).toBeVisible();

		// Count badge on tab: default severity filter is Extreme, Severe, Moderate.
		// ALERTS has 2 matching alerts (Tornado Warning: Extreme, Flash Flood Warning: Severe).
		// The 2 minor alerts (Frost Advisory, Wind Warning) are filtered out.
		await expect(alertsTab).toContainText('2');

		await alertsTab.click();

		// Verify list has 2 items initially
		let alertItems = sidePanel.getByTestId('alert-feed-item');
		await expect(alertItems).toHaveCount(2);
		await expect(alertItems.nth(0)).toContainText('Tornado Warning');
		await expect(alertItems.nth(1)).toContainText('Flash Flood Warning');

		// Verify attribution footer lists sources
		const footer = sidePanel.getByTestId('alert-attribution');
		await expect(footer).toBeVisible();
		await expect(footer).toContainText('National Weather Service');

		// Toggle "Minor" severity chip to include minor alerts
		const minorChip = sidePanel.getByRole('button', { name: 'Minor' });
		await minorChip.click();

		// Now 4 items should be visible (including Frost Advisory and German Wind Warning)
		alertItems = sidePanel.getByTestId('alert-feed-item');
		await expect(alertItems).toHaveCount(4);
		await expect(alertsTab).toContainText('4');
		await expect(sidePanel.getByText('Wind gust advisory')).toBeVisible();

		// Filter by Country dropdown
		const countrySelect = sidePanel.getByLabel('Filter by country');
		await expect(countrySelect).toBeVisible();

		// Select Germany (DEU)
		await countrySelect.selectOption('DEU');
		alertItems = sidePanel.getByTestId('alert-feed-item');
		await expect(alertItems).toHaveCount(1);
		await expect(alertItems.nth(0)).toContainText('Wind gust advisory');
		await expect(alertItems.nth(0)).toContainText('Germany');

		// Select All countries
		await countrySelect.selectOption('all');
		await expect(sidePanel.getByTestId('alert-feed-item')).toHaveCount(4);

		// Click German alert row to open detail panel and verify lazy fetch
		const detailRequestPromise = page.waitForRequest(
			(req) => req.url().includes('/api/v1/alerts/detail') && req.url().includes('DWD.PVW.20260917')
		);
		await alertItems.filter({ hasText: 'Wind gust advisory' }).click();
		await detailRequestPromise;

		// Verify DetailPanel content
		const detailHeading = sidePanel.getByRole('heading', { name: /Wind gust advisory/ });
		await expect(detailHeading).toBeVisible();
		await expect(
			sidePanel.getByText('Es treten Windböen mit Geschwindigkeiten bis 60 km/h auf.')
		).toBeVisible();
		await expect(sidePanel.getByText('Achten Sie auf herabfallende Äste.')).toBeVisible();
		await expect(sidePanel.getByTestId('alert-detail-attribution')).toContainText(
			'Deutscher Wetterdienst'
		);

		// Back to list restores scroll/filter state
		await sidePanel.getByRole('button', { name: 'Back to list' }).click();
		await expect(sidePanel.getByTestId('alert-feed-item')).toHaveCount(4);
	});

	test('retains detail on SSE ended and refetches on SSE resync', async ({ page }) => {
		await mockBackend(page);
		const alertSse = new SseInjector(page);
		await alertSse.install();
		await page.goto('/globe');

		const sidePanel = page.getByTestId('side-panel');
		const alertsTab = sidePanel.getByRole('tab', { name: /Alerts/ });
		await alertsTab.click();

		// Initially 2 active alerts (Tornado Warning, Flash Flood Warning)
		const alertItems = sidePanel.getByTestId('alert-feed-item');
		await expect(alertItems).toHaveCount(2);

		// Click the Tornado Warning to open its detail
		await alertItems.nth(0).click();
		await expect(sidePanel.getByRole('heading', { name: /Tornado Warning/ })).toBeVisible();

		// Push SSE ended event for Tornado Warning
		alertSse.push('alerts.ended', {
			...ALERTS[0],
			ended_at: new Date().toISOString(),
			end_reason: 'expired'
		});

		// Detail panel remains open and renders the state line indicating Expired
		const stateLine = sidePanel.getByTestId('alert-state-line');
		await expect(stateLine).toBeVisible();
		await expect(stateLine).toContainText('Expired');

		// Close detail view
		await sidePanel.getByRole('button', { name: 'Back to list' }).click();

		// List now only contains 1 active alert (Flash Flood Warning)
		await expect(sidePanel.getByTestId('alert-feed-item')).toHaveCount(1);
		await expect(alertsTab).toContainText('1');

		// Now push SSE resync event: triggers #loadSnapshot which refetches /api/v1/alerts/active
		const resyncFetchPromise = page.waitForRequest((req) =>
			req.url().includes('/api/v1/alerts/active')
		);
		alertSse.push('alerts.resync', { type: 'resync' });
		await resyncFetchPromise;

		// Once snapshot is reloaded, active count returns to 2
		await expect(alertsTab).toContainText('2');
		await expect(sidePanel.getByTestId('alert-feed-item')).toHaveCount(2);
	});

	test('Feed tab count badge and FeedPanel severity breakdown use filtered alerts', async ({
		page
	}) => {
		await mockBackend(page);
		await page.goto('/globe');

		const sidePanel = page.getByTestId('side-panel');
		const feedTab = sidePanel.getByRole('tab', { name: /Feed/ });
		await expect(feedTab).toBeVisible();

		// Feed tab count badge should show filtered count (2), not sorted count (4)
		await expect(feedTab).toContainText('2');

		await feedTab.click();

		// FeedPanel per-severity breakdown: Minor is filtered out by default, so Minor should not be shown
		await expect(sidePanel.getByText(/Extreme 1/)).toBeVisible();
		await expect(sidePanel.getByText(/Severe 1/)).toBeVisible();
		await expect(sidePanel.getByText(/Minor/)).not.toBeVisible();
	});

	test('update of the same alert id with new last_seen_at refetches detail', async ({ page }) => {
		await mockBackend(page);
		const alertSse = new SseInjector(page);
		await alertSse.install();
		await page.goto('/globe');

		const sidePanel = page.getByTestId('side-panel');
		const alertsTab = sidePanel.getByRole('tab', { name: /Alerts/ });
		await alertsTab.click();

		let detailFetchCount = 0;
		page.on('request', (req) => {
			if (req.url().includes('/api/v1/alerts/detail')) {
				detailFetchCount++;
			}
		});

		// Click the Tornado Warning to open its detail
		const alertItems = sidePanel.getByTestId('alert-feed-item');
		await alertItems.nth(0).click();
		await expect(sidePanel.getByRole('heading', { name: /Tornado Warning/ })).toBeVisible();

		// Initial detail fetch has occurred exactly once
		expect(detailFetchCount).toBe(1);

		// Push SSE update for the SAME alert id with a new last_seen_at
		alertSse.push('alerts.update', {
			...ALERTS[0],
			headline: 'Tornado Warning Updated By Radar',
			last_seen_at: new Date().toISOString()
		});

		// The updated headline is rendered
		await expect(
			sidePanel.getByRole('heading', { name: /Tornado Warning Updated By Radar/ })
		).toBeVisible();

		// Detail WAS refetched due to new last_seen_at
		expect(detailFetchCount).toBe(2);
	});

	test('Alerts tab rows include severity as text for accessibility', async ({ page }) => {
		await mockBackend(page);
		await page.goto('/globe');

		const sidePanel = page.getByTestId('side-panel');
		const alertsTab = sidePanel.getByRole('tab', { name: /Alerts/ });
		await alertsTab.click();

		const alertItems = sidePanel.getByTestId('alert-feed-item');
		// ALERTS[0] is Extreme, ALERTS[1] is Severe
		await expect(alertItems.nth(0)).toContainText('Extreme');
		await expect(alertItems.nth(1)).toContainText('Severe');
	});

	test('side-pane detail does not duplicate headline when showHeader is false', async ({
		page
	}) => {
		await mockBackend(page);
		await page.goto('/globe');

		const sidePanel = page.getByTestId('side-panel');
		const alertsTab = sidePanel.getByRole('tab', { name: /Alerts/ });
		await alertsTab.click();

		const alertItems = sidePanel.getByTestId('alert-feed-item');
		await alertItems.nth(0).click();

		// DetailHeader displays the headline in an h2
		await expect(sidePanel.getByRole('heading', { name: 'Tornado Warning issued' })).toBeVisible();

		// The body paragraph should NOT duplicate the headline when showHeader is false
		await expect(sidePanel.getByText('Tornado Warning issued')).toHaveCount(1);
	});
});
