import assert from 'node:assert/strict';
import express from 'express';
import http from 'node:http';
import test from 'node:test';

import sessionsRouter from '@/routes/sessions.js';

// Provide a no-op resolveProjectId so the test never touches the real DB.
function noopResolveProjectId(_cwd: string): string | null {
  return null;
}

function startServer(deps: any) {
  const app = express();
  app.use('/api/sessions', sessionsRouter({ resolveProjectId: noopResolveProjectId, ...deps }));
  return new Promise<{ url: string; close: () => void }>(resolve => {
    const server = http.createServer(app).listen(0, () => {
      const port = (server.address() as any).port;
      resolve({ url: `http://127.0.0.1:${port}`, close: () => server.close() });
    });
  });
}

test('GET /active returns a single live list (SDK active ∪ mtime-recent), deduped by id', async () => {
  const liveMeta = [
    { id: 'sess-a', title: 'A title', project: 'foo', cwd: '/p/foo', mtime: 1000 },
    { id: 'sess-c', title: null,      project: 'bar', cwd: '/p/bar', mtime: 2000 },
  ];
  const lookupMap: Record<string, any> = {
    'sess-a': { id: 'sess-a', title: 'A title', project: 'foo', cwd: '/p/foo', mtime: 1000 },
    'sess-b': { id: 'sess-b', title: 'B title', project: 'baz', cwd: '/p/baz', mtime: 3000 },
  };

  const { url, close } = await startServer({
    getRunningIds: () => ['sess-a', 'sess-b'],
    getLiveMeta: async () => liveMeta,
    lookupSessionMeta: async (id: string) => lookupMap[id] ?? null,
    windowMin: 5,
  });
  try {
    const res = await fetch(`${url}/api/sessions/active`);
    assert.equal(res.status, 200);
    const body = await res.json() as {
      live: Array<{ id: string; title: string | null; project: string | null; cwd: string | null; projectId: string | null }>;
      windowMin: number;
    };

    // SDK-active sessions come first (sess-a, sess-b), then mtime-only (sess-c)
    assert.equal(body.live.length, 3);
    assert.equal(body.live[0].id, 'sess-a');
    assert.equal(body.live[1].id, 'sess-b');
    assert.equal(body.live[2].id, 'sess-c');
    assert.equal(body.live.find(s => s.id === 'sess-b')!.title, 'B title');
    // projectId is null because noopResolveProjectId always returns null
    assert.equal(body.live.find(s => s.id === 'sess-b')!.projectId, null);

    // sess-a was in both SDK set and liveMeta — appears only once
    assert.equal(body.live.filter(s => s.id === 'sess-a').length, 1);
    assert.equal(body.windowMin, 5);
  } finally {
    close();
  }
});

test('GET /active resolves projectId via injected resolver', async () => {
  const liveMeta = [
    { id: 'sess-x', title: 'X', project: 'myproj', cwd: '/home/user/myproj', mtime: 5000 },
  ];
  const projectIdMap: Record<string, string> = {
    '/home/user/myproj': 'proj-uuid-123',
  };

  const { url, close } = await startServer({
    getRunningIds: () => [],
    getLiveMeta: async () => liveMeta,
    lookupSessionMeta: async () => null,
    windowMin: 5,
    resolveProjectId: (cwd: string) => projectIdMap[cwd] ?? null,
  });
  try {
    const res = await fetch(`${url}/api/sessions/active`);
    const body = await res.json() as { live: any[] };
    assert.equal(body.live[0].projectId, 'proj-uuid-123');
  } finally {
    close();
  }
});

test('GET /active falls back to minimal meta when lookup misses', async () => {
  const { url, close } = await startServer({
    getRunningIds: () => ['unknown-id'],
    getLiveMeta: async () => [],
    lookupSessionMeta: async () => null,
    windowMin: 5,
  });
  try {
    const res = await fetch(`${url}/api/sessions/active`);
    const body = await res.json() as { live: any[] };
    assert.equal(body.live.length, 1);
    assert.equal(body.live[0].id, 'unknown-id');
    assert.equal(body.live[0].title, null);
    assert.equal(body.live[0].project, null);
    assert.equal(body.live[0].projectId, null);
  } finally {
    close();
  }
});
