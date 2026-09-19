import http from 'k6/http';
import { Trend, Rate } from 'k6/metrics';
import exec from 'k6/execution';

const BASE_URL = __ENV.BASE_URL || 'http://matrix_whale:8080';
const RESULT_FILE = __ENV.RESULT_FILE || 'perf/results/summary.json';
const RATE = Number(__ENV.RATE || 1);

// Endpoint identifiers
const ENDPOINT_ALERTS = 'alerts_active';
const ENDPOINT_QUAKES = 'earthquakes_recent';
const ENDPOINT_HAZARDS = 'hazards_recent';
const ENDPOINT_TIMELINE1 = 'timeline_page1';
const ENDPOINT_TIMELINE2 = 'timeline_page2';

const ENDPOINTS = [
  ENDPOINT_ALERTS,
  ENDPOINT_QUAKES,
  ENDPOINT_HAZARDS,
  ENDPOINT_TIMELINE1,
  ENDPOINT_TIMELINE2,
];

// Per-endpoint custom metrics (populated only in the measured phase)
const endpointTrends = {};
const endpointErrorRates = {};

for (const ep of ENDPOINTS) {
  endpointTrends[ep] = new Trend(`lat_${ep}`, true);
  endpointErrorRates[ep] = new Rate(`err_${ep}`);
}

// Single custom Rate metric for the threshold: measured error rate < 1%
const measuredErrorRate = new Rate('measured_error_rate');

// Build scenarios object dynamically
const scenarios = {};
for (const ep of ENDPOINTS) {
  scenarios[`warmup_${ep}`] = {
    executor: 'constant-arrival-rate',
    rate: RATE,
    timeUnit: '1s',
    duration: '10s',
    preAllocatedVUs: 5,
    maxVUs: 50,
    tags: { phase: 'warmup', endpoint: ep },
    exec: ep,
  };
  scenarios[`measured_${ep}`] = {
    executor: 'constant-arrival-rate',
    rate: RATE,
    timeUnit: '1s',
    startTime: '10s',
    duration: '60s',
    preAllocatedVUs: 5,
    maxVUs: 50,
    tags: { phase: 'measured', endpoint: ep },
    exec: ep,
  };
}

export const options = {
  summaryTrendStats: ['count', 'avg', 'min', 'med', 'max', 'p(50)', 'p(95)', 'p(99)'],
  scenarios,
  thresholds: {
    measured_error_rate: ['rate<0.01'],
  },
};

function recordSample(epName, res, isMeasured) {
  if (!isMeasured) return;
  const isErr = res.status < 200 || res.status >= 400;
  endpointTrends[epName].add(res.timings.duration);
  endpointErrorRates[epName].add(isErr ? 1 : 0);
  measuredErrorRate.add(isErr ? 1 : 0);
}

// Exported scenario functions per endpoint
export function alerts_active() {
  const isMeasured = exec.scenario.name.startsWith('measured_');
  const res = http.get(`${BASE_URL}/api/v1/alerts/active`, {
    tags: { endpoint: ENDPOINT_ALERTS },
  });
  recordSample(ENDPOINT_ALERTS, res, isMeasured);
}

export function earthquakes_recent() {
  const isMeasured = exec.scenario.name.startsWith('measured_');
  const res = http.get(`${BASE_URL}/api/v1/earthquakes/recent`, {
    tags: { endpoint: ENDPOINT_QUAKES },
  });
  recordSample(ENDPOINT_QUAKES, res, isMeasured);
}

export function hazards_recent() {
  const isMeasured = exec.scenario.name.startsWith('measured_');
  const res = http.get(`${BASE_URL}/api/v1/hazards/recent`, {
    tags: { endpoint: ENDPOINT_HAZARDS },
  });
  recordSample(ENDPOINT_HAZARDS, res, isMeasured);
}

export function timeline_page1() {
  const isMeasured = exec.scenario.name.startsWith('measured_');
  const res = http.get(`${BASE_URL}/api/v1/timeline`, {
    tags: { endpoint: ENDPOINT_TIMELINE1 },
  });
  recordSample(ENDPOINT_TIMELINE1, res, isMeasured);
}

export function timeline_page2() {
  const isMeasured = exec.scenario.name.startsWith('measured_');

  // Fetch page 1 untracked to obtain cursor
  const res1 = http.get(`${BASE_URL}/api/v1/timeline`);
  if (res1.status !== 200) return;

  let nextCursor = null;
  try {
    const parsed = res1.json();
    if (parsed && typeof parsed.next_cursor === 'string' && parsed.next_cursor.length > 0) {
      nextCursor = parsed.next_cursor;
    }
  } catch (e) {}

  if (!nextCursor) return;

  const res2 = http.get(
    `${BASE_URL}/api/v1/timeline?before=${encodeURIComponent(nextCursor)}`,
    { tags: { endpoint: ENDPOINT_TIMELINE2 } }
  );
  recordSample(ENDPOINT_TIMELINE2, res2, isMeasured);
}

function round2(num) {
  return typeof num === 'number' && !isNaN(num) ? Math.round(num * 100) / 100 : 0;
}

function round4(num) {
  return typeof num === 'number' && !isNaN(num) ? Math.round(num * 10000) / 10000 : 0;
}

export function handleSummary(data) {
  const dropped =
    data.metrics.dropped_iterations && data.metrics.dropped_iterations.values
      ? (data.metrics.dropped_iterations.values.count || 0)
      : 0;

  const meta = {
    git_sha: __ENV.GIT_SHA || '',
    git_dirty: __ENV.GIT_DIRTY === 'true',
    started_at: __ENV.STARTED_AT || new Date().toISOString(),
    loadavg: __ENV.LOADAVG || '',
    rate: RATE,
    dropped_iterations: dropped,
  };

  const endpoints = {};
  for (const ep of ENDPOINTS) {
    const trend = data.metrics[`lat_${ep}`];
    const tVals = trend && trend.values ? trend.values : {};
    const errRate = data.metrics[`err_${ep}`];
    const eVals = errRate && errRate.values ? errRate.values : {};

    const p50 = tVals['p(50)'] !== undefined ? tVals['p(50)'] : (tVals.med !== undefined ? tVals.med : 0);
    const p95 = tVals['p(95)'] !== undefined ? tVals['p(95)'] : 0;
    const p99 = tVals['p(99)'] !== undefined ? tVals['p(99)'] : 0;
    const err = eVals.rate !== undefined ? eVals.rate : 0;

    endpoints[ep] = {
      count: tVals.count || 0,
      p50: round2(p50),
      p95: round2(p95),
      p99: round2(p99),
      error_rate: round4(err),
    };
  }

  const resultObj = { meta, endpoints };

  // Text table for stdout
  let textTable = '\n';
  textTable += '================================================================================\n';
  textTable += `MatrixWhale Load Test Summary\n`;
  textTable += `Git: ${meta.git_sha} (dirty: ${meta.git_dirty}) | Started: ${meta.started_at} | Load: ${meta.loadavg} | Rate: ${meta.rate}/s | Dropped: ${meta.dropped_iterations}\n`;
  textTable += '--------------------------------------------------------------------------------\n';
  textTable += 'Endpoint             Count    p50 (ms)    p95 (ms)    p99 (ms)    Error Rate\n';
  textTable += '--------------------------------------------------------------------------------\n';
  for (const ep of ENDPOINTS) {
    const stats = endpoints[ep];
    const epPad = (ep + '                    ').slice(0, 20);
    const cntPad = (String(stats.count) + '         ').slice(0, 9);
    const p50Pad = (stats.p50.toFixed(2) + '            ').slice(0, 12);
    const p95Pad = (stats.p95.toFixed(2) + '            ').slice(0, 12);
    const p99Pad = (stats.p99.toFixed(2) + '            ').slice(0, 12);
    const errPad = (stats.error_rate * 100).toFixed(2) + '%';
    textTable += `${epPad} ${cntPad} ${p50Pad} ${p95Pad} ${p99Pad} ${errPad}\n`;
  }
  textTable += '================================================================================\n';

  return {
    [RESULT_FILE]: JSON.stringify(resultObj),
    stdout: textTable,
  };
}
