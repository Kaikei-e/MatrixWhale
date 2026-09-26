export type Wis2ChannelStatus = 'ok' | 'stale' | 'failing';
export type Wis2ChannelKind = 'warnings' | 'trajectory' | 'synop';

export interface Wis2BrokerHealth {
	url: string;
	connected: boolean;
	last_report_at: string | null;
	error: string | null;
}

export interface Wis2ChannelHealth {
	centre_id: string;
	kind: Wis2ChannelKind | string;
	received_24h: number;
	duplicates_24h: number;
	download_failed_24h: number;
	decode_failed_24h: number;
	integrity_failed_24h: number;
	last_received_at: string | null;
	status: Wis2ChannelStatus;
}

export interface Wis2HealthResponse {
	broker: Wis2BrokerHealth;
	channels: Wis2ChannelHealth[];
}

/** Computes the primary unique message count: received minus duplicates (floored at 0). */
export function computeUnique24h(received_24h: number, duplicates_24h: number): number {
	return Math.max(0, received_24h - duplicates_24h);
}

/** Computes the combined count of all failure types over 24h. */
export function computeTotalFailures(
	download_failed_24h: number,
	decode_failed_24h: number,
	integrity_failed_24h: number
): number {
	return download_failed_24h + decode_failed_24h + integrity_failed_24h;
}

export type Wis2SortColumn =
	| 'centre_id'
	| 'kind'
	| 'unique_24h'
	| 'duplicates_24h'
	| 'failures'
	| 'last_received_at'
	| 'status';

export function sortWis2Channels(
	channels: Wis2ChannelHealth[],
	col: Wis2SortColumn,
	dir: 'asc' | 'desc'
): Wis2ChannelHealth[] {
	const mult = dir === 'asc' ? 1 : -1;
	return [...channels].sort((a, b) => {
		switch (col) {
			case 'centre_id':
				return mult * a.centre_id.localeCompare(b.centre_id);
			case 'kind':
				return mult * a.kind.localeCompare(b.kind);
			case 'unique_24h': {
				const uA = computeUnique24h(a.received_24h, a.duplicates_24h);
				const uB = computeUnique24h(b.received_24h, b.duplicates_24h);
				return mult * (uA - uB);
			}
			case 'duplicates_24h':
				return mult * (a.duplicates_24h - b.duplicates_24h);
			case 'failures': {
				const fA = computeTotalFailures(
					a.download_failed_24h,
					a.decode_failed_24h,
					a.integrity_failed_24h
				);
				const fB = computeTotalFailures(
					b.download_failed_24h,
					b.decode_failed_24h,
					b.integrity_failed_24h
				);
				return mult * (fA - fB);
			}
			case 'last_received_at': {
				const tA = a.last_received_at ? new Date(a.last_received_at).getTime() : 0;
				const tB = b.last_received_at ? new Date(b.last_received_at).getTime() : 0;
				return mult * (tA - tB);
			}
			case 'status':
				return mult * a.status.localeCompare(b.status);
			default:
				return 0;
		}
	});
}
