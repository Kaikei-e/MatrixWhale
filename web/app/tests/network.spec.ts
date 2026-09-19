import { expect, test } from '@playwright/test';
import { mockBackend } from './fixtures';

test('fetches static map data and source attribution once across map and filter updates', async ({
	page
}) => {
	await mockBackend(page);
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('Network.enable');
	await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });
	const geodata = new Map<string, number>();
	let sources = 0;
	page.on('request', (request) => {
		const path = new URL(request.url()).pathname;
		if (path.startsWith('/data/') && !path.includes('centroids')) {
			geodata.set(path, (geodata.get(path) ?? 0) + 1);
		}
		if (path === '/api/v1/sources') sources++;
	});
	await page.goto('/globe');
	await expect(page.getByTestId('earthquake-map-layer')).toHaveAttribute('data-ready', 'true');
	await expect.poll(() => geodata.size).toBe(5);
	await page.getByRole('button', { name: 'CONUS', exact: true }).click();
	await page.getByRole('button', { name: 'Switch to night theme' }).click();
	const pane = page.getByTestId('side-panel');
	await pane.getByRole('tab', { name: /Alerts/ }).click();
	await pane.getByRole('button', { name: 'Minor', exact: true }).click();
	await page.getByRole('button', { name: 'Stop blinking' }).click();
	// Allow worker source updates and the map transition to finish; a URL-backed
	// source used to make another network request during these updates.
	await page.waitForTimeout(1500);
	expect([...geodata.values()]).toEqual([1, 1, 1, 1, 1]);
	expect(sources).toBe(1);
});
