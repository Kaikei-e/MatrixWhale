import { type CapFeed, type FeedHealth, type FeedSortColumn } from './types';

export function computeHealthCounts(feeds: CapFeed[]): Record<FeedHealth, number> {
	const counts = {
		ok: 0,
		empty: 0,
		stale: 0,
		degraded: 0,
		failing: 0,
		pending: 0,
		excluded: 0
	} as Record<FeedHealth, number>;

	for (const feed of feeds) {
		if (feed.health in counts) {
			counts[feed.health]++;
		}
	}
	return counts;
}

export function filterFeeds(
	feeds: CapFeed[],
	activeHealth: Set<FeedHealth>,
	searchQuery: string
): CapFeed[] {
	const query = searchQuery.trim().toLowerCase();

	return feeds.filter((feed) => {
		if (!activeHealth.has(feed.health)) return false;
		if (!query) return true;

		const countryMatch =
			feed.authority.country_name.toLowerCase().includes(query) ||
			feed.authority.country_iso3.toLowerCase().includes(query);
		const authorityMatch = feed.authority.name.toLowerCase().includes(query);
		const urlMatch = feed.url.toLowerCase().includes(query);

		return countryMatch || authorityMatch || urlMatch;
	});
}

const HEALTH_ORDER: Record<FeedHealth, number> = {
	ok: 1,
	empty: 2,
	stale: 3,
	degraded: 4,
	failing: 5,
	pending: 6,
	excluded: 7
};

export function sortFeeds(
	feeds: CapFeed[],
	column: FeedSortColumn,
	direction: 'asc' | 'desc'
): CapFeed[] {
	const modifier = direction === 'asc' ? 1 : -1;

	return [...feeds].sort((a, b) => {
		let cmp = 0;
		switch (column) {
			case 'health':
				cmp = (HEALTH_ORDER[a.health] ?? 99) - (HEALTH_ORDER[b.health] ?? 99);
				break;
			case 'country':
				cmp = a.authority.country_name.localeCompare(b.authority.country_name);
				break;
			case 'authority':
				cmp = a.authority.name.localeCompare(b.authority.name);
				break;
			case 'url':
				cmp = a.url.localeCompare(b.url);
				break;
			case 'language':
				cmp = (a.language ?? '').localeCompare(b.language ?? '');
				break;
			case 'format':
				cmp = (a.format ?? '').localeCompare(b.format ?? '');
				break;
			case 'last_success':
				cmp = (a.last_success_at ?? '').localeCompare(b.last_success_at ?? '');
				break;
			case 'failures':
				cmp = a.consecutive_failures - b.consecutive_failures;
				break;
			case 'items':
				cmp = (a.item_count ?? -1) - (b.item_count ?? -1);
				break;
			case 'newest_item':
				cmp = (a.newest_item_at ?? '').localeCompare(b.newest_item_at ?? '');
				break;
			case 'active_alerts':
				cmp = a.active_alerts - b.active_alerts;
				break;
		}

		if (cmp !== 0) return cmp * modifier;
		return a.url.localeCompare(b.url);
	});
}

export function formatFeedDisplayUrl(url: string): { host: string; displayPath: string } {
	try {
		const parsed = new URL(url);
		const host = parsed.host;
		let path = parsed.pathname + parsed.search;
		if (path.length > 20) {
			path = path.slice(0, 10) + '…' + path.slice(-7);
		}
		return { host, displayPath: path };
	} catch {
		if (url.length > 30) {
			return { host: url.slice(0, 20) + '…', displayPath: '' };
		}
		return { host: url, displayPath: '' };
	}
}

export function isHttpUrl(url: string | null | undefined): boolean {
	if (!url) return false;
	try {
		const parsed = new URL(url);
		return parsed.protocol === 'http:' || parsed.protocol === 'https:';
	} catch {
		return false;
	}
}
