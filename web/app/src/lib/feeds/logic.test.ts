import { describe, it, expect } from 'vitest';
import {
	computeHealthCounts,
	filterFeeds,
	sortFeeds,
	formatFeedDisplayUrl,
	isHttpUrl
} from './logic';
import type { CapFeed, FeedHealth } from './types';

function makeFeed(overrides: Partial<CapFeed> = {}): CapFeed {
	return {
		url: 'https://example.com/alerts/rss.xml',
		health: 'ok',
		authority: {
			oid: '2.49.0.0.276.0',
			source: 'cap-2.49.0.0.276.0',
			name: 'Deutscher Wetterdienst',
			country_name: 'Germany',
			country_iso3: 'DEU'
		},
		authority_oids: ['2.49.0.0.276.0'],
		language: 'en',
		subscribed: true,
		exclusion_reason: null,
		format: 'rss',
		last_polled_at: '2026-09-19T00:00:00Z',
		last_success_at: '2026-09-19T00:00:00Z',
		last_http_status: 200,
		last_error: null,
		consecutive_failures: 0,
		item_count: 10,
		newest_item_at: '2026-09-19T00:00:00Z',
		active_alerts: 2,
		failed_items: 0,
		...overrides
	};
}

describe('computeHealthCounts', () => {
	it('counts occurrences of each health status', () => {
		const feeds = [
			makeFeed({ health: 'ok' }),
			makeFeed({ health: 'ok' }),
			makeFeed({ health: 'stale' }),
			makeFeed({ health: 'failing' }),
			makeFeed({ health: 'excluded' })
		];

		const counts = computeHealthCounts(feeds);
		expect(counts).toEqual({
			ok: 2,
			empty: 0,
			stale: 1,
			degraded: 0,
			failing: 1,
			pending: 0,
			excluded: 1
		});
	});
});

describe('filterFeeds', () => {
	const feeds = [
		makeFeed({
			url: 'https://dwd.de/rss.xml',
			health: 'ok',
			authority: {
				oid: '1',
				source: 'src1',
				name: 'Deutscher Wetterdienst',
				country_name: 'Germany',
				country_iso3: 'DEU'
			}
		}),
		makeFeed({
			url: 'https://meteofrance.com/cap.xml',
			health: 'failing',
			authority: {
				oid: '2',
				source: 'src2',
				name: 'Meteo France',
				country_name: 'France',
				country_iso3: 'FRA'
			}
		}),
		makeFeed({
			url: 'https://metoffice.gov.uk/warnings.atom',
			health: 'excluded',
			authority: {
				oid: '3',
				source: 'src3',
				name: 'Met Office',
				country_name: 'United Kingdom',
				country_iso3: 'GBR'
			}
		})
	];

	it('filters by active health set', () => {
		const active = new Set<FeedHealth>(['ok', 'failing']);
		const result = filterFeeds(feeds, active, '');
		expect(result).toHaveLength(2);
		expect(result.map((f) => f.authority.name)).toEqual(['Deutscher Wetterdienst', 'Meteo France']);
	});

	it('filters by text search across country, authority, and url', () => {
		const active = new Set<FeedHealth>(['ok', 'failing', 'excluded']);
		expect(filterFeeds(feeds, active, 'France')).toHaveLength(1);
		expect(filterFeeds(feeds, active, 'deu')).toHaveLength(1);
		expect(filterFeeds(feeds, active, 'warnings.atom')).toHaveLength(1);
		expect(filterFeeds(feeds, active, 'office')).toHaveLength(1);
		expect(filterFeeds(feeds, active, 'nonexistent')).toHaveLength(0);
	});
});

describe('sortFeeds', () => {
	const feeds = [
		makeFeed({
			url: 'https://b.com',
			health: 'stale',
			authority: {
				oid: '1',
				source: '1',
				name: 'Beta',
				country_name: 'Brazil',
				country_iso3: 'BRA'
			},
			consecutive_failures: 2,
			active_alerts: 5
		}),
		makeFeed({
			url: 'https://a.com',
			health: 'ok',
			authority: {
				oid: '2',
				source: '2',
				name: 'Alpha',
				country_name: 'Algeria',
				country_iso3: 'DZA'
			},
			consecutive_failures: 0,
			active_alerts: 10
		})
	];

	it('sorts by health', () => {
		const asc = sortFeeds(feeds, 'health', 'asc');
		expect(asc.map((f) => f.health)).toEqual(['ok', 'stale']);

		const desc = sortFeeds(feeds, 'health', 'desc');
		expect(desc.map((f) => f.health)).toEqual(['stale', 'ok']);
	});

	it('sorts by authority name', () => {
		const asc = sortFeeds(feeds, 'authority', 'asc');
		expect(asc.map((f) => f.authority.name)).toEqual(['Alpha', 'Beta']);
	});

	it('sorts by numeric active_alerts', () => {
		const asc = sortFeeds(feeds, 'active_alerts', 'asc');
		expect(asc.map((f) => f.active_alerts)).toEqual([5, 10]);

		const desc = sortFeeds(feeds, 'active_alerts', 'desc');
		expect(desc.map((f) => f.active_alerts)).toEqual([10, 5]);
	});
});

describe('formatFeedDisplayUrl', () => {
	it('extracts host and truncates path when long', () => {
		const result = formatFeedDisplayUrl('https://example.com/alerts/feeds/national/v1/cap.xml');
		expect(result.host).toBe('example.com');
		expect(result.displayPath).toContain('…');
	});

	it('handles short paths without truncation', () => {
		const result = formatFeedDisplayUrl('https://example.com/rss');
		expect(result.host).toBe('example.com');
		expect(result.displayPath).toBe('/rss');
	});
});

describe('isHttpUrl', () => {
	it('accepts valid http and https URLs', () => {
		expect(isHttpUrl('http://example.com')).toBe(true);
		expect(isHttpUrl('https://example.com/cap.xml')).toBe(true);
	});

	it('rejects null, undefined, empty, and non-http URLs', () => {
		expect(isHttpUrl(null)).toBe(false);
		expect(isHttpUrl(undefined)).toBe(false);
		expect(isHttpUrl('')).toBe(false);
		expect(isHttpUrl('javascript:alert(1)')).toBe(false);
		expect(isHttpUrl('ftp://example.com')).toBe(false);
		expect(isHttpUrl('not a url')).toBe(false);
	});
});
