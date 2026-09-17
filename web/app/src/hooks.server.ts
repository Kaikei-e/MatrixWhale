import type { Handle } from '@sveltejs/kit';

export const handle: Handle = async ({ event, resolve }) => {
	const response = await resolve(event);

	response.headers.set(
		'Content-Security-Policy',
		"connect-src 'self'; worker-src 'self'; img-src 'self' data: blob:"
	);

	if (event.url.pathname.startsWith('/data/')) {
		response.headers.set('Cache-Control', 'public, max-age=31536000, immutable');
	}

	return response;
};
