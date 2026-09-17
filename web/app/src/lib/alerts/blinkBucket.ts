import type { BlinkState, Severity } from './types';

// Ordered most urgent first; used both as the bucket's identity and to rank
// which alert "wins" when several alerts cover the same zone.
export const BLINK_BUCKETS = ['q', 'update', 'fl2', 'fl4', 'still', 'none'] as const;

export type BlinkBucket = (typeof BLINK_BUCKETS)[number];

export function bucketFor(
	state: BlinkState | undefined,
	severity: Severity,
	stopAll: boolean,
	reducedMotion: boolean
): BlinkBucket {
	if (!state) return 'none';
	const frozen = stopAll || reducedMotion;

	switch (state.mode) {
		case 'arrival':
			return frozen ? 'still' : 'q';
		case 'update':
			return frozen ? 'still' : 'update';
		case 'persistent':
			if (frozen) return 'still';
			if (severity === 'Extreme') return 'fl2';
			if (severity === 'Severe') return 'fl4';
			return 'none';
		case 'fading':
		case 'static':
			return 'none';
	}
}

export function bucketRank(bucket: BlinkBucket): number {
	return BLINK_BUCKETS.indexOf(bucket);
}
