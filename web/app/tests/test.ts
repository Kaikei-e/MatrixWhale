import { expect, test } from '@playwright/test';
import { mockBackend } from './fixtures';

test('home page has expected h1 and active US NWS alerts count', async ({ page }) => {
	await mockBackend(page);
	await page.goto('/');
	await expect(page.locator('h1')).toBeVisible();
	await expect(page.getByText(/active US NWS alert/)).toBeVisible();
});
