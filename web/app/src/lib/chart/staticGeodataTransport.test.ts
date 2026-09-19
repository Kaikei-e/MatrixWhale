import { describe, expect, it, beforeEach } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { FeatureCollection, Feature, Polygon, MultiPolygon, Point, LineString } from 'geojson';
import {
	encodeFeatureCollection,
	encodeGeometry,
	findMinPrecision,
	isGeometryEncodable,
	POLYLINE_FILES,
	generatePolylineFiles
} from '../../../scripts/geodata/geometry-transport.mjs';
import { decodeFeatureCollection, fetchGeoJson, clearGeoJsonCache } from './zoneCache';
import { decodeGeometry } from './geometryTransport';
import * as DATA_FILES from './dataFiles';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const STATIC_DATA_DIR = path.resolve(__dirname, '../../../static/data');

describe('staticGeodataTransport', () => {
	beforeEach(() => {
		clearGeoJsonCache();
	});

	describe('POLYLINE_FILES configuration', () => {
		it('contains exactly the 6 static polygon files', () => {
			expect(POLYLINE_FILES).toEqual([
				{
					original: 'land-coast-ne50m-v5.1.1.json',
					polyline: 'land-coast-ne50m-v5.1.1-polyline-v1.json'
				},
				{
					original: 'land-coast-ne110m-v5.1.1.json',
					polyline: 'land-coast-ne110m-v5.1.1-polyline-v1.json'
				},
				{
					original: 'nws-forecast-zones-2026-04-16.json',
					polyline: 'nws-forecast-zones-2026-04-16-polyline-v1.json'
				},
				{
					original: 'nws-counties-2026-04-16.json',
					polyline: 'nws-counties-2026-04-16-polyline-v1.json'
				},
				{
					original: 'nws-marine-coastal-zones-2026-04-16.json',
					polyline: 'nws-marine-coastal-zones-2026-04-16-polyline-v1.json'
				},
				{
					original: 'nws-marine-offshore-zones-2026-04-16.json',
					polyline: 'nws-marine-offshore-zones-2026-04-16-polyline-v1.json'
				}
			]);
		});

		it('dataFiles exports point to the polyline-v1 endpoints while preserving centroids', () => {
			expect(DATA_FILES.LAND_50M).toBe('/data/land-coast-ne50m-v5.1.1-polyline-v1.json');
			expect(DATA_FILES.LAND_110M).toBe('/data/land-coast-ne110m-v5.1.1-polyline-v1.json');
			expect(DATA_FILES.FORECAST_ZONES).toBe(
				'/data/nws-forecast-zones-2026-04-16-polyline-v1.json'
			);
			expect(DATA_FILES.COUNTY_ZONES).toBe('/data/nws-counties-2026-04-16-polyline-v1.json');
			expect(DATA_FILES.MARINE_COASTAL_ZONES).toBe(
				'/data/nws-marine-coastal-zones-2026-04-16-polyline-v1.json'
			);
			expect(DATA_FILES.MARINE_OFFSHORE_ZONES).toBe(
				'/data/nws-marine-offshore-zones-2026-04-16-polyline-v1.json'
			);
			expect(DATA_FILES.ZONE_CENTROIDS).toBe('/data/zone-centroids-2026-04-16.json');
		});

		it('all original static files exist on disk', () => {
			for (const { original } of POLYLINE_FILES) {
				const filePath = path.join(STATIC_DATA_DIR, original);
				expect(fs.existsSync(filePath), `Missing original file: ${original}`).toBe(true);
			}
		});
	});

	describe('100% Lossless Roundtrip for All 6 Static Datasets', () => {
		for (const { original, polyline } of POLYLINE_FILES) {
			it(`encodes and losslessly decodes ${original} (identical to original GeoJSON)`, () => {
				const originalPath = path.join(STATIC_DATA_DIR, original);
				const raw = fs.readFileSync(originalPath, 'utf8');
				const originalFc = JSON.parse(raw) as FeatureCollection;

				// 1. Encode
				const encodedFc = encodeFeatureCollection(originalFc);

				// Verify contract of encoded FeatureCollection
				expect(encodedFc.type).toBe('FeatureCollection');
				expect(encodedFc.features.length).toBe(originalFc.features.length);

				// Verify every encoded feature adheres to the schema
				for (let i = 0; i < encodedFc.features.length; i++) {
					const encFeat = encodedFc.features[i];
					const origFeat = originalFc.features[i];

					expect(encFeat.id).toBe(origFeat.id);
					expect(encFeat.properties).toEqual(origFeat.properties);
					if ('bbox' in origFeat) {
						expect(encFeat.bbox).toEqual(origFeat.bbox);
					}

					const geom = encFeat.geometry as any;
					if (geom && (geom.type === 'Polygon' || geom.type === 'MultiPolygon')) {
						expect(geom.encoding).toBe('polyline');
						expect(typeof geom.precision).toBe('number');
						expect(geom.precision).toBeGreaterThanOrEqual(0);
						expect(geom.precision).toBeLessThanOrEqual(9);

						// Coordinates must be strings (or arrays of strings for MultiPolygon), no numbers
						if (geom.type === 'Polygon') {
							expect(Array.isArray(geom.coordinates)).toBe(true);
							for (const ring of geom.coordinates) {
								expect(typeof ring).toBe('string');
							}
						} else {
							expect(Array.isArray(geom.coordinates)).toBe(true);
							for (const poly of geom.coordinates) {
								expect(Array.isArray(poly)).toBe(true);
								for (const ring of poly) {
									expect(typeof ring).toBe('string');
								}
							}
						}
					}
				}

				// 2. Decode using frontend zoneCache decoder (which delegates to geometryTransport.ts)
				const decodedFc = decodeFeatureCollection(encodedFc as any);
				expect(decodedFc).toEqual(originalFc);
			});
		}
	});

	describe('Antarctic and Wrapped Coordinates (> 180° / < -180°)', () => {
		it('preserves unwrapped negative longitudes in land-coast-ne110m-v5.1.1.json', () => {
			const originalPath = path.join(STATIC_DATA_DIR, 'land-coast-ne110m-v5.1.1.json');
			const originalFc = JSON.parse(fs.readFileSync(originalPath, 'utf8')) as FeatureCollection;

			// Find coordinates with lon < -180
			let foundWrapped = false;
			for (const feat of originalFc.features) {
				const geom = feat.geometry;
				if (geom.type === 'MultiPolygon') {
					for (const poly of geom.coordinates) {
						for (const ring of poly) {
							for (const pos of ring) {
								if (pos[0] < -180) {
									foundWrapped = true;
									expect(Number.isSafeInteger(Math.round(pos[0] * 10000))).toBe(true);
								}
							}
						}
					}
				}
			}
			expect(foundWrapped).toBe(true);

			const encodedFc = encodeFeatureCollection(originalFc);
			const decodedFc = decodeFeatureCollection(encodedFc as any);
			expect(decodedFc).toEqual(originalFc);
		});

		it('roundtrips extreme wrapped coordinates within safe integer range', () => {
			const wrappedFeature: Feature<Polygon> = {
				type: 'Feature',
				id: 'ANTARCTICA_WRAPPED',
				properties: { region: 'Antarctica' },
				geometry: {
					type: 'Polygon',
					coordinates: [
						[
							[-539.9424, -85.1234],
							[-500.1234, -85.1234],
							[-500.1234, -70.5678],
							[-539.9424, -70.5678],
							[-539.9424, -85.1234]
						]
					]
				}
			};

			const fc: FeatureCollection = {
				type: 'FeatureCollection',
				features: [wrappedFeature]
			};

			const encoded = encodeFeatureCollection(fc);
			const encGeom = encoded.features[0].geometry as any;
			expect(encGeom.encoding).toBe('polyline');
			expect(encGeom.precision).toBe(4);

			const decoded = decodeFeatureCollection(encoded as any);
			expect(decoded).toEqual(fc);
		});
	});

	describe('Fallback Behavior for Unsupported Geometries and Precision Limits', () => {
		it('preserves altitude and geometry-level metadata instead of discarding them', () => {
			for (const geometry of [
				{
					type: 'Polygon',
					coordinates: [
						[
							[0, 0, 7],
							[1, 0, 8],
							[0, 1, 9],
							[0, 0, 7]
						]
					]
				},
				{
					type: 'Polygon',
					bbox: [0, 0, 1, 1],
					coordinates: [
						[
							[0, 0],
							[1, 0],
							[0, 1],
							[0, 0]
						]
					]
				}
			]) {
				expect(encodeGeometry(geometry)).toBe(geometry);
			}
		});

		it('gracefully leaves Point geometries unencoded', () => {
			const pointFeature: Feature<Point> = {
				type: 'Feature',
				id: 'POINT_1',
				properties: { name: 'Radar Site' },
				geometry: {
					type: 'Point',
					coordinates: [-122.4194, 37.7749]
				}
			};

			const fc: FeatureCollection = {
				type: 'FeatureCollection',
				features: [pointFeature]
			};

			const encoded = encodeFeatureCollection(fc);
			expect((encoded.features[0].geometry as any).encoding).toBeUndefined();
			expect(encoded.features[0].geometry).toEqual(pointFeature.geometry);

			const decoded = decodeFeatureCollection(encoded as any);
			expect(decoded).toEqual(fc);
		});

		it('gracefully leaves LineString geometries unencoded', () => {
			const lineFeature: Feature<LineString> = {
				type: 'Feature',
				id: 'LINE_1',
				properties: { route: 'Track' },
				geometry: {
					type: 'LineString',
					coordinates: [
						[-122.4, 37.7],
						[-122.5, 37.8]
					]
				}
			};

			const fc: FeatureCollection = {
				type: 'FeatureCollection',
				features: [lineFeature]
			};

			const encoded = encodeFeatureCollection(fc);
			expect((encoded.features[0].geometry as any).encoding).toBeUndefined();
			expect(encoded.features[0].geometry).toEqual(lineFeature.geometry);

			const decoded = decodeFeatureCollection(encoded as any);
			expect(decoded).toEqual(fc);
		});

		it('gracefully leaves unclosed polygon rings unencoded', () => {
			const unclosedFeature: Feature<Polygon> = {
				type: 'Feature',
				id: 'UNCLOSED_1',
				properties: {},
				geometry: {
					type: 'Polygon',
					coordinates: [
						[
							[-122.0, 37.0],
							[-121.0, 37.0],
							[-121.0, 38.0]
							// Missing closing point
						]
					]
				}
			};

			const fc: FeatureCollection = {
				type: 'FeatureCollection',
				features: [unclosedFeature]
			};

			const encoded = encodeFeatureCollection(fc);
			expect((encoded.features[0].geometry as any).encoding).toBeUndefined();
			expect(encoded.features[0].geometry).toEqual(unclosedFeature.geometry);

			const decoded = decodeFeatureCollection(encoded as any);
			expect(decoded).toEqual(fc);
		});

		it('gracefully leaves rings with fewer than 4 points unencoded', () => {
			const shortRingFeature: Feature<Polygon> = {
				type: 'Feature',
				id: 'SHORT_1',
				properties: {},
				geometry: {
					type: 'Polygon',
					coordinates: [
						[
							[-122.0, 37.0],
							[-122.0, 37.0]
						]
					]
				}
			};

			const fc: FeatureCollection = {
				type: 'FeatureCollection',
				features: [shortRingFeature]
			};

			const encoded = encodeFeatureCollection(fc);
			expect((encoded.features[0].geometry as any).encoding).toBeUndefined();
			expect(encoded.features[0].geometry).toEqual(shortRingFeature.geometry);
		});

		it('gracefully leaves features with null geometry intact', () => {
			const nullGeomFeature: any = {
				type: 'Feature',
				id: 'NULL_GEOM',
				properties: { info: 'none' },
				geometry: null
			};

			const fc: any = {
				type: 'FeatureCollection',
				features: [nullGeomFeature]
			};

			const encoded = encodeFeatureCollection(fc);
			expect(encoded.features[0].geometry).toBeNull();

			const decoded = decodeFeatureCollection(encoded);
			expect(decoded).toEqual(fc);
		});

		it('falls back when coordinate precision exceeds 9 decimal places', () => {
			const highPrecisionFeature: Feature<Polygon> = {
				type: 'Feature',
				id: 'HIGH_PRECISION',
				properties: {},
				geometry: {
					type: 'Polygon',
					coordinates: [
						[
							[-122.1234567890123, 37.1234567890123],
							[-121.1234567890123, 37.1234567890123],
							[-121.1234567890123, 38.1234567890123],
							[-122.1234567890123, 37.1234567890123]
						]
					]
				}
			};

			expect(findMinPrecision(highPrecisionFeature.geometry)).toBeNull();
			const encoded = encodeGeometry(highPrecisionFeature.geometry);
			// Falls back to unencoded geometry
			expect((encoded as any).encoding).toBeUndefined();
			expect(encoded).toEqual(highPrecisionFeature.geometry);
		});
	});

	describe('Preservation of Foreign Fields and Member Integrity', () => {
		it('preserves root and feature foreign properties, ids, and bounding boxes', () => {
			const customFc: any = {
				type: 'FeatureCollection',
				name: 'CustomLayer',
				bbox: [-125, 30, -115, 40],
				crs: { type: 'name', properties: { name: 'urn:ogc:def:crs:OGC:1.3:CRS84' } },
				customRootMember: { version: '1.0.0', author: 'NWS' },
				features: [
					{
						type: 'Feature',
						id: 'ZONE_ABC',
						bbox: [-123, 35, -121, 37],
						foreignFeatureMember: [1, 2, 3],
						properties: {
							ugc: 'CAZ001',
							name: 'Northern Coastal',
							tags: ['coastal', 'zone']
						},
						geometry: {
							type: 'Polygon',
							coordinates: [
								[
									[-123.0, 35.0],
									[-121.0, 35.0],
									[-121.0, 37.0],
									[-123.0, 35.0]
								]
							]
						}
					}
				]
			};

			const encoded = encodeFeatureCollection(customFc);
			expect(encoded.name).toBe('CustomLayer');
			expect(encoded.bbox).toEqual([-125, 30, -115, 40]);
			expect(encoded.crs).toEqual(customFc.crs);
			expect(encoded.customRootMember).toEqual(customFc.customRootMember);

			const encFeat = encoded.features[0];
			expect(encFeat.id).toBe('ZONE_ABC');
			expect(encFeat.bbox).toEqual([-123, 35, -121, 37]);
			expect(encFeat.foreignFeatureMember).toEqual([1, 2, 3]);
			expect(encFeat.properties).toEqual(customFc.features[0].properties);
			expect(encFeat.geometry.encoding).toBe('polyline');

			const decoded = decodeFeatureCollection(encoded);
			expect(decoded).toEqual(customFc);
		});
	});

	describe('Idempotency and Non-Polyline Passthrough', () => {
		it('passes already-unencoded GeoJSON through decodeFeatureCollection unchanged', () => {
			const originalPath = path.join(STATIC_DATA_DIR, 'land-coast-ne110m-v5.1.1.json');
			const originalFc = JSON.parse(fs.readFileSync(originalPath, 'utf8')) as FeatureCollection;

			const decoded = decodeFeatureCollection(originalFc);
			expect(decoded).toEqual(originalFc);
		});

		it('decodeGeometry returns null or primitives unchanged', () => {
			expect(decodeGeometry(null)).toBeNull();
			expect(decodeGeometry(undefined)).toBeNull();
			expect(decodeGeometry('non-object' as any)).toBe('non-object');
		});
	});

	describe('fetchGeoJson integration', () => {
		it('decodes polyline-encoded response transparently', async () => {
			const triangle: Polygon = {
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
			const originalFc: FeatureCollection = {
				type: 'FeatureCollection',
				features: [
					{
						type: 'Feature',
						id: 'TEST_1',
						properties: { name: 'Test' },
						geometry: triangle
					}
				]
			};

			const encodedFc = encodeFeatureCollection(originalFc);

			const mockFetch = async () =>
				({
					ok: true,
					status: 200,
					json: async () => JSON.parse(JSON.stringify(encodedFc))
				}) as unknown as Response;

			const result = await fetchGeoJson('/data/test-polyline-v1.json', mockFetch as any);
			expect(result).toEqual(originalFc);
			expect((result.features[0].geometry as any).encoding).toBeUndefined();
			expect(result.features[0].geometry).toEqual(triangle);
		});

		it('caches responses and avoids redundant fetches', async () => {
			let fetchCount = 0;
			const sampleFc: FeatureCollection = {
				type: 'FeatureCollection',
				features: []
			};

			const mockFetch = async () => {
				fetchCount++;
				return {
					ok: true,
					status: 200,
					json: async () => sampleFc
				} as unknown as Response;
			};

			const res1 = await fetchGeoJson('/data/cached.json', mockFetch as any);
			const res2 = await fetchGeoJson('/data/cached.json', mockFetch as any);

			expect(fetchCount).toBe(1);
			expect(res1).toBe(res2);

			clearGeoJsonCache();
			const res3 = await fetchGeoJson('/data/cached.json', mockFetch as any);
			expect(fetchCount).toBe(2);
		});
	});
});
