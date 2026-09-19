import { describe, it, expect, vi } from 'vitest';
import { createPolygonFeatureCache } from './polygonCache';
import type { Alert } from '$lib/alerts/types';

describe('createPolygonFeatureCache', () => {
	it('reuses previous key when prev.geometry === alert.geometry without re-hashing', () => {
		const cache = createPolygonFeatureCache();
		const geom1: NonNullable<Alert['geometry']> = {
			type: 'Polygon',
			coordinates: [
				[
					[0, 0],
					[0, 1],
					[1, 1],
					[1, 0],
					[0, 0]
				]
			]
		};
		const alert1: Alert = {
			id: 'a1',
			geometry: geom1,
			severity: 'Severe',
			source: 'noaa'
		} as unknown as Alert;

		const stringifySpy = vi.spyOn(JSON, 'stringify');

		// First pass: computes geomKey for alert1
		cache([alert1]);
		expect(stringifySpy).toHaveBeenCalledTimes(1);

		// Second pass: alert1 has unchanged geometry object reference; alert2 is new
		const geom2: NonNullable<Alert['geometry']> = {
			type: 'Polygon',
			coordinates: [
				[
					[2, 2],
					[2, 3],
					[3, 3],
					[3, 2],
					[2, 2]
				]
			]
		};
		const alert2: Alert = {
			id: 'a2',
			geometry: geom2,
			severity: 'Moderate',
			source: 'noaa'
		} as unknown as Alert;

		stringifySpy.mockClear();
		cache([alert1, alert2]);

		// Only alert2's geometry should be hashed; alert1's unchanged geometry must be reused
		expect(stringifySpy).toHaveBeenCalledTimes(1);
	});
});
