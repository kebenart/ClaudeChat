import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { liveSessionsService as recentSessionsService } from '@/services/recent-sessions.service.js';

async function writeJsonl(filePath: string, lines: object[]): Promise<void> {
  await fs.writeFile(filePath, lines.map(o => JSON.stringify(o)).join('\n') + '\n');
}

test('list returns enriched session metadata for recently-touched JSONLs', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'recent-sessions-'));
  try {
    const projDir = path.join(tmp, '-Users-tester-CODE-foo');
    await fs.mkdir(projDir, { recursive: true });

    const freshId = 'aaaa-bbbb-cccc';
    await writeJsonl(path.join(projDir, `${freshId}.jsonl`), [
      { type: 'permission-mode', sessionId: freshId, permissionMode: 'default' },
      { type: 'user', sessionId: freshId, cwd: '/Users/tester/CODE/foo', message: { content: 'hello world' } },
      { type: 'ai-title', sessionId: freshId, aiTitle: 'A clean session title' },
    ]);

    const stale = path.join(projDir, 'old-old-old.jsonl');
    await fs.writeFile(stale, '');
    const oldMtime = new Date(Date.now() - 60 * 60 * 1000);
    await fs.utimes(stale, oldMtime, oldMtime);

    const out = await recentSessionsService.list({ rootDir: tmp, windowMin: 30 });
    assert.equal(out.length, 1);
    assert.equal(out[0].id, freshId);
    assert.equal(out[0].title, 'A clean session title');
    assert.equal(out[0].project, 'foo');
    assert.equal(out[0].cwd, '/Users/tester/CODE/foo');
    assert.ok(out[0].mtime > 0);
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('list falls back to first user message when ai-title is absent', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'recent-sessions-'));
  try {
    const projDir = path.join(tmp, '-Users-x-project');
    await fs.mkdir(projDir, { recursive: true });
    const id = 'no-ai-title';
    await writeJsonl(path.join(projDir, `${id}.jsonl`), [
      { type: 'user', sessionId: id, cwd: '/Users/x/project', message: { content: 'first user prompt' } },
    ]);
    const out = await recentSessionsService.list({ rootDir: tmp, windowMin: 30 });
    assert.equal(out[0].title, 'first user prompt');
    assert.equal(out[0].project, 'project');
    assert.equal(out[0].cwd, '/Users/x/project');
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('list handles array-form message content (text blocks)', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'recent-sessions-'));
  try {
    const projDir = path.join(tmp, '-Users-x-project');
    await fs.mkdir(projDir, { recursive: true });
    const id = 'array-content';
    await writeJsonl(path.join(projDir, `${id}.jsonl`), [
      {
        type: 'user',
        sessionId: id,
        cwd: '/Users/x/project',
        message: { content: [{ type: 'text', text: 'block-form prompt' }] },
      },
    ]);
    const out = await recentSessionsService.list({ rootDir: tmp, windowMin: 30 });
    assert.equal(out[0].title, 'block-form prompt');
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('list returns an empty array when root directory is missing', async () => {
  const out = await recentSessionsService.list({
    rootDir: '/nonexistent/path/that/should/not/exist',
    windowMin: 30,
  });
  assert.deepEqual(out, []);
});

test('lookupById finds a session jsonl by id across project subdirs', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'recent-sessions-'));
  try {
    const projDir = path.join(tmp, '-Users-x-proj');
    await fs.mkdir(projDir, { recursive: true });
    const id = 'lookup-target';
    await writeJsonl(path.join(projDir, `${id}.jsonl`), [
      { type: 'ai-title', sessionId: id, aiTitle: 'Found it' },
      { type: 'user', sessionId: id, cwd: '/Users/x/proj', message: { content: 'q' } },
    ]);

    const meta = await recentSessionsService.lookupById(tmp, id);
    assert.ok(meta);
    assert.equal(meta!.id, id);
    assert.equal(meta!.title, 'Found it');
    assert.equal(meta!.project, 'proj');
    assert.equal(meta!.cwd, '/Users/x/proj');

    const missing = await recentSessionsService.lookupById(tmp, 'no-such-id');
    assert.equal(missing, null);
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
