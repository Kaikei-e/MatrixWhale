export const FEED_HEALTHS = [
	'ok',
	'empty',
	'stale',
	'degraded',
	'failing',
	'pending',
	'excluded'
] as const;

export type FeedHealth = (typeof FEED_HEALTHS)[number];

export interface FeedAuthority {
	oid: string;
	source: string;
	name: string;
	country_name: string;
	country_iso3: string;
}

export interface CapFeed {
	url: string;
	health: FeedHealth;
	authority: FeedAuthority;
	authority_oids: string[];
	language: string | null;
	subscribed: boolean;
	exclusion_reason: string | null;
	format: string | null;
	last_polled_at: string | null;
	last_success_at: string | null;
	last_http_status: number | null;
	last_error: string | null;
	consecutive_failures: number;
	item_count: number | null;
	newest_item_at: string | null;
	active_alerts: number;
	failed_items: number;
}

export interface CapFeedsResponse {
	generated_at: string;
	registry_fetched_at: string | null;
	counts: Record<FeedHealth, number>;
	feeds: CapFeed[];
}

export type FeedSortColumn =
	| 'health'
	| 'country'
	| 'authority'
	| 'url'
	| 'language'
	| 'format'
	| 'last_success'
	| 'failures'
	| 'items'
	| 'newest_item'
	| 'active_alerts';

export type {
	Wis2BrokerHealth,
	Wis2ChannelHealth,
	Wis2ChannelKind,
	Wis2ChannelStatus,
	Wis2HealthResponse,
	Wis2SortColumn
} from './wis2';
