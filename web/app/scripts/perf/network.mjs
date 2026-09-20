// Run against the production proxy, e.g.:
// node scripts/perf/network.mjs --out /tmp/network-before.json --seconds 90
import { chromium } from '@playwright/test';
import { writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i], process.argv[i + 1]);
const url = args.get('--url') ?? 'http://localhost:8180/globe';
const output = args.get('--out') ?? '/tmp/matrixwhale-network.json';
const seconds = Number(args.get('--seconds') ?? 90);
const kbps = Number(args.get('--kbps') ?? 1600);
const latency = Number(args.get('--latency') ?? 150);
const ect = args.get('--ect');
const browser = await chromium.launch({
	args: [
		'--enable-unsafe-swiftshader',
		...(ect ? [`--force-effective-connection-type=${ect}`] : [])
	]
});
try {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const page = await context.newPage();
	const cdp = await context.newCDPSession(page);
	await cdp.send('Network.enable');
	await cdp.send('Network.clearBrowserCache');
	await cdp.send('Network.emulateNetworkConditions', {
		offline: false,
		latency,
		downloadThroughput: (kbps * 1000) / 8,
		uploadThroughput: (750 * 1000) / 8,
		connectionType: 'cellular4g'
	});
	const requests = new Map();
	const pending = new Set();
	const errors = [];
	const cdpRequests = new Map();
	let origin;
	cdp.on('Network.requestWillBeSent', (e) => {
		origin ??= e.timestamp;
		cdpRequests.set(e.requestId, {
			url: e.request.url,
			type: e.type,
			priority: e.request.initialPriority,
			startMs: (e.timestamp - origin) * 1000,
			receivedBytes: 0,
			events: 0,
			eventsByName: {},
			eventPayloadBytes: 0
		});
	});
	cdp.on('Network.responseReceived', (e) => {
		const r = cdpRequests.get(e.requestId);
		if (r)
			Object.assign(r, {
				responseMs: (e.timestamp - origin) * 1000,
				protocol: e.response.protocol,
				connectionId: e.response.connectionId,
				timing: e.response.timing
			});
	});
	cdp.on('Network.loadingFinished', (e) => {
		const r = cdpRequests.get(e.requestId);
		if (r)
			Object.assign(r, {
				finishedMs: (e.timestamp - origin) * 1000,
				completedEncodedBytes: e.encodedDataLength
			});
	});
	cdp.on('Network.dataReceived', (e) => {
		const r = cdpRequests.get(e.requestId);
		if (r) r.receivedBytes += e.encodedDataLength;
	});
	cdp.on('Network.eventSourceMessageReceived', (e) => {
		const r = cdpRequests.get(e.requestId);
		if (r) {
			r.events++;
			r.eventsByName[e.eventName] = (r.eventsByName[e.eventName] ?? 0) + 1;
			r.eventPayloadBytes += Buffer.byteLength(e.data);
			r.firstEventMs ??= (e.timestamp - origin) * 1000;
			r.lastEventMs = (e.timestamp - origin) * 1000;
		}
	});
	context.on('request', (r) =>
		requests.set(r, { url: r.url(), method: r.method(), type: r.resourceType() })
	);
	context.on('response', (r) => {
		const row = requests.get(r.request());
		if (row) {
			row.status = r.status();
			row.headers = r.headers();
		}
	});
	context.on('requestfinished', (r) => {
		const p = (async () => {
			Object.assign(requests.get(r), {
				timing: r.timing(),
				sizes: await r.sizes(),
				finished: true
			});
		})();
		pending.add(p);
		p.catch((error) => errors.push(String(error))).finally(() => pending.delete(p));
	});
	context.on('requestfailed', (r) =>
		Object.assign(requests.get(r), { timing: r.timing(), failure: r.failure() })
	);
	page.on('pageerror', (e) => errors.push(e.message));
	await page.addInitScript(() => {
		window.__networkProbe = { lcp: null, firstPopulatedTabMs: {} };
		new PerformanceObserver((list) => {
			window.__networkProbe.lcp = list.getEntries().at(-1)?.startTime;
		}).observe({ type: 'largest-contentful-paint', buffered: true });
		setInterval(() => {
			for (const tab of document.querySelectorAll('[role="tab"]')) {
				if (
					Number.parseInt(tab.lastElementChild?.textContent ?? '0', 10) > 0 &&
					!window.__networkProbe.firstPopulatedTabMs[tab.id]
				) {
					window.__networkProbe.firstPopulatedTabMs[tab.id] = performance.now();
				}
			}
		}, 100);
	});
	const start = Date.now();
	await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
	while (Date.now() - start < seconds * 1000) {
		await new Promise((resolve) =>
			setTimeout(resolve, Math.min(10000, seconds * 1000 - (Date.now() - start)))
		);
		console.log(
			JSON.stringify({
				elapsedSeconds: Math.round((Date.now() - start) / 1000),
				requests: requests.size
			})
		);
	}
	await Promise.allSettled([...pending]);
	const state = await page.evaluate(() => ({
		...window.__networkProbe,
		paints: performance
			.getEntriesByType('paint')
			.map((p) => ({ name: p.name, startTime: p.startTime })),
		tabs: [...document.querySelectorAll('[role="tab"]')].map((t) => ({
			id: t.id,
			text: t.textContent
		})),
		bodyText: document.body.innerText,
		canvasCount: document.querySelectorAll('canvas').length
	}));
	const report = {
		measuredAt: new Date().toISOString(),
		url,
		seconds,
		kbps,
		latency,
		browser: browser.version(),
		forcedEffectiveConnectionType: ect ?? null,
		state,
		errors,
		requests: [...requests.values()],
		cdpRequests: [...cdpRequests.values()]
	};
	report.streams = report.cdpRequests.filter((r) => r.type === 'EventSource');
	report.streamReceivedBytes = report.streams.reduce((n, r) => n + r.receivedBytes, 0);
	report.mapDataFinishedMs = Math.max(
		0,
		...report.cdpRequests
			.filter((r) => new URL(r.url).pathname.startsWith('/data/'))
			.map((r) => r.finishedMs ?? 0)
	);
	await mkdir(dirname(output), { recursive: true });
	await writeFile(output, JSON.stringify(report, null, 2) + '\n');
	console.log(
		JSON.stringify({
			output,
			state: { ...state, bodyText: undefined },
			errors,
			completedTransferBytes: report.requests.reduce(
				(n, r) => n + (r.sizes?.responseBodySize ?? 0) + (r.sizes?.responseHeadersSize ?? 0),
				0
			)
		})
	);
} finally {
	await browser.close();
}
