import { expect, test } from '@playwright/test';
import { mockBackend } from './fixtures';

test.describe('Feed Health Page (/feeds)', () => {
	test('renders table, handles search, sorts columns, and toggles health filter', async ({
		page
	}) => {
		await mockBackend(page);
		await page.goto('/feeds');

		await expect(page.getByRole('heading', { name: /Feed Health/ })).toBeVisible();

		// Default filter includes ok, empty, stale, degraded, failing, pending (excludes excluded).
		// Our fixture has 5 feeds (1 ok, 1 failing, 1 degraded, 1 excluded, 1 pending).
		// So 4 rows should be rendered initially.
		const rows = page.getByTestId('feed-row');
		await expect(rows).toHaveCount(4);

		// Health chips show counts
		const excludedChip = page.getByTestId('feed-health-chip-excluded');
		await expect(excludedChip).toContainText('excluded (1)');

		// Toggle "excluded" chip to include excluded feeds
		await excludedChip.click();
		await expect(rows).toHaveCount(5);
		await expect(page.getByText('INMET', { exact: true })).toBeVisible();

		// Text search filtering
		const searchInput = page.getByTestId('feed-search-input');
		await searchInput.fill('Germany');
		await expect(page.getByTestId('feed-row')).toHaveCount(1);
		await expect(page.getByText('Deutscher Wetterdienst')).toBeVisible();

		await searchInput.fill('');
		await expect(page.getByTestId('feed-row')).toHaveCount(5);

		// Column header sorting
		// Click "Alerts" column header
		const alertsHeader = page.getByTestId('feed-th-active_alerts');
		await expect(alertsHeader).toHaveAttribute('aria-sort', 'none');

		// Click once: sorts descending (highest alert count first)
		await alertsHeader.click();
		await expect(alertsHeader).toHaveAttribute('aria-sort', 'descending');
		let firstRow = page.getByTestId('feed-row').first();
		await expect(firstRow).toContainText('Deutscher Wetterdienst'); // active_alerts: 5

		// Click again: sorts ascending (lowest alert count first)
		await alertsHeader.click();
		await expect(alertsHeader).toHaveAttribute('aria-sort', 'ascending');

		// Click "Country" column header
		const countryHeader = page.getByTestId('feed-th-country');
		await countryHeader.click();
		await expect(countryHeader).toHaveAttribute('aria-sort', 'ascending');
		firstRow = page.getByTestId('feed-row').first();
		await expect(firstRow).toContainText('Brazil'); // Brazil comes first alphabetically
	});

	test('table fits at 1280x800 viewport without horizontal overflow', async ({ page }) => {
		await page.setViewportSize({ width: 1280, height: 800 });
		await mockBackend(page);
		await page.goto('/feeds');

		const wrapper = page.getByTestId('feeds-table-wrapper');
		await expect(wrapper).toBeVisible();

		const fits = await wrapper.evaluate((el) => el.scrollWidth <= el.clientWidth);
		expect(fits).toBe(true);
	});

	test('renders WIS2 broker status, sortable table, and computes unique 24h & failures', async ({
		page
	}) => {
		await mockBackend(page);
		await page.goto('/feeds');

		// Broker status bar
		const brokerStatus = page.getByTestId('wis2-broker-status');
		await expect(brokerStatus).toBeVisible();
		await expect(brokerStatus).toContainText('Broker Connected');
		await expect(brokerStatus).toContainText('mqtts://globalbroker.meteo.fr:8883');

		// WIS2 channels table
		const wis2Rows = page.getByTestId('wis2-row');
		await expect(wis2Rows).toHaveCount(3);

		// Unique 24h column: received 450 - duplicates 50 = 400
		const eumetnetRow = page.getByTestId('wis2-row').filter({ hasText: 'eu-eumetnet-warnings' });
		await expect(eumetnetRow).toBeVisible();
		await expect(eumetnetRow).toContainText('warnings');
		await expect(eumetnetRow).toContainText('400'); // unique 24h primary number
		await expect(eumetnetRow).toContainText('50'); // duplicates

		// Failures column: download 4 + decode 1 + integrity 0 = 5 for in-imd
		const imdRow = page.getByTestId('wis2-row').filter({ hasText: 'in-imd' });
		await expect(imdRow).toBeVisible();
		await expect(imdRow).toContainText('5'); // failures total
		await expect(imdRow).toContainText('failing');

		// Column sorting on WIS2 table
		const centreHeader = page.getByTestId('wis2-th-centre');
		await expect(centreHeader).toHaveAttribute('aria-sort', 'none');

		// Sort ascending by centre_id: ecmwf comes first alphabetically
		await centreHeader.click();
		await expect(centreHeader).toHaveAttribute('aria-sort', 'ascending');
		let firstWis2Row = page.getByTestId('wis2-row').first();
		await expect(firstWis2Row).toContainText('ecmwf');

		// Sort descending by centre_id: in-imd comes first
		await centreHeader.click();
		await expect(centreHeader).toHaveAttribute('aria-sort', 'descending');
		firstWis2Row = page.getByTestId('wis2-row').first();
		await expect(firstWis2Row).toContainText('in-imd');
	});
});
