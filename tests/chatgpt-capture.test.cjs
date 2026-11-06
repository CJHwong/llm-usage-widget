const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');

const source = readFileSync('LLMUsageWidget/App/Sources/App/Scraper.swift', 'utf8');
const script = source.match(/private static let usageCaptureScript = """\n([\s\S]*?)\n    """/)[1];
const captureUsage = eval(`(${script})`);

function settingsPage(responses) {
  const listeners = [];
  let acceptResponse;
  let finishResponse;
  return {
    on(event, listener) { listeners.push(listener); },
    async goto(url) {
      assert.equal(url, 'https://chatgpt.com/settings/general-settings');
    },
    waitForResponse(predicate) {
      acceptResponse = predicate;
      return new Promise(resolve => { finishResponse = resolve; });
    },
    getByText(label, options) {
      assert.equal(label, 'Usage');
      assert.deepEqual(options, { exact: true });
      return {
        async click() {
          for (const response of responses) {
            for (const listener of listeners) await listener(response);
            if (acceptResponse?.(response)) finishResponse(response);
          }
          finishResponse?.(null);
        },
      };
    },
    async waitForTimeout() {},
  };
}

function response(path, status, payload) {
  return {
    url: () => `https://chatgpt.com${path}`,
    status: () => status,
    async json() { return payload; },
  };
}

test('opens Usage and captures only the successful usage endpoint', async () => {
  const usage = { rate_limit: { primary_window: { used_percent: 63, limit_window_seconds: 604800 } } };
  const page = settingsPage([
    response('/backend-api/wham/usage', 403, { detail: 'Forbidden' }),
    response('/backend-api/wham/usage/plan_limit_balance_history', 404, { detail: 'Not Found' }),
    response('/backend-api/wham/usage', 200, usage),
    response('/backend-api/wham/usage/plan_limit_history', 200, { history: [] }),
  ]);
  assert.deepEqual(JSON.parse(await captureUsage(page)), usage);
});

test('returns null when Usage returns no successful usage response', async () => {
  assert.equal(await captureUsage(settingsPage([])), 'null');
});
