const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');

const source = readFileSync('LLMUsageWidget/App/Sources/App/Scraper.swift', 'utf8');
const script = source.match(/private static let claudeCaptureScript = """\n([\s\S]*?)\n    """/)[1];
const captureUsage = eval(`(${script})`);

function browserPage({ responses = [], pageStatus = 200, navigationFails = false } = {}) {
  let responseListener;
  const session = { closed: false };
  const usagePage = {
    on(event, listener) {
      assert.equal(event, 'response');
      responseListener = listener;
    },
    async goto() {
      for (const reply of responses) await responseListener(reply);
      if (navigationFails) throw new Error('Navigation timed out');
      return { status: () => pageStatus };
    },
    async waitForTimeout() {},
    async close() { session.closed = true; },
  };
  return {
    context: () => ({ async newPage() { return usagePage; } }),
    session,
  };
}

function usageResponse({ status = 200, path = '/api/organizations/example/usage', invalidJSON = false } = {}) {
  return {
    url: () => `https://claude.ai${path}`,
    status: () => status,
    async json() {
      if (invalidJSON) throw new Error('Invalid JSON');
      return { seven_day: { utilization: 100 } };
    },
  };
}

async function captureResult(options) {
  const page = browserPage(options);
  const result = JSON.parse(await captureUsage(page));
  assert.equal(page.session.closed, true);
  return result;
}

test('captures weekly usage', async () => {
  assert.deepEqual(await captureResult({ responses: [usageResponse()] }), {
    usage: { seven_day: { utilization: 100 } },
  });
});

test('reports an HTTP failure from the usage endpoint', async () => {
  assert.deepEqual(await captureResult({ responses: [usageResponse({ status: 403 })] }), {
    issue: 'Claude usage returned HTTP 403',
  });
});

test('reports an HTTP failure from the page', async () => {
  assert.deepEqual(await captureResult({ pageStatus: 403 }), {
    issue: 'Claude page returned HTTP 403',
  });
});

test('reports no usage response without claiming a block', async () => {
  assert.deepEqual(await captureResult(), { issue: 'No Claude usage response' });
});

test('reports a response that is not JSON', async () => {
  assert.deepEqual(await captureResult({ responses: [usageResponse({ invalidJSON: true })] }), {
    issue: 'Claude usage response was not JSON',
  });
});

test('reports a navigation failure', async () => {
  assert.deepEqual(await captureResult({ navigationFails: true }), {
    issue: 'Claude page did not load',
  });
});

test('keeps usage that arrives before navigation times out', async () => {
  assert.deepEqual(await captureResult({ responses: [usageResponse()], navigationFails: true }), {
    usage: { seven_day: { utilization: 100 } },
  });
});

test('ignores other endpoints with the usage prefix', async () => {
  assert.deepEqual(await captureResult({
    responses: [usageResponse({ path: '/api/organizations/example/usage/history' })],
  }), { issue: 'No Claude usage response' });
});
