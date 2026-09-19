// Measure actual encoded bodies through the production proxy at 1.6 Mbps.
// node scripts/perf/api.mjs --out /tmp/api-after.json
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { createHash } from 'node:crypto';
import { gunzipSync } from 'node:zlib';

const run = promisify(execFile);
const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i], process.argv[i + 1]);
const base = args.get('--url') ?? 'http://localhost:8180';
const output = args.get('--out') ?? '/tmp/matrixwhale-api.json';
const rate = Number(args.get('--bytes-per-second') ?? 200000);
const encoding = args.get('--encoding') ?? 'gzip';
const endpoints = {
	hazards: '/api/v1/hazards/recent?types=TC%2CFL%2CVO%2CWF%2CDR%2CTS&levels=green%2Corange%2Cred',
	alerts: '/api/v1/alerts/active',
	sources: '/api/v1/sources'
};
const dir = await mkdtemp(join(tmpdir(), 'matrixwhale-api-'));
const results = {};
try {
	for (const [name, path] of Object.entries(endpoints)) {
		const bodyPath = join(dir, `${name}.body`);
		const headersPath = join(dir, `${name}.headers`);
		const { stdout } = await run('curl', [
			'--max-time',
			'120',
			'--limit-rate',
			String(rate),
			'-sS',
			'--fail',
			'-H',
			`Accept-Encoding: ${encoding}`,
			'-D',
			headersPath,
			'-o',
			bodyPath,
			'-w',
			'%{json}',
			new URL(path, base).href
		]);
		const metrics = JSON.parse(stdout);
		const headers = await readFile(headersPath, 'utf8');
		const body = await readFile(bodyPath);
		const compressed = /^content-encoding:\s*gzip\s*$/im.test(headers);
		const decoded = compressed ? gunzipSync(body) : body;
		const json = JSON.parse(decoded.toString());
		results[name] = {
			url: new URL(path, base).href,
			status: metrics.http_code,
			encoding: compressed ? 'gzip' : 'identity',
			transferBytes: metrics.size_download,
			decodedBytes: decoded.length,
			timeToFirstByteSeconds: metrics.time_starttransfer,
			totalSeconds: metrics.time_total,
			decodedSha256: createHash('sha256').update(decoded).digest('hex'),
			recordCount: Array.isArray(json) ? json.length : (json.hazards ?? json.sources)?.length,
			headers
		};
		console.log(JSON.stringify({ name, ...results[name] }));
	}
	await mkdir(dirname(output), { recursive: true });
	await writeFile(
		output,
		JSON.stringify(
			{
				measuredAt: new Date().toISOString(),
				bytesPerSecond: rate,
				requestedEncoding: encoding,
				results
			},
			null,
			2
		) + '\n'
	);
} finally {
	await rm(dir, { recursive: true, force: true });
}
