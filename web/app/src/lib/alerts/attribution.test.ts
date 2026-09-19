import { describe, it, expect } from 'vitest';
import { summarizeAlertSources } from './attribution';
import type { Alert } from './types';

function makeAlert(sourceName: string): Alert {
	return {
		id: 'id',
		source: 'src',
		source_id: '1',
		source_name: sourceName,
		attribution: 'attr',
		countries: ['USA'],
		sender: null,
		sender_name: null,
		message_type: 'Alert',
		event: 'Event',
		category: [],
		severity: 'Moderate',
		urgency: 'Immediate',
		certainty: 'Observed',
		headline: null,
		language: null,
		web: null,
		area_desc: 'Area',
		geocodes: [],
		geometry: null,
		sent: null,
		effective: null,
		onset: null,
		expires: null,
		ends: null,
		active_until: '2026-09-19T00:00:00Z',
		first_seen_at: '2026-09-19T00:00:00Z',
		last_seen_at: '2026-09-19T00:00:00Z',
		ended_at: null,
		end_reason: null,
		superseded_by: null
	};
}

describe('summarizeAlertSources', () => {
	it('sorts sources by frequency desc, tie-breaking alphabetically', () => {
		const alerts = [
			makeAlert('NWS'),
			makeAlert('DWD'),
			makeAlert('NWS'),
			makeAlert('Meteo-France'),
			makeAlert('JMA'),
			makeAlert('JMA'),
			makeAlert('DWD')
		];

		const summary = summarizeAlertSources(alerts, 3);
		expect(summary.visible).toEqual([
			{ name: 'DWD', count: 2 },
			{ name: 'JMA', count: 2 },
			{ name: 'NWS', count: 2 }
		]);
		expect(summary.hiddenCount).toBe(1);
		expect(summary.totalUnique).toBe(4);
	});

	it('handles fewer sources than the limit', () => {
		const alerts = [makeAlert('NWS'), makeAlert('DWD')];
		const summary = summarizeAlertSources(alerts, 3);
		expect(summary.visible).toEqual([
			{ name: 'DWD', count: 1 },
			{ name: 'NWS', count: 1 }
		]);
		expect(summary.hiddenCount).toBe(0);
		expect(summary.totalUnique).toBe(2);
	});

	it('handles empty alerts array', () => {
		const summary = summarizeAlertSources([]);
		expect(summary.visible).toEqual([]);
		expect(summary.hiddenCount).toBe(0);
		expect(summary.totalUnique).toBe(0);
	});
});
