import assert from 'node:assert/strict';
import express from 'express';
import http from 'node:http';
import test from 'node:test';

import createUsageRouter from '@/routes/usage.js';

function startServer(deps: { summarize: () => Promise<any> }) {
  const app = express();
  app.use('/api/usage', createUsageRouter(deps));
  return new Promise<{ url: string; close: () => void }>(resolve => {
    const server = http.createServer(app).listen(0, () => {
      const port = (server.address() as any).port;
      resolve({ url: `http://127.0.0.1:${port}`, close: () => server.close() });
    });
  });
}

const fakeSummary = {
  asOf: 1_700_000_000_000,
  fiveHour: {
    input: 1000, output: 500, cacheCreation: 200, cacheRead: 100,
    total: 1800, costUsd: 0.05,
    byModel: { 'claude-opus-4-7[1m]': { input: 1000, output: 500, cacheCreation: 200, cacheRead: 100, costUsd: 0.05 } },
  },
  week: {
    input: 5000, output: 2000, cacheCreation: 400, cacheRead: 300,
    total: 7700, costUsd: 0.25,
    byModel: { 'claude-opus-4-7[1m]': { input: 5000, output: 2000, cacheCreation: 400, cacheRead: 300, costUsd: 0.25 } },
  },
};

test('GET /summary returns the summarize dependency output verbatim', async () => {
  const { url, close } = await startServer({
    summarize: async () => fakeSummary,
  });
  try {
    const res = await fetch(`${url}/api/usage/summary`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body, fakeSummary);
  } finally {
    close();
  }
});

test('GET /summary returns 500 when summarize throws', async () => {
  const { url, close } = await startServer({
    summarize: async () => { throw new Error('disk error'); },
  });
  try {
    const res = await fetch(`${url}/api/usage/summary`);
    assert.equal(res.status, 500);
    const body = await res.json() as { error: string };
    assert.equal(body.error, 'disk error');
  } finally {
    close();
  }
});
