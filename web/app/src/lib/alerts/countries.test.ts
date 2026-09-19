import { describe, it, expect } from 'vitest';
import { getCountryName, activeCountriesWithCounts } from './countries';
import type { Alert } from './types';

function makeAlert(countries: string[]): Alert {
	return {
		id: 'a1',
		source: 'test',
		source_id: '1',
		source_name: 'Test Authority',
		attribution: 'Attribution',
		countries,
		sender: null,
		sender_name: null,
		message_type: 'Alert',
		event: 'Test Event',
		category: [],
		severity: 'Moderate',
		urgency: 'Immediate',
		certainty: 'Observed',
		headline: null,
		language: null,
		web: null,
		area_desc: 'Test Area',
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

describe('getCountryName', () => {
	it('converts common ISO3 to readable English country names', () => {
		expect(getCountryName('USA')).toBe('United States');
		expect(getCountryName('DEU')).toBe('Germany');
		expect(getCountryName('FRA')).toBe('France');
		expect(getCountryName('JPN')).toBe('Japan');
		expect(getCountryName('GBR')).toBe('United Kingdom');
	});

	it('falls back to ISO3 if unmapped', () => {
		expect(getCountryName('XYZ')).toBe('XYZ');
		expect(getCountryName('')).toBe('');
	});
});

describe('activeCountriesWithCounts', () => {
	it('computes counts and sorts alphabetically by name', () => {
		const alerts = [makeAlert(['USA']), makeAlert(['DEU']), makeAlert(['USA']), makeAlert(['FRA'])];

		const result = activeCountriesWithCounts(alerts);
		expect(result).toEqual([
			{ iso3: 'FRA', name: 'France', count: 1 },
			{ iso3: 'DEU', name: 'Germany', count: 1 },
			{ iso3: 'USA', name: 'United States', count: 2 }
		]);
	});

	it('handles empty or missing country arrays', () => {
		const alerts = [makeAlert([])];
		expect(activeCountriesWithCounts(alerts)).toEqual([]);
	});
});
