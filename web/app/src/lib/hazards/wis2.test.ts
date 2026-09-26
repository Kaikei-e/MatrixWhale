import { describe, expect, it } from 'vitest';
import {
	encodeHazardDetailPath,
	formatAlertSourceBadge,
	formatLatLon,
	formatMaxWind,
	formatMslp,
	formatMslpWithUnit,
	formatObservedExtremeSubtype,
	formatTrackLeadLabel,
	formatWindRadiiSummary,
	is24HourStep,
	matchesObservedExtremeFilter,
	observedExtremeColor
} from './wis2';
import type { Hazard } from './types';

function createMockHazard(overrides: Partial<Hazard> = {}): Hazard {
	const now = Date.now();
	return {
		id: 'gdacs:TC-1000001',
		source: 'gdacs',
		source_id: 'TC-1000001',
		source_type_code: 'TC',
		hazard_type: 'tropical_cyclone',
		hazard_codes: ['glide:TC'],
		glide: null,
		alert_level: 'orange',
		alert_score: 1.5,
		cap_severity: 'severe',
		severity_value: 120,
		severity_unit: 'km/h',
		severity_label: 'Wind speed 120 km/h',
		estimate_type: 'primary',
		title: 'Tropical Cyclone Test',
		description: 'Tropical cyclone test description',
		countries: ['PHL'],
		report_url: 'https://www.gdacs.org/report.aspx?eventid=1000001',
		onset_at: new Date(now).toISOString(),
		onset_at_ms: now,
		expires_at: new Date(now).toISOString(),
		expires_at_ms: now,
		modified_at: new Date(now).toISOString(),
		modified_at_ms: now,
		is_current: true,
		episode_id: '1',
		episode_count: 1,
		longitude: 120.5,
		latitude: 14.5,
		bbox: [120.5, 14.5, 120.5, 14.5],
		primary_geometry: null,
		external_ids: [],
		first_seen_at: new Date(now).toISOString(),
		last_seen_at: new Date(now).toISOString(),
		...overrides
	};
}

describe('WIS2 Hazard Helpers', () => {
	describe('encodeHazardDetailPath', () => {
		it('encodes simple source and source_id without slashes', () => {
			expect(encodeHazardDetailPath('gdacs', 'TC-1000001')).toBe(
				'/api/v1/hazards/gdacs/TC-1000001'
			);
		});

		it('encodes source IDs with slashes by encoding each segment separately', () => {
			// Slashes are preserved as URL path separators while segments are encoded
			expect(encodeHazardDetailPath('wis2-ecmwf', '06L/2026')).toBe(
				'/api/v1/hazards/wis2-ecmwf/06L/2026'
			);
		});

		it('encodes special characters in source and individual segments', () => {
			expect(encodeHazardDetailPath('source name', 'storm #1/part 2')).toBe(
				'/api/v1/hazards/source%20name/storm%20%231/part%202'
			);
		});
	});

	describe('formatTrackLeadLabel', () => {
		it('formats lead hours with + and h suffix', () => {
			expect(formatTrackLeadLabel(0)).toBe('+0h');
			expect(formatTrackLeadLabel(12)).toBe('+12h');
			expect(formatTrackLeadLabel(24)).toBe('+24h');
			expect(formatTrackLeadLabel(120)).toBe('+120h');
		});
	});

	describe('is24HourStep', () => {
		it('returns true only for positive multiples of 24', () => {
			expect(is24HourStep(0)).toBe(false);
			expect(is24HourStep(6)).toBe(false);
			expect(is24HourStep(12)).toBe(false);
			expect(is24HourStep(24)).toBe(true);
			expect(is24HourStep(36)).toBe(false);
			expect(is24HourStep(48)).toBe(true);
			expect(is24HourStep(72)).toBe(true);
			expect(is24HourStep(-24)).toBe(false);
		});
	});

	describe('matchesObservedExtremeFilter', () => {
		const allSubtypes = new Set(['wind', 'gust', 'rain_1h', 'rain_24h', 'low_pressure']);

		it('always returns true for non-observed-extreme hazards', () => {
			const cyclone = createMockHazard({ hazard_type: 'tropical_cyclone' });
			expect(matchesObservedExtremeFilter(cyclone, new Set(), true)).toBe(true);
			expect(matchesObservedExtremeFilter(cyclone, new Set(), false)).toBe(true);
		});

		it('filters observed extremes by active subtypes', () => {
			const gustHazard = createMockHazard({
				hazard_type: 'observed_extreme',
				subtype: 'gust',
				confirmed: true
			});
			const rainHazard = createMockHazard({
				hazard_type: 'observed_extreme',
				subtype: 'rain_1h',
				confirmed: true
			});

			const onlyGust = new Set(['gust']);
			expect(matchesObservedExtremeFilter(gustHazard, onlyGust, false)).toBe(true);
			expect(matchesObservedExtremeFilter(rainHazard, onlyGust, false)).toBe(false);
		});

		it('respects hideUnconfirmed for unconfirmed observed extremes', () => {
			const unconfirmed = createMockHazard({
				hazard_type: 'observed_extreme',
				subtype: 'wind',
				confirmed: false
			});
			const confirmed = createMockHazard({
				hazard_type: 'observed_extreme',
				subtype: 'wind',
				confirmed: true
			});

			// When hideUnconfirmed is false, both pass
			expect(matchesObservedExtremeFilter(unconfirmed, allSubtypes, false)).toBe(true);
			expect(matchesObservedExtremeFilter(confirmed, allSubtypes, false)).toBe(true);

			// When hideUnconfirmed is true, unconfirmed is filtered out
			expect(matchesObservedExtremeFilter(unconfirmed, allSubtypes, true)).toBe(false);
			expect(matchesObservedExtremeFilter(confirmed, allSubtypes, true)).toBe(true);
		});
	});

	describe('formatLatLon', () => {
		it('returns em dash for null or NaN coordinates', () => {
			expect(formatLatLon(null, null)).toBe('—');
			expect(formatLatLon(14.5, null)).toBe('—');
			expect(formatLatLon(NaN, 120.5)).toBe('—');
		});

		it('formats lat/lon with 1 decimal and N/S/E/W suffixes without degree clutter', () => {
			expect(formatLatLon(17.1, -108.8)).toBe('17.1N 108.8W');
			expect(formatLatLon(14.5, 120.5)).toBe('14.5N 120.5E');
			expect(formatLatLon(-14.52, -120.58)).toBe('14.5S 120.6W');
			expect(formatLatLon(0, 0)).toBe('0.0N 0.0E');
		});
	});

	describe('formatMslp', () => {
		it('returns em dash for null', () => {
			expect(formatMslp(null)).toBe('—');
		});

		it('converts Pa to integer hPa', () => {
			expect(formatMslp(101325)).toBe('1013');
			expect(formatMslp(98500)).toBe('985');
			expect(formatMslp(95040)).toBe('950');
		});
	});

	describe('formatMslpWithUnit', () => {
		it('returns em dash for null', () => {
			expect(formatMslpWithUnit(null)).toBe('—');
		});

		it('converts Pa to hPa string with unit', () => {
			expect(formatMslpWithUnit(101325)).toBe('1013 hPa');
			expect(formatMslpWithUnit(98500)).toBe('985 hPa');
		});
	});

	describe('formatMaxWind', () => {
		it('returns em dash for null', () => {
			expect(formatMaxWind(null)).toBe('—');
		});

		it('formats max wind as integer m/s', () => {
			expect(formatMaxWind(32.44)).toBe('32 m/s');
			expect(formatMaxWind(45)).toBe('45 m/s');
			expect(formatMaxWind(28.5)).toBe('29 m/s');
		});
	});

	describe('formatWindRadiiSummary', () => {
		it('returns em dash for empty or missing radii', () => {
			expect(formatWindRadiiSummary([])).toBe('—');
		});

		it('formats summary for 18, 26, 33 m/s thresholds in km (numbers only, km)', () => {
			const summary = formatWindRadiiSummary([
				{
					threshold_ms: 18,
					radii_m: [240000, 200000, 180000, 220000]
				},
				{
					threshold_ms: 26,
					radii_m: [150000, 120000, 110000, 140000]
				},
				{
					threshold_ms: 33,
					radii_m: [80000, 70000, 60000, 75000]
				}
			]);
			expect(summary).toBe('18: 240 · 26: 150 · 33: 80 km');
		});

		it('skips thresholds with all zero or null radii', () => {
			const summary = formatWindRadiiSummary([
				{
					threshold_ms: 18,
					radii_m: [100000, 90000, 80000, 95000]
				},
				{
					threshold_ms: 26,
					radii_m: [0, 0, 0, 0]
				}
			]);
			expect(summary).toBe('18: 100 km');
		});
	});

	describe('formatAlertSourceBadge', () => {
		it('formats wis2-<centre_id> as WIS2 · <centre_id>', () => {
			expect(formatAlertSourceBadge('wis2-eu-eumetnet-warnings')).toBe(
				'WIS2 · eu-eumetnet-warnings'
			);
			expect(formatAlertSourceBadge('wis2-in-imd')).toBe('WIS2 · in-imd');
		});

		it('falls back to sourceName or source for non-wis2 sources', () => {
			expect(formatAlertSourceBadge('noaa', 'National Weather Service')).toBe(
				'National Weather Service'
			);
			expect(formatAlertSourceBadge('cap-oid', null)).toBe('cap-oid');
		});
	});

	describe('observedExtremeColor and formatObservedExtremeSubtype', () => {
		it('returns correct color per subtype', () => {
			expect(observedExtremeColor('wind')).toBe('#00bcd4');
			expect(observedExtremeColor('gust')).toBe('#ff9800');
			expect(observedExtremeColor('rain_1h')).toBe('#2196f3');
			expect(observedExtremeColor('rain_24h')).toBe('#3f51b5');
			expect(observedExtremeColor('low_pressure')).toBe('#9c27b0');
			expect(observedExtremeColor(null)).toBe('#607d8b');
		});

		it('formats human readable subtype labels', () => {
			expect(formatObservedExtremeSubtype('wind')).toBe('Wind');
			expect(formatObservedExtremeSubtype('gust')).toBe('Wind Gust');
			expect(formatObservedExtremeSubtype('rain_1h')).toBe('Rain 1h');
			expect(formatObservedExtremeSubtype('rain_24h')).toBe('Rain 24h');
			expect(formatObservedExtremeSubtype('low_pressure')).toBe('Low Pressure');
			expect(formatObservedExtremeSubtype(null)).toBe('Observed Extreme');
		});
	});
});
