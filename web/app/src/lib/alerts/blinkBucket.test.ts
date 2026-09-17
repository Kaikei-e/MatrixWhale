import { describe, expect, it } from 'vitest';
import { bucketFor } from './blinkBucket';
import type { BlinkState, Severity } from './types';

describe('bucketFor', () => {
	const table: Array<{
		name: string;
		state: BlinkState;
		severity: Severity;
		stopAll: boolean;
		reducedMotion: boolean;
		expected: string;
	}> = [
		{
			name: 'arrival blinks Q',
			state: { mode: 'arrival', until: null },
			severity: 'Minor',
			stopAll: false,
			reducedMotion: false,
			expected: 'q'
		},
		{
			name: 'arrival is frozen by stopAll',
			state: { mode: 'arrival', until: null },
			severity: 'Minor',
			stopAll: true,
			reducedMotion: false,
			expected: 'still'
		},
		{
			name: 'arrival is frozen by reducedMotion',
			state: { mode: 'arrival', until: null },
			severity: 'Minor',
			stopAll: false,
			reducedMotion: true,
			expected: 'still'
		},
		{
			name: 'update blinks once',
			state: { mode: 'update', until: null },
			severity: 'Severe',
			stopAll: false,
			reducedMotion: false,
			expected: 'update'
		},
		{
			name: 'update is frozen by stopAll',
			state: { mode: 'update', until: null },
			severity: 'Severe',
			stopAll: true,
			reducedMotion: false,
			expected: 'still'
		},
		{
			name: 'persistent Extreme flashes 2s',
			state: { mode: 'persistent', until: null },
			severity: 'Extreme',
			stopAll: false,
			reducedMotion: false,
			expected: 'fl2'
		},
		{
			name: 'persistent Severe flashes 4s',
			state: { mode: 'persistent', until: null },
			severity: 'Severe',
			stopAll: false,
			reducedMotion: false,
			expected: 'fl4'
		},
		{
			name: 'persistent Extreme is frozen by stopAll',
			state: { mode: 'persistent', until: null },
			severity: 'Extreme',
			stopAll: true,
			reducedMotion: false,
			expected: 'still'
		},
		{
			name: 'persistent Extreme is frozen by reducedMotion',
			state: { mode: 'persistent', until: null },
			severity: 'Extreme',
			stopAll: false,
			reducedMotion: true,
			expected: 'still'
		},
		{
			name: 'persistent Moderate never blinks',
			state: { mode: 'persistent', until: null },
			severity: 'Moderate',
			stopAll: false,
			reducedMotion: false,
			expected: 'none'
		},
		{
			name: 'fading never blinks',
			state: { mode: 'fading', until: null },
			severity: 'Extreme',
			stopAll: false,
			reducedMotion: false,
			expected: 'none'
		},
		{
			name: 'static never blinks',
			state: { mode: 'static', until: null },
			severity: 'Extreme',
			stopAll: false,
			reducedMotion: false,
			expected: 'none'
		}
	];

	for (const { name, state, severity, stopAll, reducedMotion, expected } of table) {
		it(name, () => {
			expect(bucketFor(state, severity, stopAll, reducedMotion)).toBe(expected);
		});
	}

	it('returns none when there is no blink state for the alert', () => {
		expect(bucketFor(undefined, 'Extreme', false, false)).toBe('none');
	});
});
