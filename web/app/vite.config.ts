import { sveltekit } from '@sveltejs/kit/vite';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vitest/config';
import { geometryTransportPlugin } from './scripts/geodata/geometry-transport.mjs';

export default defineConfig({
	plugins: [geometryTransportPlugin(), tailwindcss(), sveltekit()],
	test: {
		include: ['src/**/*.{test,spec}.{js,ts}']
	}
});
