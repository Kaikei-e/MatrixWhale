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

// Light rhythms drawn by the pulse layers. 'still' is the frozen look
// (stop toggle / reduced motion): lit at a constant brightness, never animated.
export const RHYTHMS = {
	q: { buckets: ['q', 'update'], period: 1000, duty: 300 },
	fl2: { buckets: ['fl2'], period: 2000, duty: 500 },
	fl4: { buckets: ['fl4'], period: 4000, duty: 1000 }
} as const satisfies Record<
	string,
	{ buckets: readonly BlinkBucket[]; period: number; duty: number }
>;

export type Rhythm = keyof typeof RHYTHMS;

export const RHYTHM_KEYS = Object.keys(RHYTHMS) as Rhythm[];

export const PULSE_OPACITY = { lit: 1, dim: 0.12, still: 0.6 } as const;

export function rhythmLit(rhythm: Rhythm, now: number): boolean {
	const { period, duty } = RHYTHMS[rhythm];
	return now % period < duty;
}
