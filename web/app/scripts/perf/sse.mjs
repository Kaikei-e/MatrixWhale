// Compare simultaneous legacy and compact SSE events, matched by hub event ID.
// Node >=24. Does not inject events or modify the database.
// node scripts/perf/sse.mjs --seconds 90 --out /tmp/sse.json
import { isDeepStrictEqual } from 'node:util';
import { writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import { decodeHazard } from '../../src/lib/chart/geometryTransport.ts';

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i], process.argv[i + 1]);
const base = args.get('--url') ?? 'http://localhost:8180';
const output = args.get('--out') ?? '/tmp/matrixwhale-sse.json';
const seconds = Number(args.get('--seconds') ?? 90);
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), seconds * 1000);
const started = performance.now();

async function observe(path, compact) {
	const response = await fetch(new URL(path, base), { signal: controller.signal });
	if (!response.ok || !response.headers.get('content-type')?.startsWith('text/event-stream')) {
		throw new Error(`${path}: invalid SSE response ${response.status}`);
	}
	const result = {
		path,
		headersMs: performance.now() - started,
		firstEventMs: null,
		receivedBytes: 0,
		counts: {},
		records: new Map()
	};
	const decoder = new TextDecoder();
	let buffer = '';
	try {
		for await (const chunk of response.body) {
			result.receivedBytes += chunk.length;
			buffer += decoder.decode(chunk, { stream: true });
			let end;
			while ((end = buffer.indexOf('\n\n')) !== -1) {
				const frame = buffer.slice(0, end);
				buffer = buffer.slice(end + 2);
				let name = 'message';
				let id = '';
				const lines = [];
				for (const line of frame.split('\n')) {
					if (line.startsWith('event:')) name = line.slice(6).trim();
					if (line.startsWith('id:')) id = line.slice(3).trim();
					if (line.startsWith('data:')) lines.push(line.slice(5).replace(/^ /, ''));
				}
				if (!lines.length) continue;
				result.firstEventMs ??= performance.now() - started;
				result.counts[name] = (result.counts[name] ?? 0) + 1;
				if (!(compact ? /^hazards\.(new|update)$/ : /^(new|update)$/).test(name)) continue;
				const data = lines.join('\n');
				result.records.set(id, {
					data: JSON.parse(data),
					bytes: Buffer.byteLength(data),
					frameBytes: Buffer.byteLength(frame + '\n\n')
				});
			}
		}
	} catch (error) {
		if (!controller.signal.aborted) throw error;
	}
	return result;
}

try {
	const [legacy, compact] = await Promise.all([
		observe('/api/v1/hazards/stream', false),
		observe('/api/v1/stream?geometry=polyline', true)
	]);
	const matched = {
		events: 0,
		encodedGeometries: 0,
		legacyPayloadBytes: 0,
		compactPayloadBytes: 0,
		legacyFrameBytes: 0,
		compactFrameBytes: 0
	};
	for (const [id, record] of legacy.records) {
		const encoded = compact.records.get(id);
		if (!encoded) continue;
		if (!isDeepStrictEqual(record.data, decodeHazard(encoded.data)))
			throw new Error(`SSE round-trip mismatch ${id}`);
		matched.events++;
		matched.encodedGeometries += encoded.data.primary_geometry?.encoding === 'polyline' ? 1 : 0;
		matched.legacyPayloadBytes += record.bytes;
		matched.compactPayloadBytes += encoded.bytes;
		matched.legacyFrameBytes += record.frameBytes;
		matched.compactFrameBytes += encoded.frameBytes;
	}
	const report = {
		measuredAt: new Date().toISOString(),
		seconds,
		legacy: { ...legacy, records: legacy.records.size },
		compact: { ...compact, records: compact.records.size },
		matched,
		allMatchedRecordsExactlyEqual: matched.events > 0
	};
	await mkdir(dirname(output), { recursive: true });
	await writeFile(output, JSON.stringify(report, null, 2) + '\n');
	console.log(JSON.stringify(report));
	if (!matched.events)
		throw new Error('No matching live hazard events observed; extend observation window');
} finally {
	clearTimeout(timer);
	controller.abort();
}
