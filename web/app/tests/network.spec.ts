import { expect, test } from '@playwright/test';
import { readFile } from 'node:fs/promises';
import { mockBackend } from './fixtures';

test('starts snapshots while the map module is still downloading', async ({ page }) => {
	await mockBackend(page);
	const manifest = JSON.parse(
		await readFile(
			new URL('../.svelte-kit/output/client/.vite/manifest.json', import.meta.url),
			'utf8'
		)
	);
	const mapModule = manifest['src/lib/chart/GlobeMap.svelte'].file;
	let releaseMap!: () => void;
	const mapDownload = new Promise<void>((resolve) => {
		releaseMap = resolve;
	});
	let mapRequested = false;
	const snapshots = new Set<string>();
	page.on('request', (request) => {
		const path = new URL(request.url()).pathname;
		if (path.endsWith('/recent') || path.endsWith('/active')) snapshots.add(path);
	});
	await page.route(`**/${mapModule}`, async (route) => {
		mapRequested = true;
		await mapDownload;
		await route.continue();
	});
	try {
		await page.goto('/globe', { waitUntil: 'domcontentloaded' });
		await expect.poll(() => mapRequested).toBe(true);
		await expect.poll(() => snapshots.size).toBe(3);
		await expect(page.locator('canvas')).toHaveCount(0);
	} finally {
		releaseMap();
	}
	await expect(page.getByTestId('earthquake-map-layer')).toHaveAttribute('data-ready', 'true');
});

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

test('shares a single SSE transport socket across alerts, earthquakes, and hazards stores', async ({
	page
}) => {
	await mockBackend(page);
	const sseRequests: string[] = [];
	page.on('request', (request) => {
		const url = new URL(request.url());
		if (url.pathname.includes('/stream')) {
			sseRequests.push(url.pathname + url.search);
		}
	});

	await page.goto('/globe');
	await expect(page.getByTestId('earthquake-map-layer')).toHaveAttribute('data-ready', 'true');

	// Expect exactly 1 SSE connection opened across the entire page (reduced 3 -> 1)
	expect(sseRequests).toEqual(['/api/v1/stream?geometry=polyline']);
});
