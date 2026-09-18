import { describe, it, expect } from 'vitest';
import {
	compareItems,
	itemFromRecord,
	passesFilters,
	severityForAlert,
	severityForEarthquake,
	severityForHazard,
	severityRank
} from './severity';
import type { TimelineFilters, TimelineItem } from './types';
import type { Earthquake } from '$lib/earthquakes/types';
import type { Hazard } from '$lib/hazards/types';
import type { Alert } from '$lib/alerts/types';

function makeEarthquake(overrides: Partial<Earthquake> = {}): Earthquake {
	const now = new Date().toISOString();
	return {
		id: 1,
		kind: 'earthquake',
		magnitude: 4.2,
		magnitude_type: 'mb',
		occurred_at: now,
		occurred_at_ms: Date.now(),
		updated_at: now,
		updated_at_ms: Date.now(),
		place: 'Test location',
		title: 'M 4.2 - Test location',
		status: 'reviewed',
		event_type: 'earthquake',
		tsunami: 0,
		significance: 271,
		alert: null,
		mmi: null,
		cdi: null,
		felt: null,
		nst: null,
		dmin: null,
		rms: null,
		gap: null,
		net: 'us',
		code: '123',
		url: null,
		detail: null,
		longitude: 139.7,
		latitude: 35.6,
		depth_km: 12,
		preferred_source: 'usgs',
		sources: ['usgs'],
		members: [],
		first_seen_at: now,
		last_seen_at: now,
		...overrides
	};
}

function makeHazard(overrides: Partial<Hazard> = {}): Hazard {
	const now = new Date().toISOString();
	return {
		id: 'gdacs:TC-1000001',
		source: 'gdacs',
		source_id: 'TC-1000001',
		source_type_code: 'TC',
		hazard_type: 'tropical_cyclone',
		hazard_codes: [],
		glide: null,
		alert_level: 'orange',
		alert_score: 1.5,
		cap_severity: 'severe',
		severity_value: 120,
		severity_unit: 'km/h',
		severity_label: 'Wind speed 120 km/h',
		estimate_type: 'primary',
		title: 'Tropical Cyclone Test',
		description: 'Test description',
		countries: ['PHL'],
		report_url: null,
		onset_at: now,
		onset_at_ms: Date.now(),
		expires_at: now,
		expires_at_ms: Date.now(),
		modified_at: now,
		modified_at_ms: Date.now(),
		is_current: true,
		episode_id: 'e1',
		episode_count: 1,
		longitude: 120,
		latitude: 12,
		bbox: [119, 11, 121, 13],
		primary_geometry: null,
		external_ids: [],
		first_seen_at: now,
		last_seen_at: now,
		...overrides
	};
}

function makeAlert(overrides: Partial<Alert> = {}): Alert {
	const now = new Date().toISOString();
	return {
		id: 'urn:oid:test.1',
		event: 'Tornado Warning',
		severity: 'Extreme',
		urgency: 'Immediate',
		certainty: 'Observed',
		message_type: null,
		headline: null,
		area_desc: 'Test Area',
		ugc: [],
		same: [],
		geometry: null,
		sent: now,
		effective: null,
		expires: null,
		ends: null,
		first_seen_at: now,
		last_seen_at: now,
		ended_at: null,
		...overrides
	};
}

function defaultFilters(overrides: Partial<TimelineFilters> = {}): TimelineFilters {
	return {
		kinds: new Set(['earthquake', 'hazard', 'alert']),
		minMagnitude: 2.5,
		minSeverity: 'all',
		...overrides
	};
}

describe('severityRank', () => {
	it('orders unknown < minor < moderate < severe < extreme', () => {
		expect(severityRank('unknown')).toBe(0);
		expect(severityRank('minor')).toBe(1);
		expect(severityRank('moderate')).toBe(2);
		expect(severityRank('severe')).toBe(3);
		expect(severityRank('extreme')).toBe(4);
	});
});

describe('severityForEarthquake', () => {
	it.each([
		[null, 'unknown'],
		[-0.3, 'minor'],
		[4.49, 'minor'],
		[4.5, 'moderate'],
		[5.99, 'moderate'],
		[6.0, 'severe'],
		[6.99, 'severe'],
		[7.0, 'extreme'],
		[9.1, 'extreme']
	] as const)('magnitude %s -> %s', (magnitude, expected) => {
		expect(severityForEarthquake(magnitude)).toBe(expected);
	});
});

describe('severityForHazard', () => {
	it.each([
		['minor', 'minor'],
		['severe', 'severe'],
		['extreme', 'extreme'],
		['garbage', 'unknown']
	] as const)('cap_severity %s -> %s', (capSeverity, expected) => {
		expect(severityForHazard(capSeverity)).toBe(expected);
	});
});

describe('severityForAlert', () => {
	it.each([
		['Extreme', 'extreme'],
		['Severe', 'severe'],
		['Moderate', 'moderate'],
		['Minor', 'minor'],
		['Unknown', 'unknown'],
		['garbage', 'unknown']
	] as const)('NOAA severity %s -> %s', (noaaSeverity, expected) => {
		expect(severityForAlert(noaaSeverity)).toBe(expected);
	});
});

describe('itemFromRecord', () => {
	it('builds an earthquake item keyed by id, never ended', () => {
		const item = itemFromRecord('earthquake', makeEarthquake({ id: 42, magnitude: 6.1 }));
		expect(item).toMatchObject({
			kind: 'earthquake',
			key: 'earthquake:42',
			severity: 'severe',
			ended: false
		});
	});

	it('builds a hazard item keyed by source:source_id and derives ended from is_current', () => {
		const item = itemFromRecord(
			'hazard',
			makeHazard({ is_current: false, cap_severity: 'extreme' })
		);
		expect(item).toMatchObject({
			kind: 'hazard',
			key: 'hazard:gdacs:TC-1000001',
			severity: 'extreme',
			ended: true
		});
	});

	it('builds an alert item keyed by alert id and derives ended from ended_at', () => {
		const item = itemFromRecord(
			'alert',
			makeAlert({ id: 'urn:oid:test.2', severity: 'Moderate', ended_at: '2026-09-18T00:00:00Z' })
		);
		expect(item).toMatchObject({
			kind: 'alert',
			key: 'alert:urn:oid:test.2',
			severity: 'moderate',
			ended: true
		});
	});
});

describe('passesFilters', () => {
	it('excludes a kind that is toggled off', () => {
		const item = itemFromRecord('earthquake', makeEarthquake());
		expect(passesFilters(item, defaultFilters({ kinds: new Set(['hazard', 'alert']) }))).toBe(
			false
		);
	});

	it('excludes a deleted earthquake regardless of magnitude', () => {
		const item = itemFromRecord('earthquake', makeEarthquake({ status: 'deleted', magnitude: 8 }));
		expect(passesFilters(item, defaultFilters())).toBe(false);
	});

	it('applies the magnitude floor to earthquakes only', () => {
		const small = itemFromRecord('earthquake', makeEarthquake({ magnitude: 1 }));
		expect(passesFilters(small, defaultFilters({ minMagnitude: 2.5 }))).toBe(false);
		expect(passesFilters(small, defaultFilters({ minMagnitude: 'all' }))).toBe(true);
	});

	it('excludes a null-magnitude earthquake unless minMagnitude is all', () => {
		const unknown = itemFromRecord('earthquake', makeEarthquake({ magnitude: null }));
		expect(passesFilters(unknown, defaultFilters({ minMagnitude: 2.5 }))).toBe(false);
		expect(passesFilters(unknown, defaultFilters({ minMagnitude: 'all' }))).toBe(true);
	});

	it('always excludes GDACS earthquake hazards', () => {
		const item = itemFromRecord('hazard', makeHazard({ hazard_type: 'earthquake' }));
		expect(passesFilters(item, defaultFilters())).toBe(false);
	});

	it('applies the min-severity floor across kinds', () => {
		const minorHazard = itemFromRecord('hazard', makeHazard({ cap_severity: 'minor' }));
		expect(passesFilters(minorHazard, defaultFilters({ minSeverity: 'moderate' }))).toBe(false);
		const severeHazard = itemFromRecord('hazard', makeHazard({ cap_severity: 'severe' }));
		expect(passesFilters(severeHazard, defaultFilters({ minSeverity: 'moderate' }))).toBe(true);
	});

	it('does not exclude an ended item purely for being ended', () => {
		const item = itemFromRecord('alert', makeAlert({ ended_at: '2026-09-18T00:00:00Z' }));
		expect(passesFilters(item, defaultFilters())).toBe(true);
	});
});

describe('compareItems', () => {
	it('orders newest seen_at first', () => {
		const older = itemFromRecord(
			'earthquake',
			makeEarthquake({ id: 1, first_seen_at: '2026-09-18T00:00:00Z' })
		);
		const newer = itemFromRecord(
			'earthquake',
			makeEarthquake({ id: 2, first_seen_at: '2026-09-18T01:00:00Z' })
		);
		expect([older, newer].sort(compareItems)).toEqual([newer, older]);
	});

	it('breaks a seen_at tie by kind DESC then key DESC', () => {
		const sameTime = '2026-09-18T00:00:00Z';
		const earthquake = itemFromRecord(
			'earthquake',
			makeEarthquake({ id: 1, first_seen_at: sameTime })
		);
		const hazard = itemFromRecord('hazard', makeHazard({ first_seen_at: sameTime }));
		const alert = itemFromRecord('alert', makeAlert({ first_seen_at: sameTime }));
		const items: TimelineItem[] = [alert, earthquake, hazard];

		expect(items.sort(compareItems).map((item) => item.kind)).toEqual([
			'hazard',
			'earthquake',
			'alert'
		]);
	});
});
