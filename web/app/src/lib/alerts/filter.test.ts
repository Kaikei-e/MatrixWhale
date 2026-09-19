import { describe, it, expect } from 'vitest';
import { filterAlerts } from './filter';
import type { Alert, Severity } from './types';

function makeAlert(severity: Severity, countries: string[]): Alert {
	return {
		id: 'id',
		source: 'src',
		source_id: '1',
		source_name: 'Authority',
		attribution: 'attr',
		countries,
		sender: null,
		sender_name: null,
		message_type: 'Alert',
		event: 'Event',
		category: [],
		severity,
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

describe('filterAlerts', () => {
	it('filters by severity set', () => {
		const alerts = [
			makeAlert('Extreme', ['USA']),
			makeAlert('Severe', ['USA']),
			makeAlert('Moderate', ['DEU']),
			makeAlert('Minor', ['FRA']),
			makeAlert('Unknown', ['JPN'])
		];

		const activeSeverities = new Set<Severity>(['Extreme', 'Severe', 'Moderate']);
		const filtered = filterAlerts(alerts, activeSeverities, 'all');

		expect(filtered.map((a) => a.severity)).toEqual(['Extreme', 'Severe', 'Moderate']);
	});

	it('filters by country when specified', () => {
		const alerts = [
			makeAlert('Extreme', ['USA']),
			makeAlert('Severe', ['DEU']),
			makeAlert('Moderate', ['USA', 'CAN'])
		];

		const activeSeverities = new Set<Severity>(['Extreme', 'Severe', 'Moderate']);
		expect(filterAlerts(alerts, activeSeverities, 'USA')).toHaveLength(2);
		expect(filterAlerts(alerts, activeSeverities, 'DEU')).toHaveLength(1);
		expect(filterAlerts(alerts, activeSeverities, 'FRA')).toHaveLength(0);
	});
});
