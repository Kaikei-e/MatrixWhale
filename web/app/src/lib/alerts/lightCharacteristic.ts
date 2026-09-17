import type { BlinkState, Severity } from './types';

interface StaticStyle {
	fill: number;
	lineWidth: number;
	dash: 'solid' | 'dashed' | 'dotted';
}

const STATIC_STYLE: Record<Severity, StaticStyle> = {
	Extreme: { fill: 0.55, lineWidth: 2.5, dash: 'solid' },
	Severe: { fill: 0.3, lineWidth: 1.5, dash: 'solid' },
	Moderate: { fill: 0, lineWidth: 1.5, dash: 'solid' },
	Minor: { fill: 0, lineWidth: 1, dash: 'dashed' },
	Unknown: { fill: 0, lineWidth: 1, dash: 'dotted' }
};

interface Timing {
	period: number;
	duty: number;
	label: string;
}

function staticTiming(severity: Severity): Timing {
	return { period: 0, duty: 1, label: severity === 'Moderate' ? 'F' : 'static' };
}

function timingFor(severity: Severity, state: BlinkState): Timing {
	switch (state.mode) {
		case 'arrival':
		case 'update':
			return { period: 1000, duty: 0.3, label: 'Q' };
		case 'persistent':
			if (severity === 'Extreme') return { period: 2000, duty: 0.25, label: 'Fl 2s' };
			if (severity === 'Severe') return { period: 4000, duty: 0.25, label: 'Fl 4s' };
			return staticTiming(severity);
		case 'fading':
			return { period: 0, duty: 1, label: 'ending' };
		case 'static':
			return staticTiming(severity);
	}
}

export interface LightCharacteristic {
	period: number;
	duty: number;
	fill: number;
	lineWidth: number;
	dash: 'solid' | 'dashed' | 'dotted';
	className: string;
	label: string;
}

export function lightCharacteristic(severity: Severity, state: BlinkState): LightCharacteristic {
	const style = STATIC_STYLE[severity];
	const timing = timingFor(severity, state);
	const labelSlug = timing.label.toLowerCase().replace(/\s+/g, '-');

	return {
		period: timing.period,
		duty: timing.duty,
		fill: style.fill,
		lineWidth: style.lineWidth,
		dash: style.dash,
		className: `light-${severity.toLowerCase()}-${labelSlug}`,
		label: timing.label
	};
}
