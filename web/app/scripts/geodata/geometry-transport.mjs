import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Validates that precision is an integer between 0 and 9.
 * @param {unknown} precision
 */
export function validatePrecision(precision) {
	if (
		typeof precision !== 'number' ||
		!Number.isInteger(precision) ||
		precision < 0 ||
		precision > 9
	) {
		throw new Error(
			`Invalid precision: expected integer between 0 and 9, got ${String(precision)}`
		);
	}
}

/**
 * Inverse of quantization.
 * @param {number} quant
 * @param {number} precision
 * @param {number} factor
 * @returns {number}
 */
export function dequantize(quant, precision, factor) {
	if (quant === 0) return 0;
	if (precision === 0) return quant;
	return quant / factor;
}

/**
 * Encodes a signed integer delta into Google base64url/base32 (+63) polyline chunk.
 * Arithmetic is used instead of 32-bit bitwise shifts.
 * @param {number} delta
 * @returns {string}
 */
export function encodeSignedDelta(delta) {
	let u = delta < 0 ? -delta * 2 - 1 : delta * 2;
	let str = '';
	while (u >= 32) {
		const chunk = (u % 32) + 32;
		str += String.fromCharCode(chunk + 63);
		u = Math.floor(u / 32);
	}
	str += String.fromCharCode(u + 63);
	return str;
}

/**
 * Encodes a single closed ring of 2D [lon, lat] coordinates into a polyline string.
 * @param {number[][]} ring
 * @param {number} precision
 * @returns {string}
 */
export function encodeRing(ring, precision) {
	validatePrecision(precision);
	if (!Array.isArray(ring) || ring.length < 4) {
		throw new Error('Ring must have at least 4 coordinates');
	}
	const first = ring[0];
	const last = ring[ring.length - 1];
	if (!first || !last || first[0] !== last[0] || first[1] !== last[1]) {
		throw new Error('Ring must be closed (first point must equal last point)');
	}

	const factor = 10 ** precision;
	let prevQuantLon = 0;
	let prevQuantLat = 0;
	let result = '';

	for (const pos of ring) {
		const lon = pos[0];
		const lat = pos[1];
		const quantLon = Math.round(lon * factor);
		const quantLat = Math.round(lat * factor);

		const deltaLon = quantLon - prevQuantLon;
		const deltaLat = quantLat - prevQuantLat;

		prevQuantLon = quantLon;
		prevQuantLat = quantLat;

		result += encodeSignedDelta(deltaLon);
		result += encodeSignedDelta(deltaLat);
	}

	return result;
}

/**
 * Checks if a geometry is a valid encodable Polygon or MultiPolygon with closed rings of >= 4 points.
 * @param {any} geometry
 * @returns {boolean}
 */
export function isGeometryEncodable(geometry) {
	if (!geometry || typeof geometry !== 'object') return false;
	if (geometry.type === 'Polygon') {
		if (!Array.isArray(geometry.coordinates) || geometry.coordinates.length === 0) return false;
		for (const ring of geometry.coordinates) {
			if (!Array.isArray(ring) || ring.length < 4) return false;
			const first = ring[0];
			const last = ring[ring.length - 1];
			if (!first || !last || first[0] !== last[0] || first[1] !== last[1]) return false;
		}
		return true;
	}
	if (geometry.type === 'MultiPolygon') {
		if (!Array.isArray(geometry.coordinates) || geometry.coordinates.length === 0) return false;
		for (const poly of geometry.coordinates) {
			if (!Array.isArray(poly) || poly.length === 0) return false;
			for (const ring of poly) {
				if (!Array.isArray(ring) || ring.length < 4) return false;
				const first = ring[0];
				const last = ring[ring.length - 1];
				if (!first || !last || first[0] !== last[0] || first[1] !== last[1]) return false;
			}
		}
		return true;
	}
	return false;
}

/**
 * Extracts all coordinates in a Polygon or MultiPolygon.
 * @param {any} geometry
 * @returns {Array<[number, number]>}
 */
export function getGeometryPositions(geometry) {
	const positions = [];
	if (geometry.type === 'Polygon') {
		for (const ring of geometry.coordinates) {
			for (const pos of ring) {
				positions.push(pos);
			}
		}
	} else if (geometry.type === 'MultiPolygon') {
		for (const poly of geometry.coordinates) {
			for (const ring of poly) {
				for (const pos of ring) {
					positions.push(pos);
				}
			}
		}
	}
	return positions;
}

/**
 * Finds the minimum precision p in [0..9] such that for all coordinates v in the geometry,
 * round(v * 10^p) / 10^p equals v exactly.
 * Returns null if no such precision exists or geometry is unencodable.
 * @param {any} geometry
 * @returns {number | null}
 */
export function findMinPrecision(geometry) {
	if (!isGeometryEncodable(geometry)) return null;
	const positions = getGeometryPositions(geometry);
	if (positions.length === 0) return null;

	for (let p = 0; p <= 9; p++) {
		const factor = 10 ** p;
		let allMatch = true;
		for (let i = 0; i < positions.length; i++) {
			const pos = positions[i];
			if (!Array.isArray(pos) || pos.length !== 2) return null;
			const lon = pos[0];
			const lat = pos[1];
			if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
				return null;
			}
			const quantLon = Math.round(lon * factor);
			const quantLat = Math.round(lat * factor);
			if (
				!Number.isSafeInteger(quantLon) ||
				!Number.isSafeInteger(quantLat) ||
				Math.abs(quantLon) > Number.MAX_SAFE_INTEGER / 4 ||
				Math.abs(quantLat) > Number.MAX_SAFE_INTEGER / 4
			) {
				allMatch = false;
				break;
			}
			const decLon = dequantize(quantLon, p, factor);
			const decLat = dequantize(quantLat, p, factor);
			if (decLon !== lon || decLat !== lat) {
				allMatch = false;
				break;
			}
		}
		if (allMatch) {
			return p;
		}
	}
	return null;
}

/**
 * Encodes a Polygon geometry into polyline encoding at the specified precision.
 * @param {import('geojson').Polygon} polygon
 * @param {number} precision
 * @returns {any}
 */
export function encodePolygon(polygon, precision) {
	validatePrecision(precision);
	return {
		type: 'Polygon',
		encoding: 'polyline',
		precision,
		coordinates: polygon.coordinates.map((ring) => encodeRing(ring, precision))
	};
}

/**
 * Encodes a MultiPolygon geometry into polyline encoding at the specified precision.
 * @param {import('geojson').MultiPolygon} multiPolygon
 * @param {number} precision
 * @returns {any}
 */
export function encodeMultiPolygon(multiPolygon, precision) {
	validatePrecision(precision);
	return {
		type: 'MultiPolygon',
		encoding: 'polyline',
		precision,
		coordinates: multiPolygon.coordinates.map((poly) =>
			poly.map((ring) => encodeRing(ring, precision))
		)
	};
}

/**
 * Encodes a geometry (Polygon or MultiPolygon) using adaptive precision.
 * If unsupported, invalid, or precision > 9 would be required, returns original geometry.
 * @param {any} geometry
 * @returns {any}
 */
export function encodeGeometry(geometry) {
	if (!geometry || typeof geometry !== 'object') return geometry;
	if (geometry.encoding === 'polyline') return geometry;
	if (Object.keys(geometry).some((key) => key !== 'type' && key !== 'coordinates')) return geometry;
	if (geometry.type !== 'Polygon' && geometry.type !== 'MultiPolygon') {
		return geometry;
	}
	const precision = findMinPrecision(geometry);
	if (precision === null) {
		return geometry;
	}
	try {
		if (geometry.type === 'Polygon') {
			return encodePolygon(geometry, precision);
		}
		if (geometry.type === 'MultiPolygon') {
			return encodeMultiPolygon(geometry, precision);
		}
	} catch {
		return geometry;
	}
	return geometry;
}

/**
 * Encodes a GeoJSON Feature preserving all feature metadata (id, properties, bbox, foreign fields).
 * @param {any} feature
 * @returns {any}
 */
export function encodeFeature(feature) {
	if (!feature || typeof feature !== 'object') return feature;
	if (!('geometry' in feature) || !feature.geometry) return feature;
	const encodedGeom = encodeGeometry(feature.geometry);
	return {
		...feature,
		geometry: encodedGeom
	};
}

/**
 * Encodes a GeoJSON FeatureCollection preserving all members (type, bbox, foreign fields).
 * @param {any} fc
 * @returns {any}
 */
export function encodeFeatureCollection(fc) {
	if (!fc || typeof fc !== 'object') return fc;
	if (!Array.isArray(fc.features)) return fc;
	return {
		...fc,
		features: fc.features.map(encodeFeature)
	};
}

// ---------------------------------------------------------------------------
// File Preparation and Vite Plugin
// ---------------------------------------------------------------------------

export const POLYLINE_FILES = [
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
];

/**
 * Generates the -polyline-v1.json variants in dataDir from the original files.
 * Always encodes current inputs; skips writing unchanged output unless force is true.
 * @param {string} dataDir
 * @param {{ force?: boolean }} [options]
 * @returns {string[]} Paths of generated files
 */
export function generatePolylineFiles(dataDir, options = {}) {
	const generated = [];
	for (const { original, polyline } of POLYLINE_FILES) {
		const origPath = path.join(dataDir, original);
		const polyPath = path.join(dataDir, polyline);

		const origContent = fs.readFileSync(origPath, 'utf8');
		const fc = JSON.parse(origContent);
		const encodedFc = encodeFeatureCollection(fc);
		const content = JSON.stringify(encodedFc);
		if (!options.force && fs.existsSync(polyPath) && fs.readFileSync(polyPath, 'utf8') === content)
			continue;
		fs.writeFileSync(polyPath, content);
		generated.push(polyPath);
	}
	return generated;
}

/**
 * Vite plugin that ensures static/data/*-polyline-v1.json exist before SvelteKit copies static assets.
 * @param {object} [options]
 * @param {boolean} [options.force]
 * @returns {import('vite').Plugin}
 */
export function geometryTransportPlugin(options = {}) {
	return {
		name: 'geometry-transport',
		configResolved(config) {
			generatePolylineFiles(path.resolve(config.root, 'static', 'data'), options);
		}
	};
}

const currentFile = fileURLToPath(import.meta.url);
const isDirectCall =
	process.argv[1] &&
	(process.argv[1] === currentFile || process.argv[1].endsWith('geometry-transport.mjs'));

if (isDirectCall) {
	const dataDir = path.resolve(path.dirname(currentFile), '..', '..', 'static', 'data');
	console.log(`[geometry-transport] Generating polyline geodata in ${dataDir}...`);
	const results = generatePolylineFiles(dataDir, { force: true });
	console.log(`[geometry-transport] Generated ${results.length} files.`);
}
