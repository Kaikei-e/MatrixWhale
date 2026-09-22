import type { Handle } from '@sveltejs/kit';
import {
	LAND_50M,
	ZONE_CENTROIDS,
	FORECAST_ZONES,
	COUNTY_ZONES,
	MARINE_COASTAL_ZONES,
	MARINE_OFFSHORE_ZONES
} from '$lib/chart/dataFiles';

const GLOBE_PRELOADS = [
	LAND_50M,
	ZONE_CENTROIDS,
	FORECAST_ZONES,
	COUNTY_ZONES,
	MARINE_COASTAL_ZONES,
	MARINE_OFFSHORE_ZONES
];

export const handle: Handle = async ({ event, resolve }) => {
	const response = await resolve(event);

	response.headers.set(
		'Content-Security-Policy',
		"connect-src 'self'; worker-src 'self'; img-src 'self' data: blob:"
	);

	if (event.url.pathname.startsWith('/data/')) {
		response.headers.set('Cache-Control', 'public, max-age=31536000, immutable');
	}

	if (event.url.pathname === '/globe') {
		for (const url of GLOBE_PRELOADS) {
			response.headers.append(
				'Link',
				'<' + url + '>; rel=preload; as=fetch; crossorigin=anonymous'
			);
		}
	}

	return response;
};
