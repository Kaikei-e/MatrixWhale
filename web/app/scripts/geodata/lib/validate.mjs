import fs from 'node:fs';
import zlib from 'node:zlib';
import { lonBboxSpan } from './antimeridian.mjs';

const UGC_RE = /^([A-Z]{2}[CZ]\d{3}|[A-Z]{3}\d{3})$/;

const RAW_BUDGET = 3 * 1024 * 1024;
const GZIP_BUDGET = 1 * 1024 * 1024;

/** Validates one polygon FeatureCollection; pushes any problems onto `errors`. */
export function validatePolygonLayer(name, featureCollection, centroids, errors) {
	const seen = new Set();
	for (const f of featureCollection.features) {
		const ugc = f.properties.ugc;
		if (!UGC_RE.test(ugc)) {
			errors.push(`${name}: invalid ugc format "${ugc}"`);
		}
		if (seen.has(ugc)) {
			errors.push(`${name}: duplicate ugc "${ugc}"`);
		}
		seen.add(ugc);
		if (!Object.prototype.hasOwnProperty.call(centroids, ugc)) {
			errors.push(`${name}: ugc "${ugc}" has no entry in the centroid dict`);
		}
		const span = lonBboxSpan(f.geometry);
		if (span > 180) {
			errors.push(`${name}: ugc "${ugc}" longitude bbox span ${span.toFixed(2)}° exceeds 180°`);
		}
	}
}

function ringSets(geometry) {
	if (geometry.type === 'Polygon') return [geometry.coordinates];
	if (geometry.type === 'MultiPolygon') return geometry.coordinates;
	return [];
}

/**
 * Pushes an error for any ring with a raw consecutive |dlon| > 180 — the
 * world-spanning-edge artefact that geojson-vt turns into a band across the
 * whole map, which `unwrapAntimeridian` is meant to have already fixed.
 */
export function validateNoWorldSpanningEdges(name, featureCollection, errors) {
	for (const f of featureCollection.features) {
		for (const rings of ringSets(f.geometry)) {
			for (const ring of rings) {
				for (let i = 1; i < ring.length; i++) {
					const dLon = Math.abs(ring[i][0] - ring[i - 1][0]);
					if (dLon > 180) {
						errors.push(`${name}: world-spanning edge (|dlon|=${dLon.toFixed(1)}deg)`);
					}
				}
			}
		}
	}
}

/** @returns {Array<{name: string, raw: number, gzip: number}>} */
export function sizeReport(files) {
	return files.map(({ name, filePath }) => {
		const buf = fs.readFileSync(filePath);
		return { name, raw: buf.length, gzip: zlib.gzipSync(buf).length };
	});
}

/** Fails the build if a budgeted file exceeds the raw/gzip limits. */
export function checkBudget(rows, budgetedNames, errors) {
	for (const row of rows) {
		if (!budgetedNames.has(row.name)) continue;
		if (row.raw > RAW_BUDGET) {
			errors.push(
				`${row.name}: raw size ${(row.raw / 1e6).toFixed(2)}MB exceeds ${RAW_BUDGET / 1e6}MB budget`
			);
		}
		if (row.gzip > GZIP_BUDGET) {
			errors.push(
				`${row.name}: gzip size ${(row.gzip / 1e6).toFixed(2)}MB exceeds ${GZIP_BUDGET / 1e6}MB budget`
			);
		}
	}
}

export function printSizeTable(rows) {
	const nameWidth = Math.max(4, ...rows.map((r) => r.name.length));
	console.log('');
	console.log(`${'file'.padEnd(nameWidth)}  ${'raw'.padStart(10)}  ${'gzip'.padStart(10)}`);
	for (const row of rows) {
		console.log(
			`${row.name.padEnd(nameWidth)}  ${fmtBytes(row.raw).padStart(10)}  ${fmtBytes(row.gzip).padStart(10)}`
		);
	}
	console.log('');
}

function fmtBytes(n) {
	return `${(n / 1024).toFixed(1)} KB`;
}
