import fs from 'node:fs';
import path from 'node:path';
import mapshaper from 'mapshaper';
import { fixAntimeridian } from './antimeridian.mjs';

function runMapshaper(cmd, input) {
	return new Promise((resolve, reject) => {
		mapshaper.applyCommands(cmd, input, (err, output) => (err ? reject(err) : resolve(output)));
	});
}

export function readShapefileParts(shpPath) {
	const dir = path.dirname(shpPath);
	const base = path.basename(shpPath, path.extname(shpPath));
	const input = {};
	for (const f of fs.readdirSync(dir)) {
		if (f.startsWith(base + '.')) input[f] = fs.readFileSync(path.join(dir, f));
	}
	return { input, shpName: path.basename(shpPath), base };
}

function assertGeographicCrs(input, base) {
	const prjBuf = input[`${base}.prj`];
	if (!prjBuf) throw new Error(`missing .prj for ${base}`);
	const prj = prjBuf.toString('utf8');
	if (!/^GEOGCS/i.test(prj)) {
		throw new Error(`expected a geographic (lat/lon) CRS for ${base}, got: ${prj.slice(0, 120)}`);
	}
	if (!/North_American_1983|NAD83|WGS_1984|WGS84/i.test(prj)) {
		throw new Error(`expected NAD83 or WGS84 datum for ${base}, got: ${prj.slice(0, 120)}`);
	}
}

const PROPERTY_KEY_ORDER = ['cwa', 'name', 'ugc'];

function orderedProperties(props) {
	const out = {};
	for (const key of PROPERTY_KEY_ORDER) out[key] = props[key];
	return out;
}

function geometryBbox(geometry) {
	let minLon = Infinity;
	let maxLon = -Infinity;
	let minLat = Infinity;
	let maxLat = -Infinity;
	const depth = geometry.type === 'Polygon' ? 2 : 3;
	(function walk(coords, d) {
		if (d === 0) {
			minLon = Math.min(minLon, coords[0]);
			maxLon = Math.max(maxLon, coords[0]);
			minLat = Math.min(minLat, coords[1]);
			maxLat = Math.max(maxLat, coords[1]);
			return;
		}
		for (const c of coords) walk(c, d - 1);
	})(geometry.coordinates, depth);
	return { minLon, maxLon, minLat, maxLat };
}

/**
 * A few NWS zones (the same ones affected by antimeridian wraparound) ship a
 * published LON/LAT centroid that lands hundreds of miles away — an artifact
 * of averaging vertex longitudes across the dateline upstream. Detect this by
 * checking the point against the (already antimeridian-fixed) geometry's own
 * bbox, trying +-360 wraps since the fixed geometry may now sit outside
 * [-180, 180]. Falls back to the bbox center, which is at least inside the
 * zone, when the published point is clearly wrong.
 */
function resolveCentroid(lon, lat, geometry) {
	const bbox = geometryBbox(geometry);
	const margin = 2; // degrees
	const withinLat = lat >= bbox.minLat - margin && lat <= bbox.maxLat + margin;
	const withinLon = [lon, lon + 360, lon - 360].some(
		(c) => c >= bbox.minLon - margin && c <= bbox.maxLon + margin
	);
	if (withinLat && withinLon) return { lon, lat, corrected: false };

	let fallbackLon = (bbox.minLon + bbox.maxLon) / 2;
	if (fallbackLon > 180) fallbackLon -= 360;
	if (fallbackLon < -180) fallbackLon += 360;
	return { lon: fallbackLon, lat: (bbox.minLat + bbox.maxLat) / 2, corrected: true };
}

/**
 * Converts one NWS zone shapefile into a dissolved, simplified GeoJSON
 * FeatureCollection (properties: ugc/name/cwa) plus a centroid list, using
 * the shapefile's own LON/LAT attributes.
 *
 * @param {object} opts
 * @param {string} opts.shpPath
 * @param {(raw: Record<string, any>) => {ugc: string, name: string, cwa: string, lon: number, lat: number}} opts.mapProperties
 * @param {number} [opts.simplifyPct]
 * @param {number} [opts.precision]
 */
export async function buildZoneLayer({
	shpPath,
	mapProperties,
	simplifyPct = 8,
	precision = 0.0001
}) {
	const { input, shpName, base } = readShapefileParts(shpPath);
	assertGeographicCrs(input, base);

	const rawOutput = await runMapshaper(
		`-i ${shpName} encoding=utf8 -o raw.geojson format=geojson`,
		input
	);
	const rawFc = JSON.parse(rawOutput['raw.geojson'].toString());

	const mappedFeatures = rawFc.features.map((f) => {
		const mapped = mapProperties(f.properties);
		return {
			type: 'Feature',
			geometry: f.geometry,
			properties: {
				ugc: mapped.ugc,
				name: mapped.name,
				cwa: mapped.cwa,
				LON: mapped.lon,
				LAT: mapped.lat
			}
		};
	});

	const dissolveInput = {
		'mapped.geojson': JSON.stringify({ type: 'FeatureCollection', features: mappedFeatures })
	};
	const dissolveCmd = [
		'-i mapped.geojson',
		'-dissolve ugc copy-fields=name,cwa,LON,LAT',
		'-clean',
		`-simplify visvalingam ${simplifyPct}% keep-shapes`,
		`-o out.geojson format=geojson precision=${precision}`
	].join(' ');
	const dissolvedOutput = await runMapshaper(dissolveCmd, dissolveInput);
	const dissolvedFc = JSON.parse(dissolvedOutput['out.geojson'].toString());

	const centroids = [];
	const antimeridianFixes = [];
	const centroidCorrections = [];
	for (const f of dissolvedFc.features) {
		const { fixed, span } = fixAntimeridian(f);
		if (fixed) antimeridianFixes.push({ ugc: f.properties.ugc, span });

		const resolved = resolveCentroid(f.properties.LON, f.properties.LAT, f.geometry);
		if (resolved.corrected) {
			centroidCorrections.push({
				ugc: f.properties.ugc,
				published: [f.properties.LON, f.properties.LAT],
				corrected: [resolved.lon, resolved.lat]
			});
		}
		centroids.push({ ugc: f.properties.ugc, lon: resolved.lon, lat: resolved.lat });
		f.properties = orderedProperties(f.properties);
	}

	dissolvedFc.features.sort((a, b) => (a.properties.ugc < b.properties.ugc ? -1 : 1));

	return {
		featureCollection: dissolvedFc,
		centroids,
		antimeridianFixes,
		centroidCorrections,
		rawRecordCount: rawFc.features.length
	};
}

/**
 * For sources with no polygon output (marineHighSeas): shapefile -> mapped
 * records only, no ugc assigned yet (this source has no natural identifier —
 * callers assign a synthetic ugc after sorting, for determinism).
 */
export async function buildCentroidsOnlyLayer({ shpPath, mapProperties }) {
	const { input, shpName, base } = readShapefileParts(shpPath);
	assertGeographicCrs(input, base);

	const rawOutput = await runMapshaper(
		`-i ${shpName} encoding=utf8 -o raw.geojson format=geojson`,
		input
	);
	const rawFc = JSON.parse(rawOutput['raw.geojson'].toString());

	const records = rawFc.features.map((f) => mapProperties(f.properties));

	return { records, rawRecordCount: rawFc.features.length };
}
