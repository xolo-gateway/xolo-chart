// Open-loop load spread over several organizations, one token each, so the
// budget counters of a single organization (rows every one of its requests
// updates, xolo#223) do not cap the measure. Same metric names as xolo-chaos's
// profile.js, which k6.sh analyzes.
//
//   TARGETS="token@org,token@org" MODEL=chaos-fast RATE=200 DURATION=45s
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const BASE_URL = __ENV.XOLO_URL || 'http://xolo:3002';
const MODEL = __ENV.MODEL || 'chaos-fast';
const RATE = Number(__ENV.RATE || 20);
const DURATION = __ENV.DURATION || '30s';
const STREAM = (__ENV.STREAM || 'true') === 'true';
const TARGETS = (__ENV.TARGETS || 'xolo-e2e-alice-acme@acme').split(',').map((t) => {
  const [token, org] = t.split('@');
  return { token, org };
});

const ttft = new Trend('llm_ttft', true);
const e2e = new Trend('llm_duration', true);

export const options = {
  scenarios: {
    load: {
      executor: 'constant-arrival-rate',
      rate: RATE, timeUnit: '1s', duration: DURATION,
      preAllocatedVUs: RATE * 10, maxVUs: RATE * 100,
    },
  },
  thresholds: { dropped_iterations: ['count>=0'] },
};

export default function () {
  const target = TARGETS[Math.floor(Math.random() * TARGETS.length)];
  const res = http.post(`${BASE_URL}/api/v1/chat/completions`, JSON.stringify({
    model: `${target.org}/${MODEL}`,
    stream: STREAM,
    messages: [{ role: 'user', content: 'Suggest a load test plan for an HTTP gateway.' }],
  }), {
    headers: { Authorization: `Bearer ${target.token}`, 'Content-Type': 'application/json' },
    timeout: '120s',
    tags: { org: target.org },
    responseCallback: http.expectedStatuses({ min: 200, max: 599 }),
  });
  ttft.add(res.timings.waiting);
  e2e.add(res.timings.duration);
  check(res, {
    'status 200': (r) => r.status === 200,
    'body complete': (r) => r.status !== 200 || (STREAM ? r.body.includes('[DONE]') : r.body.includes('"choices"')),
  });
}
