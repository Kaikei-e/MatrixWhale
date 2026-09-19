import type { Alert, BlinkState, Severity } from '$lib/alerts/types';
import type { BlinkBucket } from '$lib/alerts/blinkBucket';
import { bucketFor, bucketRank } from '$lib/alerts/blinkBucket';
import { NWS_EVENT_COLORS, DEFAULT_NWS_COLOR } from '$lib/alerts/nwsEventStyle';
import { extractUgc } from '$lib/alerts/geocodes';

export interface ZoneState {
	[key: string]: unknown;
	severity: Severity;
	blinkBucket: BlinkBucket;
	nwsColor: string;
}

export interface ZoneEntry {
	ugc: string;
	state: ZoneState;
}

export function createZoneStateCache() {
	let stateCache = new Map<string, ZoneState>();

	return function getZoneEntries(
		filteredAlerts: Alert[],
		zoneSeverity: Map<string, Severity>,
		blinkMap: { get(id: string): BlinkState | undefined },
		stopAll: boolean,
		reducedMotion: boolean
	): ZoneEntry[] {
		const extras = new Map<string, { blinkBucket: BlinkBucket; nwsColor: string }>();
		for (const alert of filteredAlerts) {
			const bucket = bucketFor(blinkMap.get(alert.id), alert.severity, stopAll, reducedMotion);
			const color = NWS_EVENT_COLORS[alert.event] ?? DEFAULT_NWS_COLOR;
			for (const ugc of extractUgc(alert)) {
				const existing = extras.get(ugc);
				if (!existing) {
					extras.set(ugc, { blinkBucket: bucket, nwsColor: color });
				} else if (bucketRank(bucket) < bucketRank(existing.blinkBucket)) {
					extras.set(ugc, { blinkBucket: bucket, nwsColor: existing.nwsColor });
				}
			}
		}

		const nextCache = new Map<string, ZoneState>();
		const entries: ZoneEntry[] = [];

		for (const [ugc, severity] of zoneSeverity.entries()) {
			const blinkBucket = extras.get(ugc)?.blinkBucket ?? 'none';
			const nwsColor = extras.get(ugc)?.nwsColor ?? DEFAULT_NWS_COLOR;
			const cached = stateCache.get(ugc);
			let state: ZoneState;
			if (
				cached &&
				cached.severity === severity &&
				cached.blinkBucket === blinkBucket &&
				cached.nwsColor === nwsColor
			) {
				state = cached;
			} else {
				state = {
					severity,
					blinkBucket,
					nwsColor
				};
			}

			nextCache.set(ugc, state);
			entries.push({ ugc, state });
		}

		stateCache = nextCache;
		return entries;
	};
}
