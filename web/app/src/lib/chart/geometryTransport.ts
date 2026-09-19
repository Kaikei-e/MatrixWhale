import type { Polygon, MultiPolygon, Position } from 'geojson';

export class GeometryDecodeError extends Error {
	constructor(message: string) {
		super(message);
		this.name = 'GeometryDecodeError';
	}
}

export interface EncodedPolygon {
	type: 'Polygon';
	encoding: 'polyline';
	precision: number;
	coordinates: string[];
}

export interface EncodedMultiPolygon {
	type: 'MultiPolygon';
	encoding: 'polyline';
	precision: number;
	coordinates: string[][];
}

export type EncodedGeometry = EncodedPolygon | EncodedMultiPolygon;

export type TransportGeometry = Polygon | MultiPolygon | EncodedGeometry | null | undefined;

export function validatePrecision(precision: unknown): asserts precision is number {
	if (
		typeof precision !== 'number' ||
		!Number.isInteger(precision) ||
		precision < 0 ||
		precision > 9
	) {
		throw new GeometryDecodeError(
			`Invalid precision: expected integer between 0 and 9, got ${String(precision)}`
		);
	}
}

/**
 * Decodes an encoded polyline ring into GeoJSON [longitude, latitude] coordinates.
 * Coordinates are deltas starting from [0, 0] for the ring.
 * Arithmetic is used instead of 32-bit bitwise shifts to support precision up to 9
 * without integer overflow.
 */
export function decodeRing(encoded: string, precision: number): Position[] {
	validatePrecision(precision);
	if (typeof encoded !== 'string') {
		throw new GeometryDecodeError('Invalid polyline: expected string');
	}
	if (encoded.length === 0) {
		throw new GeometryDecodeError('Truncated polyline: ring string is empty');
	}

	const factor = 10 ** precision;
	let prevQuantLon = 0;
	let prevQuantLat = 0;
	let u = 0;
	let multiplier = 1;
	let isLon = true;
	let hasMore = false;
	const positions: Position[] = [];
	let currentLon = 0;

	for (let i = 0; i < encoded.length; i++) {
		const code = encoded.charCodeAt(i);
		if (code < 63 || code > 126) {
			throw new GeometryDecodeError(
				`Invalid character '${encoded[i]}' (code ${code}) in polyline at index ${i}`
			);
		}

		const val = code - 63;
		const chunk = val % 32;
		hasMore = val >= 32;

		if (multiplier > Number.MAX_SAFE_INTEGER / 32) {
			throw new GeometryDecodeError('Unsafe integer: multiplier overflow in polyline');
		}
		const addition = chunk * multiplier;
		if (u > Number.MAX_SAFE_INTEGER - addition) {
			throw new GeometryDecodeError('Unsafe integer: accumulated value overflow in polyline');
		}
		u += addition;

		if (hasMore) {
			multiplier *= 32;
		} else {
			const delta = u % 2 !== 0 ? -((u + 1) / 2) : u / 2;
			u = 0;
			multiplier = 1;

			if (isLon) {
				const nextQuantLon = prevQuantLon + delta;
				if (!Number.isSafeInteger(nextQuantLon)) {
					throw new GeometryDecodeError(
						'Unsafe integer: longitude coordinate accumulator overflow'
					);
				}
				prevQuantLon = nextQuantLon;
				currentLon = prevQuantLon / factor;
				isLon = false;
			} else {
				const nextQuantLat = prevQuantLat + delta;
				if (!Number.isSafeInteger(nextQuantLat)) {
					throw new GeometryDecodeError('Unsafe integer: latitude coordinate accumulator overflow');
				}
				prevQuantLat = nextQuantLat;
				const currentLat = prevQuantLat / factor;
				positions.push([currentLon, currentLat]);
				isLon = true;
			}
		}
	}

	if (hasMore) {
		throw new GeometryDecodeError('Truncated polyline: input ended with continuation bit set');
	}

	if (!isLon) {
		throw new GeometryDecodeError(
			'Truncated polyline: odd number of coordinate values, expected [lon, lat] pairs'
		);
	}

	if (positions.length < 4) {
		throw new GeometryDecodeError(
			`Invalid ring: expected at least 4 coordinates for a closed ring, got ${positions.length}`
		);
	}

	const first = positions[0];
	const last = positions[positions.length - 1];
	if (first[0] !== last[0] || first[1] !== last[1]) {
		throw new GeometryDecodeError(
			'Invalid ring: ring must be closed (start point does not equal end point)'
		);
	}

	return positions;
}

export function decodePolygon(encoded: EncodedPolygon): Polygon {
	if (!encoded || typeof encoded !== 'object') {
		throw new GeometryDecodeError('Invalid EncodedPolygon: expected object');
	}
	if (encoded.type !== 'Polygon') {
		throw new GeometryDecodeError(`Expected Polygon, got ${String(encoded.type)}`);
	}
	if (encoded.encoding !== 'polyline') {
		throw new GeometryDecodeError(`Expected polyline encoding, got ${String(encoded.encoding)}`);
	}
	validatePrecision(encoded.precision);
	if (!Array.isArray(encoded.coordinates)) {
		throw new GeometryDecodeError('Polygon coordinates must be an array of ring strings');
	}
	if (encoded.coordinates.length === 0) {
		throw new GeometryDecodeError('Polygon coordinates cannot be empty');
	}

	const coordinates: Position[][] = [];
	for (let i = 0; i < encoded.coordinates.length; i++) {
		const ring = encoded.coordinates[i];
		if (typeof ring !== 'string') {
			throw new GeometryDecodeError(
				`Polygon ring at index ${i} must be a string, got ${typeof ring}`
			);
		}
		coordinates.push(decodeRing(ring, encoded.precision));
	}

	return {
		type: 'Polygon',
		coordinates
	};
}

export function decodeMultiPolygon(encoded: EncodedMultiPolygon): MultiPolygon {
	if (!encoded || typeof encoded !== 'object') {
		throw new GeometryDecodeError('Invalid EncodedMultiPolygon: expected object');
	}
	if (encoded.type !== 'MultiPolygon') {
		throw new GeometryDecodeError(`Expected MultiPolygon, got ${String(encoded.type)}`);
	}
	if (encoded.encoding !== 'polyline') {
		throw new GeometryDecodeError(`Expected polyline encoding, got ${String(encoded.encoding)}`);
	}
	validatePrecision(encoded.precision);
	if (!Array.isArray(encoded.coordinates)) {
		throw new GeometryDecodeError('MultiPolygon coordinates must be an array of polygon rings');
	}
	if (encoded.coordinates.length === 0) {
		throw new GeometryDecodeError('MultiPolygon coordinates cannot be empty');
	}

	const coordinates: Position[][][] = [];
	for (let p = 0; p < encoded.coordinates.length; p++) {
		const poly = encoded.coordinates[p];
		if (!Array.isArray(poly)) {
			throw new GeometryDecodeError(
				`MultiPolygon polygon at index ${p} must be an array of ring strings`
			);
		}
		if (poly.length === 0) {
			throw new GeometryDecodeError(
				`MultiPolygon polygon at index ${p} cannot have empty rings array`
			);
		}
		const polyCoords: Position[][] = [];
		for (let r = 0; r < poly.length; r++) {
			const ring = poly[r];
			if (typeof ring !== 'string') {
				throw new GeometryDecodeError(
					`MultiPolygon ring at polygon ${p}, ring ${r} must be a string, got ${typeof ring}`
				);
			}
			polyCoords.push(decodeRing(ring, encoded.precision));
		}
		coordinates.push(polyCoords);
	}

	return {
		type: 'MultiPolygon',
		coordinates
	};
}

export function isEncodedGeometry(geom: unknown): geom is EncodedGeometry {
	if (!geom || typeof geom !== 'object') return false;
	const candidate = geom as { encoding?: unknown; type?: unknown };
	return (
		candidate.encoding === 'polyline' &&
		(candidate.type === 'Polygon' || candidate.type === 'MultiPolygon')
	);
}

/**
 * Decodes encoded polyline geometry (Polygon or MultiPolygon) into GeoJSON geometry.
 * If the input is null, undefined, or already ordinary GeoJSON geometry, it is returned unchanged.
 */
export function decodeGeometry<T = Polygon | MultiPolygon | null>(geometry: unknown): T {
	if (geometry === null || geometry === undefined) {
		return null as T;
	}
	if (typeof geometry !== 'object') {
		return geometry as T;
	}
	const record = geometry as Record<string, unknown>;
	if (record.encoding === 'polyline') {
		if (record.type === 'Polygon') {
			return decodePolygon(geometry as EncodedPolygon) as unknown as T;
		}
		if (record.type === 'MultiPolygon') {
			return decodeMultiPolygon(geometry as EncodedMultiPolygon) as unknown as T;
		}
		throw new GeometryDecodeError(`Unsupported encoded geometry type: ${String(record.type)}`);
	}
	return geometry as T;
}

/**
 * Decodes a hazard's primary_geometry if it is encoded as polyline.
 * If primary_geometry is null or already ordinary GeoJSON, returns the hazard unchanged.
 */
export function decodeHazard<T extends { primary_geometry?: unknown }>(hazard: T): T {
	if (!hazard || typeof hazard !== 'object') return hazard;
	if (!('primary_geometry' in hazard)) return hazard;
	const decoded = decodeGeometry(hazard.primary_geometry);
	if (decoded === hazard.primary_geometry) return hazard;
	return {
		...hazard,
		primary_geometry: decoded
	};
}
