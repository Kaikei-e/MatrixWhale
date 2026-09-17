import type { BlinkState, Severity } from './types';

// Ordered most urgent first; used both as the bucket's identity and to rank
// which alert "wins" when several alerts cover the same zone. 'group' is
// earthquake-only (never assigned to an alert) so its rank position doesn't
// affect zone-ranking.
export const BLINK_BUCKETS = ['q', 'update', 'fl2', 'fl4', 'group', 'still', 'none'] as const;

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
// All features in a rhythm share one phase, so the WCAG 2.3.1 flash-rate limit
// (https://www.w3.org/WAI/WCAG21/Understanding/three-flashes-or-below-threshold.html)
// applies to the summed flash rate across rhythms, not any one rhythm alone.
// 'group' is the earthquake M>=6 rhythm: two flashes (each `duty` wide, the
// second starting at `second`) per period; alerts never use this bucket.
export const RHYTHMS = {
	q: { buckets: ['q', 'update'], period: 1000, duty: 300 },
	fl2: { buckets: ['fl2'], period: 2000, duty: 500 },
	fl4: { buckets: ['fl4'], period: 4000, duty: 1000 },
	group: { buckets: ['group'], period: 2500, duty: 225, second: 450 }
} as const satisfies Record<
	string,
	{ buckets: readonly BlinkBucket[]; period: number; duty: number; second?: number }
>;

export type Rhythm = keyof typeof RHYTHMS;

export const RHYTHM_KEYS = Object.keys(RHYTHMS) as Rhythm[];

export const PULSE_OPACITY = { lit: 1, dim: 0.12, still: 0.6 } as const;

export function rhythmLit(rhythm: Rhythm, now: number): boolean {
	const spec = RHYTHMS[rhythm];
	const t = now % spec.period;
	if (t < spec.duty) return true;
	if (!('second' in spec)) return false;
	return t >= spec.second && t < spec.second + spec.duty;
}

// Flashes per second for one rhythm; a rhythm with a `second` window flashes
// twice per period instead of once.
export function rhythmFlashRate(rhythm: Rhythm): number {
	const spec = RHYTHMS[rhythm];
	const flashesPerPeriod = 'second' in spec ? 2 : 1;
	return (flashesPerPeriod * 1000) / spec.period;
}

export function flashesPerSecond(): number {
	return RHYTHM_KEYS.reduce((sum, rhythm) => sum + rhythmFlashRate(rhythm), 0);
}
