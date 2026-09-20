// Summarize HAR metadata without dumping response bodies or sensitive headers.
// node scripts/perf/har.mjs ../../localhost.har > /tmp/har-summary.json
import { readFile } from 'node:fs/promises';

const har = JSON.parse(await readFile(process.argv[2], 'utf8'));
const entries = har.log.entries;
const start = Math.min(...entries.map((entry) => Date.parse(entry.startedDateTime)));
const rows = entries.map((entry) => {
	const response = entry.response;
	const url = new URL(entry.request.url);
	const headers = Object.fromEntries(
		response.headers.map(({ name, value }) => [name.toLowerCase(), value])
	);
	const events = {};
	for (const event of entry._eventSourceMessages ?? []) {
		events[event.eventName] = (events[event.eventName] ?? 0) + 1;
	}
	return {
		path: url.pathname + url.search,
		startMs: Date.parse(entry.startedDateTime) - start,
		status: response.status,
		protocol: response.httpVersion,
		priority: entry._priority,
		connection: entry._connectionId,
		type: entry._resourceType,
		durationMs: entry.time,
		blockedMs: entry.timings.blocked,
		waitMs: entry.timings.wait,
		receiveMs: entry.timings.receive,
		transferBytes: response._transferSize,
		bodyBytes: response.bodySize,
		decodedBytes: response.content.size,
		encoding: headers['content-encoding'] ?? 'identity',
		events
	};
});
const sum = (items) => items.reduce((n, row) => n + Math.max(0, row.transferBytes ?? 0), 0);
const streams = rows.filter((row) => row.type === 'eventsource');
console.log(
	JSON.stringify(
		{
			entries: rows.length,
			totalTransferBytes: sum(rows),
			streamTransferBytes: sum(streams),
			note: 'SSE duration is observation time, not request completion latency. HAR may omit SSE payload text.',
			streams,
			mostBlocked: [...rows].sort((a, b) => b.blockedMs - a.blockedMs).slice(0, 10),
			largest: [...rows]
				.sort((a, b) => (b.transferBytes ?? 0) - (a.transferBytes ?? 0))
				.slice(0, 10)
		},
		null,
		2
	)
);
