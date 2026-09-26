import { describe, it, expect } from 'vitest';
import { formatCompactDateTime, formatLocalDateTime, formatLocalHour } from './timeFormat';

const INSTANT = '2026-09-17T17:49:00Z';

describe('formatLocalDateTime', () => {
	it('renders an English, non-locale-dependent timestamp', () => {
		expect(formatLocalDateTime(INSTANT, 'UTC')).toBe('Sep 17, 2026, 5:49 PM');
	});
});

describe('formatLocalHour', () => {
	it('renders an English hour-only label', () => {
		expect(formatLocalHour(INSTANT, 'UTC')).toBe('5 PM');
	});

	it('renders AM for morning hours', () => {
		expect(formatLocalHour('2026-09-17T09:00:00Z', 'UTC')).toBe('9 AM');
	});
});

describe('formatCompactDateTime', () => {
	it('formats compact day and 24h time "DD HH:mm"', () => {
		expect(formatCompactDateTime('2026-09-26T03:00:00Z', 'UTC')).toBe('26 03:00');
		expect(formatCompactDateTime('2026-09-26T15:45:00Z', 'UTC')).toBe('26 15:45');
		expect(formatCompactDateTime('2026-09-05T09:05:00Z', 'UTC')).toBe('05 09:05');
	});

	it('returns em dash for invalid dates', () => {
		expect(formatCompactDateTime('invalid')).toBe('—');
	});
});
