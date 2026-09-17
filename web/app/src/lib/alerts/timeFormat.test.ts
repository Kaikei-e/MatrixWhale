import { describe, it, expect } from 'vitest';
import { formatLocalDateTime, formatLocalHour } from './timeFormat';

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
