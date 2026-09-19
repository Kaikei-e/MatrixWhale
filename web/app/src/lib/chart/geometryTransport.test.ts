import {
	encodePolygon,
	encodeMultiPolygon,
	encodeRing,
	encodeGeometry
} from '../../../scripts/geodata/geometry-transport.mjs';
import { describe, expect, it } from 'vitest';
import type { Polygon, MultiPolygon, Point } from 'geojson';
import {
	GeometryDecodeError,
	decodeRing,
	decodePolygon,
	decodeMultiPolygon,
	decodeGeometry,
	decodeHazard,
	isEncodedGeometry,
	validatePrecision,
	type EncodedPolygon,
	type EncodedMultiPolygon
} from './geometryTransport';

describe('geometryTransport', () => {
	describe('validatePrecision', () => {
		it('accepts valid integers between 0 and 9', () => {
			for (let p = 0; p <= 9; p++) {
				expect(() => validatePrecision(p)).not.toThrow();
			}
		});

		it('rejects invalid precisions', () => {
			expect(() => validatePrecision(-1)).toThrow(GeometryDecodeError);
			expect(() => validatePrecision(10)).toThrow(GeometryDecodeError);
			expect(() => validatePrecision(4.5)).toThrow(GeometryDecodeError);
			expect(() => validatePrecision('4')).toThrow(GeometryDecodeError);
			expect(() => validatePrecision(null)).toThrow(GeometryDecodeError);
			expect(() => validatePrecision(undefined)).toThrow(GeometryDecodeError);
			expect(() => validatePrecision(NaN)).toThrow(GeometryDecodeError);
			expect(() => validatePrecision(Infinity)).toThrow(GeometryDecodeError);
		});
	});

	describe('exact coordinates and [longitude, latitude] ordering', () => {
		it('decodes exact coordinates and preserves [longitude, latitude] ordering', () => {
			// A simple triangle polygon with 4 coordinates (closed)
			const original: Polygon = {
				type: 'Polygon',
				coordinates: [
					[
						[-122.4194, 37.7749],
						[-122.4094, 37.7849],
						[-122.4294, 37.7949],
						[-122.4194, 37.7749]
					]
				]
			};

			const encoded = encodePolygon(original, 4);
			expect(encoded.type).toBe('Polygon');
			expect(encoded.encoding).toBe('polyline');
			expect(encoded.precision).toBe(4);
			expect(encoded.coordinates).toHaveLength(1);

			const decoded = decodePolygon(encoded);
			expect(decoded.type).toBe('Polygon');
			expect(decoded.coordinates).toEqual(original.coordinates);

			// Explicit verify of first point [lon, lat]
			expect(decoded.coordinates[0][0][0]).toBe(-122.4194);
			expect(decoded.coordinates[0][0][1]).toBe(37.7749);
		});

		it('decodes known hand-verified polyline string', () => {
			// At precision 0:
			// Ring: [[100, 20], [101, 20], [101, 21], [100, 20]]
			// lon 100 (delta 100 -> u=200 -> 'gE'), lat 20 (delta 20 -> u=40 -> 'g@')
			// lon 101 (delta 1 -> u=2 -> 'A'), lat 20 (delta 0 -> u=0 -> '?')
			// lon 101 (delta 0 -> u=0 -> '?'), lat 21 (delta 1 -> u=2 -> 'A')
			// lon 100 (delta -1 -> u=1 -> '@'), lat 20 (delta -1 -> u=1 -> '@')
			// Expected string: "gEg@A??A@@"
			const encodedRing = 'gEg@A??A@@';
			const positions = decodeRing(encodedRing, 0);
			expect(positions).toEqual([
				[100, 20],
				[101, 20],
				[101, 21],
				[100, 20]
			]);
		});
	});

	describe('holes (interior rings)', () => {
		it('decodes polygons with exterior rings and interior rings (holes)', () => {
			const polygonWithHole: Polygon = {
				type: 'Polygon',
				coordinates: [
					// Exterior ring
					[
						[10.0, 10.0],
						[20.0, 10.0],
						[20.0, 20.0],
						[10.0, 20.0],
						[10.0, 10.0]
					],
					// Hole (interior ring) - deltas must restart at [0, 0]
					[
						[12.0, 12.0],
						[18.0, 12.0],
						[18.0, 18.0],
						[12.0, 18.0],
						[12.0, 12.0]
					]
				]
			};

			const encoded = encodePolygon(polygonWithHole, 2);
			expect(encoded.coordinates).toHaveLength(2);

			const decoded = decodePolygon(encoded);
			expect(decoded.coordinates).toHaveLength(2);
			expect(decoded.coordinates).toEqual(polygonWithHole.coordinates);
		});
	});

	describe('multipolygons', () => {
		it('decodes MultiPolygon with multiple polygons, including holes', () => {
			const multiPoly: MultiPolygon = {
				type: 'MultiPolygon',
				coordinates: [
					// Polygon 1 (with hole)
					[
						[
							[-10.0, -10.0],
							[-5.0, -10.0],
							[-5.0, -5.0],
							[-10.0, -5.0],
							[-10.0, -10.0]
						],
						[
							[-9.0, -9.0],
							[-6.0, -9.0],
							[-6.0, -6.0],
							[-9.0, -6.0],
							[-9.0, -9.0]
						]
					],
					// Polygon 2 (without hole)
					[
						[
							[30.1234, 40.5678],
							[35.1234, 40.5678],
							[35.1234, 45.5678],
							[30.1234, 45.5678],
							[30.1234, 40.5678]
						]
					]
				]
			};

			const encoded = encodeMultiPolygon(multiPoly, 4);
			expect(encoded.type).toBe('MultiPolygon');
			expect(encoded.coordinates).toHaveLength(2);
			expect(encoded.coordinates[0]).toHaveLength(2);
			expect(encoded.coordinates[1]).toHaveLength(1);

			const decoded = decodeMultiPolygon(encoded);
			expect(decoded.type).toBe('MultiPolygon');
			expect(decoded.coordinates).toEqual(multiPoly.coordinates);
		});
	});

	describe('negative coordinates', () => {
		it('correctly handles negative longitudes and latitudes', () => {
			const polygon: Polygon = {
				type: 'Polygon',
				coordinates: [
					[
						[-73.9851, -40.7488],
						[-70.1234, -40.7488],
						[-70.1234, -35.1234],
						[-73.9851, -35.1234],
						[-73.9851, -40.7488]
					]
				]
			};

			const encoded = encodePolygon(polygon, 4);
			const decoded = decodePolygon(encoded);
			expect(decoded.coordinates).toEqual(polygon.coordinates);
		});
	});

	describe('antimeridian', () => {
		it('handles coordinates spanning across the antimeridian (+/-180 degrees)', () => {
			const antimeridianPolygon: Polygon = {
				type: 'Polygon',
				coordinates: [
					[
						[179.95, -15.5],
						[-179.95, -15.5],
						[-179.95, -14.5],
						[179.95, -14.5],
						[179.95, -15.5]
					]
				]
			};

			const encoded = encodePolygon(antimeridianPolygon, 3);
			const decoded = decodePolygon(encoded);
			expect(decoded.coordinates).toEqual(antimeridianPolygon.coordinates);
		});
	});

	describe('extreme precision and arithmetic (no 32-bit shift overflow)', () => {
		it('supports precision 0 (integers)', () => {
			const polygon: Polygon = {
				type: 'Polygon',
				coordinates: [
					[
						[0, 0],
						[10, 0],
						[10, 10],
						[0, 10],
						[0, 0]
					]
				]
			};
			const encoded = encodePolygon(polygon, 0);
			const decoded = decodePolygon(encoded);
			expect(decoded.coordinates).toEqual(polygon.coordinates);
		});

		it('supports precision 9 with deltas exceeding 32-bit integer limits without overflow', () => {
			// 179.123456789 * 1e9 = 179123456789
			// u = 179123456789 * 2 = 358246913578 > 2^31 - 1 (2147483647)
			// Bitwise shift operators in JS (<<, >>, |) truncate to 32-bit signed ints,
			// which would corrupt 358246913578 into -868953110.
			// Arithmetic operations handle up to Number.MAX_SAFE_INTEGER (9007199254740991) exactly.
			const highPrecisionPolygon: Polygon = {
				type: 'Polygon',
				coordinates: [
					[
						[179.123456789, -89.987654321],
						[179.987654321, -89.987654321],
						[179.987654321, -89.123456789],
						[179.123456789, -89.123456789],
						[179.123456789, -89.987654321]
					]
				]
			};

			const encoded = encodePolygon(highPrecisionPolygon, 9);
			const decoded = decodePolygon(encoded);
			expect(decoded.coordinates).toEqual(highPrecisionPolygon.coordinates);
		});
	});

	describe('malformed detection', () => {
		it('rejects invalid character codes (< 63 or > 126)', () => {
			// Space (ASCII 32) is invalid (< 63)
			expect(() => decodeRing('gE g@A??A@@', 0)).toThrow(GeometryDecodeError);
			// '<' (ASCII 60) is invalid
			expect(() => decodeRing('gE<g@A??A@@', 0)).toThrow(GeometryDecodeError);
			// DEL (ASCII 127) is invalid (> 126)
			expect(() => decodeRing(`gE${String.fromCharCode(127)}g@A??A@@`, 0)).toThrow(
				GeometryDecodeError
			);
		});

		it('rejects truncated polyline with continuation bit set at end of string', () => {
			// 'g' has charCode 103, val 40, has continuation bit set!
			expect(() => decodeRing('g', 0)).toThrow(GeometryDecodeError);
			expect(() => decodeRing('gEg@A??A@g', 0)).toThrow(GeometryDecodeError);
		});

		it('rejects truncated polyline with odd number of coordinate values', () => {
			// Decodes 7 values (an incomplete pair)
			// Ring "gEg@A??A@@" has 8 values (4 pairs). "gEg@A??" has 5 values!
			expect(() => decodeRing('gEg@A??', 0)).toThrow(GeometryDecodeError);
		});

		it('rejects empty ring string', () => {
			expect(() => decodeRing('', 0)).toThrow(GeometryDecodeError);
		});

		it('rejects rings with fewer than 4 positions', () => {
			// Ring with only 3 points (even if first equals last)
			// Point 1: [100, 20], Point 2: [101, 20], Point 3: [100, 20]
			// Only 3 positions -> invalid for linear ring
			const ring3 = 'gEg@A??@@';
			expect(() => decodeRing(ring3, 0)).toThrow(GeometryDecodeError);
		});

		it('rejects rings that are not closed', () => {
			// 4 points but last != first
			// [100, 20], [101, 20], [101, 21], [102, 22]
			const unclosedRing = 'gEg@A??AAB';
			expect(() => decodeRing(unclosedRing, 0)).toThrow(GeometryDecodeError);
		});

		it('rejects unsafe integer overflow', () => {
			// 15 continuation chars in a row: 32^14 exceeds Number.MAX_SAFE_INTEGER
			const overflowChunk = '~~~~~~~~~~~~~~~~';
			expect(() => decodeRing(overflowChunk, 0)).toThrow(GeometryDecodeError);
		});

		it('rejects invalid Polygon shapes', () => {
			expect(() =>
				decodePolygon({
					type: 'Polygon',
					encoding: 'polyline',
					precision: 4,
					coordinates: null as unknown as string[]
				})
			).toThrow(GeometryDecodeError);

			expect(() =>
				decodePolygon({
					type: 'Polygon',
					encoding: 'polyline',
					precision: 4,
					coordinates: []
				})
			).toThrow(GeometryDecodeError);

			expect(() =>
				decodePolygon({
					type: 'Polygon',
					encoding: 'polyline',
					precision: 4,
					coordinates: [123 as unknown as string]
				})
			).toThrow(GeometryDecodeError);
		});

		it('rejects invalid MultiPolygon shapes', () => {
			expect(() =>
				decodeMultiPolygon({
					type: 'MultiPolygon',
					encoding: 'polyline',
					precision: 4,
					coordinates: []
				})
			).toThrow(GeometryDecodeError);

			expect(() =>
				decodeMultiPolygon({
					type: 'MultiPolygon',
					encoding: 'polyline',
					precision: 4,
					coordinates: [['gEg@A??A@@'], []]
				})
			).toThrow(GeometryDecodeError);

			expect(() =>
				decodeMultiPolygon({
					type: 'MultiPolygon',
					encoding: 'polyline',
					precision: 4,
					coordinates: [['not a valid ring']]
				})
			).toThrow(GeometryDecodeError);
		});

		it('rejects unsupported geometry type in decodeGeometry', () => {
			expect(() =>
				decodeGeometry({
					type: 'LineString',
					encoding: 'polyline',
					precision: 4,
					coordinates: 'gEg@'
				})
			).toThrow(GeometryDecodeError);
		});
	});

	describe('legacy fallback and decodeGeometry pass-through', () => {
		it('returns null for null or undefined', () => {
			expect(decodeGeometry(null)).toBeNull();
			expect(decodeGeometry(undefined)).toBeNull();
		});

		it('preserves ordinary GeoJSON Polygon unchanged', () => {
			const ordinaryPolygon: Polygon = {
				type: 'Polygon',
				coordinates: [
					[
						[0, 0],
						[1, 0],
						[1, 1],
						[0, 0]
					]
				]
			};
			const result = decodeGeometry(ordinaryPolygon);
			expect(result).toBe(ordinaryPolygon);
		});

		it('preserves ordinary GeoJSON MultiPolygon unchanged', () => {
			const ordinaryMultiPolygon: MultiPolygon = {
				type: 'MultiPolygon',
				coordinates: [
					[
						[
							[0, 0],
							[1, 0],
							[1, 1],
							[0, 0]
						]
					]
				]
			};
			const result = decodeGeometry(ordinaryMultiPolygon);
			expect(result).toBe(ordinaryMultiPolygon);
		});

		it('preserves ordinary GeoJSON Point unchanged', () => {
			const point: Point = {
				type: 'Point',
				coordinates: [120.5, 14.5]
			};
			const result = decodeGeometry(point);
			expect(result).toBe(point);
		});

		it('isEncodedGeometry returns true only for valid encoded geometry structures', () => {
			expect(
				isEncodedGeometry({
					type: 'Polygon',
					encoding: 'polyline',
					precision: 4,
					coordinates: ['abc']
				})
			).toBe(true);

			expect(
				isEncodedGeometry({
					type: 'MultiPolygon',
					encoding: 'polyline',
					precision: 4,
					coordinates: [['abc']]
				})
			).toBe(true);

			expect(isEncodedGeometry(null)).toBe(false);
			expect(isEncodedGeometry({ type: 'Polygon', coordinates: [] })).toBe(false);
			expect(isEncodedGeometry({ type: 'Point', coordinates: [0, 0] })).toBe(false);
		});

		it('decodeHazard decodes encoded primary_geometry and leaves others unchanged', () => {
			const originalPoly: Polygon = {
				type: 'Polygon',
				coordinates: [
					[
						[100, 20],
						[101, 20],
						[101, 21],
						[100, 20]
					]
				]
			};
			const encoded = encodePolygon(originalPoly, 0);

			const encodedHazard = {
				id: 'hazard-1',
				title: 'Test Hazard',
				primary_geometry: encoded
			};

			const decoded = decodeHazard(encodedHazard);
			expect(decoded.id).toBe('hazard-1');
			expect(decoded.primary_geometry).toEqual(originalPoly);

			// Identity preservation when primary_geometry is already GeoJSON or null
			const ordinaryHazard = {
				id: 'hazard-2',
				title: 'Ordinary Hazard',
				primary_geometry: originalPoly
			};
			expect(decodeHazard(ordinaryHazard)).toBe(ordinaryHazard);

			const nullHazard = {
				id: 'hazard-3',
				title: 'Null Hazard',
				primary_geometry: null
			};
			expect(decodeHazard(nullHazard)).toBe(nullHazard);
		});
	});
});
