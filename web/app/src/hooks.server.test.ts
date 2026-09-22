import { describe, it, expect, vi } from 'vitest';
import { handle } from './hooks.server';
import {
	LAND_50M,
	LAND_110M,
	ZONE_CENTROIDS,
	FORECAST_ZONES,
	COUNTY_ZONES,
	MARINE_COASTAL_ZONES,
	MARINE_OFFSHORE_ZONES
} from '$lib/chart/dataFiles';
import type { RequestEvent } from '@sveltejs/kit';

describe('hooks.server handle', () => {
	it('adds Link preload headers for /globe', async () => {
		const event = {
			url: new URL('http://localhost/globe')
		} as unknown as RequestEvent;

		const resolve = vi.fn().mockResolvedValue(new Response('<html></html>'));

		const response = await handle({ event, resolve });

		const linkHeader = response.headers.get('Link');
		expect(linkHeader).toBeDefined();

		const expectedUrls = [
			LAND_50M,
			ZONE_CENTROIDS,
			FORECAST_ZONES,
			COUNTY_ZONES,
			MARINE_COASTAL_ZONES,
			MARINE_OFFSHORE_ZONES
		];
		for (const url of expectedUrls) {
			expect(linkHeader).toContain(`<${url}>; rel=preload; as=fetch; crossorigin=anonymous`);
		}
		expect(linkHeader).not.toContain(LAND_110M);
	});

	it('does not add Link preload headers for /', async () => {
		const event = {
			url: new URL('http://localhost/')
		} as unknown as RequestEvent;

		const resolve = vi.fn().mockResolvedValue(new Response('<html></html>'));

		const response = await handle({ event, resolve });

		expect(response.headers.get('Link')).toBeNull();
	});
});
