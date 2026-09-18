import { describe, it, expect } from 'vitest';
import {
	formatShortRelativeTime,
	formatBadgeCount,
	magnitudeLabel,
	earthquakeSeverity,
	alertSeverityLevel,
	levelLetter,
	levelDotColor
} from './format';

describe('formatShortRelativeTime', () => {
	const now = Date.parse('2026-09-18T12:00:00Z');

	it('shows "now" for under a minute', () => {
		expect(formatShortRelativeTime('2026-09-18T11:59:40Z', now)).toBe('now');
	});

	it('shows compact minutes', () => {
		expect(formatShortRelativeTime('2026-09-18T11:45:00Z', now)).toBe('15m');
	});

	it('shows compact hours', () => {
		expect(formatShortRelativeTime('2026-09-18T10:00:00Z', now)).toBe('2h');
	});

	it('shows compact days', () => {
		expect(formatShortRelativeTime('2026-09-15T12:00:00Z', now)).toBe('3d');
	});

	it('clamps a future/invalid delta to "now" instead of going negative', () => {
		expect(formatShortRelativeTime('2026-09-18T12:05:00Z', now)).toBe('now');
	});
});

describe('formatBadgeCount', () => {
	it('renders small counts as-is', () => {
		expect(formatBadgeCount(0)).toBe('0');
		expect(formatBadgeCount(42)).toBe('42');
		expect(formatBadgeCount(999)).toBe('999');
	});

	it('caps counts over 999 at "999+"', () => {
		expect(formatBadgeCount(1000)).toBe('999+');
		expect(formatBadgeCount(50000)).toBe('999+');
	});
});

describe('magnitudeLabel', () => {
	it('formats a known magnitude to one decimal with an M prefix', () => {
		expect(magnitudeLabel(6.5)).toBe('M6.5');
		expect(magnitudeLabel(3)).toBe('M3.0');
	});

	it('falls back to an em dash for a null magnitude', () => {
		expect(magnitudeLabel(null)).toBe('M—');
	});
});

describe('earthquakeSeverity', () => {
	it('buckets by magnitude threshold', () => {
		expect(earthquakeSeverity(null)).toBe('green');
		expect(earthquakeSeverity(2.5)).toBe('green');
		expect(earthquakeSeverity(4.4)).toBe('green');
		expect(earthquakeSeverity(4.5)).toBe('orange');
		expect(earthquakeSeverity(5.9)).toBe('orange');
		expect(earthquakeSeverity(6)).toBe('red');
		expect(earthquakeSeverity(7.8)).toBe('red');
	});
});

describe('alertSeverityLevel', () => {
	it('maps NWS severities onto the three-tier scale', () => {
		expect(alertSeverityLevel('Extreme')).toBe('red');
		expect(alertSeverityLevel('Severe')).toBe('red');
		expect(alertSeverityLevel('Moderate')).toBe('orange');
		expect(alertSeverityLevel('Minor')).toBe('green');
		expect(alertSeverityLevel('Unknown')).toBe('green');
	});
});

describe('levelLetter', () => {
	it('returns the capitalised first letter of the level', () => {
		expect(levelLetter('green')).toBe('G');
		expect(levelLetter('orange')).toBe('O');
		expect(levelLetter('red')).toBe('R');
	});
});

describe('levelDotColor', () => {
	it('darkens orange for the day theme to clear 3:1 against --paper', () => {
		expect(levelDotColor('orange', 'day')).not.toBe(levelDotColor('orange', 'night'));
	});

	it('keeps green and red stable across themes', () => {
		expect(levelDotColor('green', 'day')).toBe(levelDotColor('green', 'night'));
		expect(levelDotColor('red', 'day')).toBe(levelDotColor('red', 'night'));
	});
});
