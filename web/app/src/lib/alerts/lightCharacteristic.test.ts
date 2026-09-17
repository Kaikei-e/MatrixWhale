import { describe, it, expect } from 'vitest';
import { lightCharacteristic } from './lightCharacteristic';
import { SEVERITIES, type BlinkMode } from './types';

const MODES: BlinkMode[] = ['arrival', 'persistent', 'update', 'fading', 'static'];

const STATIC_STYLE = {
	Extreme: { fill: 0.55, lineWidth: 2.5, dash: 'solid' },
	Severe: { fill: 0.3, lineWidth: 1.5, dash: 'solid' },
	Moderate: { fill: 0, lineWidth: 1.5, dash: 'solid' },
	Minor: { fill: 0, lineWidth: 1, dash: 'dashed' },
	Unknown: { fill: 0, lineWidth: 1, dash: 'dotted' }
} as const;

function expectedTiming(severity: string, mode: BlinkMode) {
	if (mode === 'arrival' || mode === 'update') return { period: 1000, duty: 0.3, label: 'Q' };
	if (mode === 'fading') return { period: 0, duty: 1, label: 'ending' };
	if (mode === 'persistent') {
		if (severity === 'Extreme') return { period: 2000, duty: 0.25, label: 'Fl 2s' };
		if (severity === 'Severe') return { period: 4000, duty: 0.25, label: 'Fl 4s' };
	}
	return { period: 0, duty: 1, label: severity === 'Moderate' ? 'F' : 'static' };
}

describe('lightCharacteristic', () => {
	for (const severity of SEVERITIES) {
		for (const mode of MODES) {
			it(`${severity} / ${mode}`, () => {
				const result = lightCharacteristic(severity, { mode, until: null });
				const timing = expectedTiming(severity, mode);
				const style = STATIC_STYLE[severity];

				expect(result.period).toBe(timing.period);
				expect(result.duty).toBe(timing.duty);
				expect(result.label).toBe(timing.label);
				expect(result.fill).toBe(style.fill);
				expect(result.lineWidth).toBe(style.lineWidth);
				expect(result.dash).toBe(style.dash);
			});
		}
	}
});
