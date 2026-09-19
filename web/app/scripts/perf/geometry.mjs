// Compare the legacy and compact API on the live proxy, including an exact
// cross-language round trip through the browser's decoder. Node >= 24.
import { execFile } from 'node:child_process';
import { promisify, isDeepStrictEqual } from 'node:util';
import { mkdtemp, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { decodeHazard } from '../../src/lib/chart/geometryTransport.ts';

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i], process.argv[i + 1]);
const base = args.get('--url') ?? 'http://localhost:8180';
const output = args.get('--out') ?? '/tmp/matrixwhale-geometry.json';
const rate = Number(args.get('--bytes-per-second') ?? 200000);
const run = promisify(execFile);
const dir = await mkdtemp(join(tmpdir(), 'matrixwhale-geometry-'));

async function fetchSnapshot(compact) {
	const url = new URL('/api/v1/hazards/recent', base);
	url.searchParams.set('types', 'TC,FL,VO,WF,DR,TS');
	url.searchParams.set('levels', 'green,orange,red');
	if (compact) url.searchParams.set('geometry', 'polyline');
	const file = join(dir, compact ? 'compact' : 'legacy');
	const { stdout } = await run('curl', [
		'--max-time',
		'120',
		'--limit-rate',
		String(rate),
		'-sS',
		'--fail',
		'-H',
		'Accept-Encoding: gzip',
		'-D',
		file + '.headers',
		'-o',
		file,
		'-w',
		'%{json}',
		url.href
	]);
	const metrics = JSON.parse(stdout);
	const headers = await readFile(file + '.headers', 'utf8');
	const body = await readFile(file);
	if (!/^content-encoding:\s*gzip\s*$/im.test(headers)) throw new Error('Expected gzip');
	const expanded = gunzipSync(body);
	const start = performance.now();
	const data = JSON.parse(expanded.toString());
	const parseMs = performance.now() - start;
	return {
		data,
		metrics: {
			transferBytes: metrics.size_download,
			jsonBytes: expanded.length,
			timeToFirstByteSeconds: metrics.time_starttransfer,
			totalSeconds: metrics.time_total,
			parseMs,
			recordCount: data.hazards.length,
			headers
		}
	};
}

function countPositions(coordinates) {
	if (!Array.isArray(coordinates) || coordinates.length === 0) return 0;
	if (typeof coordinates[0] === 'number') return 1;
	return coordinates.reduce((count, part) => count + countPositions(part), 0);
}

try {
	const legacy = await fetchSnapshot(false);
	const compact = await fetchSnapshot(true);
	const start = performance.now();
	const decoded = compact.data.hazards.map(decodeHazard);
	const decodeMs = performance.now() - start;
	const previous = new Map(legacy.data.hazards.map((hazard) => [hazard.id, hazard]));
	let comparedRecords = 0;
	let comparedPositions = 0;
	let changedDuringMeasurement = 0;
	for (const hazard of decoded) {
		const before = previous.get(hazard.id);
		if (
			!before ||
			before.modified_at_ms !== hazard.modified_at_ms ||
			before.last_seen_at !== hazard.last_seen_at
		) {
			changedDuringMeasurement++;
			continue;
		}
		if (!isDeepStrictEqual(before, hazard)) throw new Error(`Round-trip mismatch: ${hazard.id}`);
		comparedRecords++;
		comparedPositions += countPositions(hazard.primary_geometry?.coordinates);
	}
	if (comparedRecords === 0) throw new Error('No unchanged records available to compare');
	const encodedRecords = compact.data.hazards.filter(
		(h) => h.primary_geometry?.encoding === 'polyline'
	).length;
	if (encodedRecords === 0) throw new Error('The server did not return compact geometry');
	const report = {
		measuredAt: new Date().toISOString(),
		bytesPerSecond: rate,
		legacy: legacy.metrics,
		compact: compact.metrics,
		decodeMs,
		encodedRecords,
		comparedRecords,
		comparedPositions,
		changedDuringMeasurement,
		allComparedRecordsExactlyEqual: true
	};
	await mkdir(dirname(output), { recursive: true });
	await writeFile(output, JSON.stringify(report, null, 2) + '\n');
	console.log(JSON.stringify(report));
} finally {
	await rm(dir, { recursive: true, force: true });
}
