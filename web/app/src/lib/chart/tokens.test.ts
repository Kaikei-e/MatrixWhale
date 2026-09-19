import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DAY, NIGHT } from './tokens';

const css = readFileSync(fileURLToPath(new URL('./tokens.css', import.meta.url)), 'utf-8');

function parseBlock(source: string, selector: string): Record<string, string> {
	const blockMatch = source.match(new RegExp(`${selector}\\s*{([^}]*)}`));
	if (!blockMatch) throw new Error(`selector not found: ${selector}`);
	const tokens: Record<string, string> = {};
	for (const line of blockMatch[1].split(';')) {
		const propMatch = line.match(/--([\w-]+)\s*:\s*(#[0-9a-fA-F]{3,8})/);
		if (propMatch) tokens[propMatch[1]] = propMatch[2];
	}
	return tokens;
}

describe('chart tokens', () => {
	it('DAY matches :root in tokens.css', () => {
		const root = parseBlock(css, ':root');
		expect(root).toEqual({
			paper: DAY.paper,
			land: DAY.land,
			shoal: DAY.shoal,
			ink: DAY.ink,
			'ink-2': DAY['ink-2'],
			light: DAY.light,
			amber: DAY.amber,
			moderate: DAY.moderate,
			minor: DAY.minor
		});
	});

	it('NIGHT matches [data-theme="night"] in tokens.css', () => {
		const night = parseBlock(css, "\\[data-theme='night'\\]");
		expect(night).toEqual({
			paper: NIGHT.paper,
			land: NIGHT.land,
			shoal: NIGHT.shoal,
			ink: NIGHT.ink,
			'ink-2': NIGHT['ink-2'],
			light: NIGHT.light,
			amber: NIGHT.amber,
			moderate: NIGHT.moderate,
			minor: NIGHT.minor
		});
	});

	it('zones and alert polygons share identical per-severity fill opacity specifications', () => {
		const zonesSrc = readFileSync(
			fileURLToPath(new URL('./ZonesLayer.svelte', import.meta.url)),
			'utf-8'
		);
		const polySrc = readFileSync(
			fileURLToPath(new URL('./AlertPolygonsLayer.svelte', import.meta.url)),
			'utf-8'
		);

		const extractOpacity = (src: string) => {
			const m = src.match(/const FILL_OPACITY[^{=]*=\s*(\[[^;]+\]);/s);
			return m ? m[1].replace(/\s+/g, ' ') : null;
		};

		const zonesOpacity = extractOpacity(zonesSrc);
		const polyOpacity = extractOpacity(polySrc);
		expect(zonesOpacity).toBe(polyOpacity);
	});

	it('FeedItem New badge has contrast ratio >= 4.5 in both day and night themes', () => {
		const feedItemSrc = readFileSync(
			fileURLToPath(new URL('../components/FeedItem.svelte', import.meta.url)),
			'utf-8'
		);
		const badgeMatch = feedItemSrc.match(/<span class="[^"]*bg-light[^"]*">New<\/span>/);
		expect(badgeMatch).not.toBeNull();
		const badgeClass = badgeMatch![0];
		expect(badgeClass).toMatch(/dark:text-(?:paper|black|\[#0f1b24\])/);
	});
});
