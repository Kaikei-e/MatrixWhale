import { expect, test, type Page } from '@playwright/test';
import { mockBackend, SseInjector } from './fixtures';

// Short enough that the seven-row page-1 fixture overflows the list without
// scrolling, so the bottom sentinel never auto-intersects on mount.
test.use({ viewport: { width: 1280, height: 450 } });

const T0 = '2026-09-18T12:00:00Z';
function minutesBefore(minutes: number): string {
	return new Date(new Date(T0).getTime() - minutes * 60000).toISOString();
}

function earthquakeItem(id: number, seenAt: string, overrides: Record<string, unknown> = {}) {
	const seenAtMs = new Date(seenAt).getTime();
	return {
		kind: 'earthquake',
		key: `earthquake:${id}`,
		seen_at: seenAt,
		seen_at_ms: seenAtMs,
		severity: 'severe',
		ended: false,
		earthquake: {
			id,
			kind: 'earthquake',
			magnitude: 6.1,
			magnitude_type: 'mww',
			occurred_at: seenAt,
			occurred_at_ms: seenAtMs,
			updated_at: seenAt,
			updated_at_ms: seenAtMs,
			place: 'Test Trench',
			title: 'M 6.1 - Test Trench',
			status: 'reviewed',
			event_type: 'earthquake',
			tsunami: 0,
			significance: 500,
			alert: null,
			mmi: null,
			cdi: null,
			felt: null,
			nst: null,
			dmin: null,
			rms: null,
			gap: null,
			net: 'us',
			code: `tl-${id}`,
			url: null,
			detail: null,
			longitude: 140,
			latitude: 35,
			depth_km: 10,
			preferred_source: 'usgs',
			sources: ['usgs'],
			members: [],
			first_seen_at: seenAt,
			last_seen_at: seenAt,
			...overrides
		}
	};
}

function hazardItem(sourceId: string, seenAt: string, overrides: Record<string, unknown> = {}) {
	const seenAtMs = new Date(seenAt).getTime();
	return {
		kind: 'hazard',
		key: `hazard:gdacs:${sourceId}`,
		seen_at: seenAt,
		seen_at_ms: seenAtMs,
		severity: 'severe',
		ended: false,
		hazard: {
			id: `gdacs:${sourceId}`,
			source: 'gdacs',
			source_id: sourceId,
			source_type_code: 'FL',
			hazard_type: 'flood',
			hazard_codes: [],
			glide: null,
			alert_level: 'orange',
			alert_score: 1.5,
			cap_severity: 'severe',
			severity_value: null,
			severity_unit: null,
			severity_label: null,
			estimate_type: 'primary',
			title: 'River Overflow Test',
			description: 'Timeline flood fixture',
			countries: ['PHL'],
			report_url: null,
			onset_at: seenAt,
			onset_at_ms: seenAtMs,
			expires_at: seenAt,
			expires_at_ms: seenAtMs,
			modified_at: seenAt,
			modified_at_ms: seenAtMs,
			is_current: true,
			episode_id: '1',
			episode_count: 1,
			longitude: 121,
			latitude: 14,
			bbox: [120, 13, 122, 15],
			primary_geometry: null,
			external_ids: [],
			first_seen_at: seenAt,
			last_seen_at: seenAt,
			...overrides
		}
	};
}

function alertItem(id: string, seenAt: string, overrides: Record<string, unknown> = {}) {
	const seenAtMs = new Date(seenAt).getTime();
	return {
		kind: 'alert',
		key: `alert:${id}`,
		seen_at: seenAt,
		seen_at_ms: seenAtMs,
		severity: 'extreme',
		ended: false,
		alert: {
			id,
			source: 'noaa',
			source_id: id,
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
			headline: null,
			language: 'en-US',
			web: null,
			area_desc: 'Test County, OK',
			geocodes: [],
			geometry: null,
			sent: seenAt,
			effective: seenAt,
			expires: seenAt,
			ends: null,
			first_seen_at: seenAt,
			last_seen_at: seenAt,
			ended_at: null,
			end_reason: null,
			superseded_by: null,
			...overrides
		}
	};
}

const PAGE1_ITEMS = [
	earthquakeItem(501, minutesBefore(1)),
	hazardItem('FL-9001', minutesBefore(2)),
	{
		...alertItem('urn:oid:ended.1', minutesBefore(3), {
			ended_at: minutesBefore(1),
			event: 'Flash Flood Warning'
		}),
		ended: true
	},
	alertItem('urn:oid:active.1', minutesBefore(4), { event: 'Winter Storm Warning' }),
	earthquakeItem(502, minutesBefore(5), { place: 'Older Trench' }),
	hazardItem('FL-9002', minutesBefore(6), { title: 'Second Flood' }),
	earthquakeItem(503, minutesBefore(7), { place: 'Even Older Trench' })
];

const PAGE1 = {
	items: PAGE1_ITEMS,
	next_cursor: 'cursor-page-2',
	generated_at: T0
};

const PAGE2 = {
	items: [earthquakeItem(504, minutesBefore(8), { place: 'Oldest Trench' })],
	next_cursor: null,
	generated_at: T0
};

async function mockTimeline(page: Page): Promise<void> {
	await page.route('**/api/v1/timeline**', (route) => {
		const url = new URL(route.request().url());
		const before = url.searchParams.get('before');
		route.fulfill({ json: before ? PAGE2 : PAGE1 });
	});
}

test('the Timeline tab is first and lists rows newest first with the right primary text', async ({
	page
}) => {
	await mockBackend(page);
	await mockTimeline(page);
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	const tabs = sidePanel.getByRole('tab');
	await expect(tabs.first()).toHaveText(/Timeline/);

	await tabs.first().click();
	const rows = sidePanel.getByTestId('timeline-item');
	await expect(rows).toHaveCount(7);
	await expect(rows.nth(0)).toContainText('M6.1 · Test Trench');
	await expect(rows.nth(1)).toContainText('Flood · River Overflow Test');
	await expect(rows.nth(2)).toContainText('Flash Flood Warning');
	await expect(rows.nth(2)).toContainText('United States · National Weather Service');
	await expect(rows.nth(2).getByTestId('timeline-badge-ended')).toBeVisible();
});

test('scrolling to the sentinel loads page 2 and shows No more events', async ({ page }) => {
	await mockBackend(page);
	await mockTimeline(page);
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	await sidePanel.getByRole('tab', { name: /Timeline/ }).click();
	await expect(sidePanel.getByTestId('timeline-item')).toHaveCount(7);

	const request = page.waitForRequest((req) => req.url().includes('before=cursor-page-2'));
	await sidePanel.getByTestId('timeline-sentinel').scrollIntoViewIfNeeded();
	await request;

	await expect(sidePanel.getByTestId('timeline-item')).toHaveCount(8);
	await expect(sidePanel.getByText('No more events')).toBeVisible();
});

test('injecting an SSE new earthquake while at the top inserts it immediately', async ({
	page
}) => {
	await mockBackend(page);
	await mockTimeline(page);
	const earthquakeSse = new SseInjector(page);
	await earthquakeSse.install();
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	await sidePanel.getByRole('tab', { name: /Timeline/ }).click();
	await expect(sidePanel.getByTestId('timeline-item')).toHaveCount(7);

	earthquakeSse.push('earthquakes.new', {
		...earthquakeItem(999, T0).earthquake,
		place: 'Brand New Quake'
	});

	await expect(sidePanel.getByTestId('timeline-item').first()).toContainText('Brand New Quake');
	await expect(sidePanel.getByTestId('timeline-new-pill')).toHaveCount(0);
});

test('injecting while scrolled down shows the "1 new" pill; clicking it inserts and scrolls to top', async ({
	page
}) => {
	await mockBackend(page);
	await mockTimeline(page);
	const earthquakeSse = new SseInjector(page);
	await earthquakeSse.install();
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	await sidePanel.getByRole('tab', { name: /Timeline/ }).click();
	const list = sidePanel.getByTestId('timeline-list');
	await expect(sidePanel.getByTestId('timeline-item')).toHaveCount(7);
	await list.evaluate((el) => {
		el.scrollTop = 200;
	});

	earthquakeSse.push('earthquakes.new', {
		...earthquakeItem(998, T0).earthquake,
		place: 'Pending Quake'
	});

	const pill = sidePanel.getByTestId('timeline-new-pill');
	await expect(pill).toHaveText('1 new');
	await expect(sidePanel.getByTestId('timeline-item').first()).not.toContainText('Pending Quake');

	await pill.click();

	await expect(sidePanel.getByTestId('timeline-item').first()).toContainText('Pending Quake');
	await expect(sidePanel.getByTestId('timeline-new-pill')).toHaveCount(0);
	await expect(list).toHaveJSProperty('scrollTop', 0);
});

test('injecting an update for a visible key shows the updated badge without moving the row', async ({
	page
}) => {
	await mockBackend(page);
	await mockTimeline(page);
	const earthquakeSse = new SseInjector(page);
	await earthquakeSse.install();
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	await sidePanel.getByRole('tab', { name: /Timeline/ }).click();
	const rows = sidePanel.getByTestId('timeline-item');
	await expect(rows).toHaveCount(7);
	await expect(rows.nth(0)).toContainText('Test Trench');

	earthquakeSse.push('earthquakes.update', {
		...earthquakeItem(501, minutesBefore(1)).earthquake,
		place: 'Revised Trench'
	});

	await expect(rows.nth(0)).toContainText('Revised Trench');
	await expect(rows.nth(0).getByTestId('timeline-badge-updated')).toBeVisible();
	await expect(rows).toHaveCount(7);
});

test('clicking a row opens detail and back returns to the list', async ({ page }) => {
	await mockBackend(page);
	await mockTimeline(page);
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	await sidePanel.getByRole('tab', { name: /Timeline/ }).click();
	const rows = sidePanel.getByTestId('timeline-item');
	await rows.nth(0).click();

	await expect(sidePanel.getByRole('heading', { name: 'Test Trench' })).toBeVisible();

	await sidePanel.getByRole('button', { name: 'Back to list' }).click();
	await expect(sidePanel.getByTestId('timeline-item')).toHaveCount(7);
});

test('toggling a kind filter chip refetches with the kinds= param', async ({ page }) => {
	await mockBackend(page);
	await mockTimeline(page);
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	await sidePanel.getByRole('tab', { name: /Timeline/ }).click();
	await expect(sidePanel.getByTestId('timeline-item')).toHaveCount(7);

	const request = page.waitForRequest(
		(req) => req.url().includes('/api/v1/timeline') && req.url().includes('kinds=hazard%2Calert')
	);
	await sidePanel.getByTestId('timeline-filter-kind-earthquake').click();
	await request;
});

test('Timeline alert rows include severity as text for accessibility', async ({ page }) => {
	await mockBackend(page);
	await mockTimeline(page);
	await page.goto('/globe');

	const sidePanel = page.getByTestId('side-panel');
	await sidePanel.getByRole('tab', { name: /Timeline/ }).click();
	const rows = sidePanel.getByTestId('timeline-item');
	// Index 3 is alert item with Extreme severity
	await expect(rows.nth(3)).toContainText('Extreme');
});
