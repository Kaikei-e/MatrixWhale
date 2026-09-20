// Isolate browser HTTP/1.1 scheduling with identical data and idle SSE streams.
// node scripts/perf/sse-scheduling.mjs --out /tmp/sse-scheduling.json
import { createServer } from 'node:http';
import { chromium } from '@playwright/test';
import { writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i], process.argv[i + 1]);
const output = args.get('--out') ?? '/tmp/sse-scheduling.json';
const ect = args.get('--ect');
const body = Buffer.alloc(100_000, 'x');
const sockets = new Set();
const server = createServer((request, response) => {
	if (request.url.startsWith('/stream')) {
		response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
		response.write('event: heartbeat\ndata: {}\n\n');
	} else if (request.url.startsWith('/data')) {
		response.writeHead(200, {
			'Content-Type': 'application/octet-stream',
			'Content-Length': body.length
		});
		response.end(body);
	} else {
		response.writeHead(200, { 'Content-Type': 'text/html' });
		response.end('<!doctype html><title>SSE scheduling probe</title>');
	}
});
server.on('connection', (socket) => {
	sockets.add(socket);
	socket.on('close', () => sockets.delete(socket));
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({
	args: ect ? [`--force-effective-connection-type=${ect}`] : []
});
const results = [];
try {
	for (const streams of [3, 1, 3, 1]) {
		const context = await browser.newContext();
		const page = await context.newPage();
		const cdp = await context.newCDPSession(page);
		await cdp.send('Network.enable');
		await cdp.send('Network.emulateNetworkConditions', {
			offline: false,
			latency: 150,
			downloadThroughput: 200_000,
			uploadThroughput: 93_750,
			connectionType: 'cellular4g'
		});
		await page.goto(url);
		const result = await page.evaluate(async (count) => {
			const sources = Array.from({ length: count }, (_, i) => new EventSource(`/stream/${i}`));
			await Promise.all(
				sources.map((source) => new Promise((resolve) => (source.onopen = resolve)))
			);
			const started = performance.now();
			await Promise.all(
				[0, 1].map(async (i) => {
					const response = await fetch(`/data/${i}`, { priority: 'low' });
					await response.arrayBuffer();
				})
			);
			const finishedMs = performance.now() - started;
			const requests = performance
				.getEntriesByType('resource')
				.filter((r) => r.name.includes('/data/'))
				.map((r) => ({
					path: new URL(r.name).pathname,
					queueMs: r.requestStart - r.fetchStart,
					ttfbMs: r.responseStart - r.requestStart,
					durationMs: r.duration,
					transferBytes: r.transferSize,
					protocol: r.nextHopProtocol
				}));
			for (const source of sources) source.close();
			return { effectiveType: navigator.connection?.effectiveType, finishedMs, requests };
		}, streams);
		results.push({ streams, ...result });
		console.log(JSON.stringify(results.at(-1)));
		await context.close();
	}
	await mkdir(dirname(output), { recursive: true });
	await writeFile(
		output,
		JSON.stringify(
			{
				browser: browser.version(),
				forcedEffectiveConnectionType: ect ?? null,
				kbps: 1600,
				latencyMs: 150,
				bodyBytes: body.length,
				results
			},
			null,
			2
		) + '\n'
	);
} finally {
	await browser.close();
	for (const socket of sockets) socket.destroy();
	await new Promise((resolve) => server.close(resolve));
}
