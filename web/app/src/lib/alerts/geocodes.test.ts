import { describe, it, expect } from 'vitest';
import { extractGeocodes, extractUgc, extractSame } from './geocodes';
import type { Alert } from './types';

function makeAlert(overrides: Partial<Alert> = {}): Alert {
	return {
		id: 'test-1',
		source: 'noaa',
		source_id: 'test-1',
		source_name: 'National Weather Service',
		attribution: 'NWS',
		countries: ['USA'],
		sender: 'test',
		sender_name: 'test',
		message_type: 'Alert',
		event: 'Tornado Warning',
		category: ['Met'],
		severity: 'Extreme',
		urgency: 'Immediate',
		certainty: 'Observed',
		headline: null,
		language: 'en-US',
		web: null,
		area_desc: 'County A',
		geocodes: [],
		geometry: null,
		sent: '2026-09-19T00:00:00Z',
		effective: '2026-09-19T00:00:00Z',
		onset: null,
		expires: '2026-09-19T02:00:00Z',
		ends: null,
		active_until: '2026-09-19T02:00:00Z',
		first_seen_at: '2026-09-19T00:00:00Z',
		last_seen_at: '2026-09-19T00:00:00Z',
		ended_at: null,
		end_reason: null,
		superseded_by: null,
		...overrides
	};
}

describe('extractGeocodes', () => {
	it('extracts matching geocodes case-insensitively', () => {
		const alert = makeAlert({
			geocodes: [
				{ name: 'UGC', value: 'OKZ140' },
				{ name: 'ugc', value: 'OKC143' },
				{ name: 'SAME', value: '040109' }
			]
		});
		expect(extractGeocodes(alert, 'UGC')).toEqual(['OKZ140', 'OKC143']);
		expect(extractUgc(alert)).toEqual(['OKZ140', 'OKC143']);
		expect(extractSame(alert)).toEqual(['040109']);
	});

	it('handles whitespace or comma separated values', () => {
		const alert = makeAlert({
			geocodes: [{ name: 'UGC', value: 'OKZ140 OKC143,OKZ145' }]
		});
		expect(extractUgc(alert)).toEqual(['OKZ140', 'OKC143', 'OKZ145']);
	});

	it('returns empty array when no matching geocodes are present', () => {
		const alert = makeAlert({ geocodes: [] });
		expect(extractUgc(alert)).toEqual([]);
		expect(extractSame(alert)).toEqual([]);
	});
});
