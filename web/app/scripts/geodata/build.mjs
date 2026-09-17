// To bump an NWS shapefile release: edit the `url`/`version` in versions.mjs,
// set that source's `sha256` to null, run this once, then paste the printed
// sha256 back into versions.mjs so future runs assert against it.

import fs from 'node:fs';
import path from 'node:path';
import mapshaper from 'mapshaper';
import {
	SOURCES,
	LAKE_SOURCES,
	NATURAL_EARTH_VERSION,
	CENTROIDS_FILE,
	MANIFEST_FILE
} from './versions.mjs';
import { downloadAndExtract, findShapefile } from './lib/download.mjs';
import {
	buildZoneLayer,
	buildCentroidsOnlyLayer,
	readShapefileParts
} from './lib/zone-pipeline.mjs';
import { buildCentroidDict } from './lib/centroids.mjs';
import { validatePolygonLayer, sizeReport, checkBudget, printSizeTable } from './lib/validate.mjs';

const APP_ROOT = path.resolve(import.meta.dirname, '..', '..');
const CACHE_DIR = path.join(APP_ROOT, '.geodata-cache');
const DATA_DIR = path.join(APP_ROOT, 'static', 'data');

fs.mkdirSync(DATA_DIR, { recursive: true });

function writeJson(filename, obj, { pretty = false } = {}) {
	const filePath = path.join(DATA_DIR, filename);
	fs.writeFileSync(filePath, pretty ? JSON.stringify(obj, null, 2) : JSON.stringify(obj));
	return filePath;
}

function runMapshaper(cmd, input) {
	return new Promise((resolve, reject) => {
		mapshaper.applyCommands(cmd, input, (err, output) => (err ? reject(err) : resolve(output)));
	});
}

async function buildLandLayer(inputFile, outputFilename, { lakesKey, extraSimplify } = {}) {
	const lakes = LAKE_SOURCES[lakesKey];
	const { extractDir, sha256 } = await downloadAndExtract({
		key: lakesKey,
		url: lakes.url,
		sha256: lakes.sha256,
		cacheDir: CACHE_DIR
	});
	const lakeParts = readShapefileParts(findShapefile(extractDir));

	const srcPath = path.join(APP_ROOT, 'node_modules', 'world-atlas', inputFile);
	const input = { [inputFile]: fs.readFileSync(srcPath), ...lakeParts.input };
	const simplify = extraSimplify ? `-simplify visvalingam ${extraSimplify}% keep-shapes ` : '';
	const cmd =
		`-i ${inputFile} name=land ` +
		simplify +
		`-i ${lakeParts.shpName} name=lakes ` +
		'-target land -erase lakes -clean ' +
		'-o out.geojson format=geojson geojson-type=FeatureCollection no-null-props precision=0.0001';
	const output = await runMapshaper(cmd, input);
	const fc = JSON.parse(output['out.geojson'].toString());
	return {
		filePath: writeJson(outputFilename, fc),
		manifestSource: { key: lakesKey, version: lakes.version, url: lakes.url, sha256 }
	};
}

function mapForecastZone(raw) {
	return {
		ugc: raw.STATE + 'Z' + raw.ZONE,
		name: raw.NAME,
		cwa: raw.CWA,
		lon: raw.LON,
		lat: raw.LAT
	};
}

function mapCounty(raw) {
	const fips = String(raw.FIPS);
	if (fips.length !== 3 && fips.length !== 5) {
		throw new Error(`counties: unexpected FIPS length for "${raw.COUNTYNAME}": "${fips}"`);
	}
	const fips3 = fips.length === 5 ? fips.slice(-3) : fips;
	return {
		ugc: raw.STATE + 'C' + fips3,
		name: raw.COUNTYNAME,
		cwa: raw.CWA,
		lon: raw.LON,
		lat: raw.LAT
	};
}

function mapMarine(raw) {
	return { ugc: raw.ID, name: raw.NAME, cwa: raw.WFO, lon: raw.LON, lat: raw.LAT };
}

function mapHighSeas(raw) {
	return { name: raw.NAME, cwa: raw.WFO, lon: raw.LON, lat: raw.LAT };
}

// forecastZones/counties need a much more aggressive simplify % than the
// spec's starting point (8%) to fit the 3MB raw / 1MB gzip size budget.
const ZONE_LAYERS = [
	{ key: 'forecastZones', mapProperties: mapForecastZone, simplifyPct: 3 },
	{ key: 'counties', mapProperties: mapCounty, simplifyPct: 3 },
	{ key: 'marineCoastal', mapProperties: mapMarine, simplifyPct: 8 },
	{ key: 'marineOffshore', mapProperties: mapMarine, simplifyPct: 8 }
];

async function main() {
	const errors = [];
	const manifestSources = [];
	const allCentroidEntries = [];
	const outputFiles = [];

	for (const { key, mapProperties, simplifyPct } of ZONE_LAYERS) {
		const source = SOURCES[key];
		const { extractDir, sha256 } = await downloadAndExtract({
			key,
			url: source.url,
			sha256: source.sha256,
			cacheDir: CACHE_DIR
		});
		const shpPath = findShapefile(extractDir);

		const { featureCollection, centroids, antimeridianFixes, centroidCorrections, rawRecordCount } =
			await buildZoneLayer({
				shpPath,
				mapProperties,
				simplifyPct
			});

		if (antimeridianFixes.length > 0) {
			console.log(`[antimeridian] ${key}: re-centered ${antimeridianFixes.length} feature(s):`);
			for (const fix of antimeridianFixes)
				console.log(`  ${fix.ugc}: span now ${fix.span.toFixed(2)}°`);
		}

		if (centroidCorrections.length > 0) {
			console.log(
				`[centroid] ${key}: ${centroidCorrections.length} published centroid(s) were far outside their zone's geometry; replaced with the zone's bbox center:`
			);
			for (const c of centroidCorrections) {
				console.log(
					`  ${c.ugc}: published [${c.published[0]}, ${c.published[1]}] -> [${c.corrected[0].toFixed(4)}, ${c.corrected[1].toFixed(4)}]`
				);
			}
		}

		const filePath = writeJson(source.outputFile, featureCollection);
		outputFiles.push({ name: source.outputFile, filePath });
		allCentroidEntries.push(...centroids);
		manifestSources.push({
			key,
			version: source.version,
			url: source.url,
			sha256,
			records: rawRecordCount
		});

		console.log(
			`[build] ${key}: ${rawRecordCount} raw records -> ${featureCollection.features.length} zones -> ${source.outputFile}`
		);
	}

	// marineHighSeas: centroids only, no polygon output, no natural ugc in the source data
	{
		const source = SOURCES.marineHighSeas;
		const { extractDir, sha256 } = await downloadAndExtract({
			key: 'marineHighSeas',
			url: source.url,
			sha256: source.sha256,
			cacheDir: CACHE_DIR
		});
		const shpPath = findShapefile(extractDir);
		const { records, rawRecordCount } = await buildCentroidsOnlyLayer({
			shpPath,
			mapProperties: mapHighSeas
		});

		const sorted = [...records].sort((a, b) => (a.name < b.name ? -1 : 1));
		const synthetic = sorted.map((r, i) => ({
			ugc: `HSZ${String(i + 1).padStart(3, '0')}`,
			lon: r.lon,
			lat: r.lat
		}));
		allCentroidEntries.push(...synthetic);
		manifestSources.push({
			key: 'marineHighSeas',
			version: source.version,
			url: source.url,
			sha256,
			records: rawRecordCount
		});

		console.log(
			`[build] marineHighSeas: ${rawRecordCount} raw records -> ${synthetic.length} synthetic centroids (no natural ugc in source; see report)`
		);
	}

	const centroidDict = buildCentroidDict(allCentroidEntries);
	const centroidsPath = writeJson(CENTROIDS_FILE, centroidDict, { pretty: true });
	outputFiles.push({ name: CENTROIDS_FILE, filePath: centroidsPath });

	// Re-validate the polygon layers now that the full centroid dict exists.
	for (const { name, filePath } of outputFiles) {
		if (!name.startsWith('nws-')) continue;
		const fc = JSON.parse(fs.readFileSync(filePath, 'utf8'));
		validatePolygonLayer(name, fc, centroidDict, errors);
	}

	const land50 = await buildLandLayer('land-50m.json', 'land-coast-ne50m-v5.1.1.json', {
		lakesKey: 'lakes50m',
		extraSimplify: 95
	});
	const land110 = await buildLandLayer('land-110m.json', 'land-coast-ne110m-v5.1.1.json', {
		lakesKey: 'lakes110m'
	});
	outputFiles.push({ name: 'land-coast-ne50m-v5.1.1.json', filePath: land50.filePath });
	outputFiles.push({ name: 'land-coast-ne110m-v5.1.1.json', filePath: land110.filePath });
	manifestSources.push(land50.manifestSource, land110.manifestSource);

	const manifest = {
		generated_at: new Date().toISOString(),
		natural_earth_version: NATURAL_EARTH_VERSION,
		sources: manifestSources,
		licenses: {
			natural_earth: 'Public domain',
			nws: 'US Government work, public domain'
		}
	};
	const manifestPath = writeJson(MANIFEST_FILE, manifest, { pretty: true });
	outputFiles.push({ name: MANIFEST_FILE, filePath: manifestPath });

	const rows = sizeReport(outputFiles);
	printSizeTable(rows);
	checkBudget(
		rows,
		new Set([SOURCES.forecastZones.outputFile, SOURCES.counties.outputFile]),
		errors
	);

	if (errors.length > 0) {
		console.error(`\n[validate] ${errors.length} error(s):`);
		for (const e of errors) console.error(`  - ${e}`);
		process.exitCode = 1;
		return;
	}

	console.log('[validate] all checks passed');
}

main().catch((err) => {
	console.error(err);
	process.exitCode = 1;
});
