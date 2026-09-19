import { describe, it, expect } from 'vitest';
import { alertPoints, alertCentroid } from './alertPoints';
import type { Alert } from '$lib/alerts/types';

function baseAlert(overrides: Partial<Alert>): Alert {
	return {
		id: 'test-id',
		source: 'noaa',
		source_id: 'test-id',
		source_name: 'National Weather Service',
		attribution: 'NWS',
		countries: ['USA'],
		sender: null,
		sender_name: null,
		message_type: null,
		event: 'Test Event',
		category: [],
		severity: 'Moderate',
		urgency: 'Expected',
		certainty: 'Likely',
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
		active_until: '2026-09-17T00:00:00Z',
		first_seen_at: '2026-09-17T00:00:00Z',
		last_seen_at: '2026-09-17T00:00:00Z',
		ended_at: null,
		end_reason: null,
		superseded_by: null,
		...overrides
	};
}

describe('alertPoints', () => {
	it('returns the bbox centroid of a Polygon outer ring', () => {
		const alert = baseAlert({
			geometry: {
				type: 'Polygon',
				coordinates: [
					[
						[-100, 30],
						[-98, 30],
						[-98, 32],
						[-100, 32],
						[-100, 30]
					]
				]
			}
		});

		expect(alertPoints(alert, {})).toEqual([[-99, 31]]);
	});

	it('returns one centroid per polygon of a MultiPolygon', () => {
		const alert = baseAlert({
			geometry: {
				type: 'MultiPolygon',
				coordinates: [
					[
						[
							[-100, 30],
							[-98, 30],
							[-98, 32],
							[-100, 32],
							[-100, 30]
						]
					],
					[
						[
							[10, 10],
							[12, 10],
							[12, 12],
							[10, 12],
							[10, 10]
						]
					]
				]
			}
		});

		expect(alertPoints(alert, {})).toEqual([
			[-99, 31],
			[11, 11]
		]);
	});

	it('falls back to UGC centroids when there is no geometry', () => {
		const alert = baseAlert({
			geocodes: [
				{ name: 'UGC', value: 'OKC143' },
				{ name: 'UGC', value: 'OKC145' }
			]
		});
		const centroids = { OKC143: [-97.5, 35.5] as [number, number] };

		expect(alertPoints(alert, centroids)).toEqual([[-97.5, 35.5]]);
	});

	it('returns an empty array when no UGC has a centroid', () => {
		const alert = baseAlert({ geocodes: [{ name: 'UGC', value: 'ZZZ999' }] });

		expect(alertPoints(alert, {})).toEqual([]);
	});
});

describe('alertCentroid', () => {
	it('returns null when the alert resolves to no points', () => {
		expect(
			alertCentroid(baseAlert({ geocodes: [{ name: 'UGC', value: 'ZZZ999' }] }), {})
		).toBeNull();
	});

	it('averages the UGC centroids of a zone-based alert into one point', () => {
		const alert = baseAlert({
			geocodes: [{ name: 'UGC', value: 'KSZ001 KSZ002 KSZ003 KSZ999' }]
		});
		const centroids = {
			KSZ001: [-100, 38] as [number, number],
			KSZ002: [-98, 38] as [number, number],
			KSZ003: [-99, 40] as [number, number]
		};

		expect(alertCentroid(alert, centroids)).toEqual([-99, 38.666666666666664]);
	});

	it('uses the polygon bbox centroid when the alert carries geometry', () => {
		const alert = baseAlert({
			geocodes: [{ name: 'UGC', value: 'OKC143' }],
			geometry: {
				type: 'Polygon',
				coordinates: [
					[
						[-100, 30],
						[-98, 30],
						[-98, 32],
						[-100, 32],
						[-100, 30]
					]
				]
			}
		});

		expect(alertCentroid(alert, { OKC143: [0, 0] })).toEqual([-99, 31]);
	});

	it('averages across the antimeridian instead of through the prime meridian', () => {
		const alert = baseAlert({
			geocodes: [
				{ name: 'UGC', value: 'PKZ001' },
				{ name: 'UGC', value: 'PKZ002' }
			]
		});
		const centroids = {
			PKZ001: [178, 52] as [number, number],
			PKZ002: [-178, 54] as [number, number]
		};

		expect(alertCentroid(alert, centroids)).toEqual([180, 53]);
	});
});
