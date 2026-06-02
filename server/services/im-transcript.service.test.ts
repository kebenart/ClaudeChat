import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { readTranscriptPage, readTranscriptBlob } from '@/services/im-transcript.service.js';

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'im-tr-'));
  const file = join(dir, 's.jsonl');
  const lines = [
    JSON.stringify({ type: 'user', uuid: 'u1', message: { role: 'user', content: 'do x' } }),
    JSON.stringify({ type: 'assistant', uuid: 'a1', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't1', name: 'Edit', input: { file: 'a.ts' } }] } }),
    JSON.stringify({ type: 'assistant', uuid: 'a2', message: { role: 'assistant', content: [{ type: 'text', text: 'done' }] } }),
  ].join('\n');
  writeFileSync(file, lines, 'utf8');
  return file;
}

test('readTranscriptPage with no anchor returns the LATEST entries (tail)', async () => {
  const file = fixture();
  // No anchor → newest page. Fixture has [u1, a1, a2]; last 2 = [a1, a2].
  const page = await readTranscriptPage({ jsonlPath: file, anchor: undefined, numBefore: 2, numAfter: 0 });
  assert.deepEqual(page.entries.map((e) => e.id), ['a1', 'a2']);
  assert.ok(typeof page.entries[0].summary === 'string');
  assert.equal(page.hasMoreBefore, true); // u1 is older, still loadable
  assert.equal(page.hasMoreAfter, false);
});

test('readTranscriptPage windows backwards from an anchor', async () => {
  const file = fixture();
  const page = await readTranscriptPage({ jsonlPath: file, anchor: 'a2', numBefore: 2, numAfter: 0 });
  assert.deepEqual(page.entries.map((e) => e.id), ['u1', 'a1']);
  assert.equal(page.hasMoreBefore, false);
});

test('large content is flagged hasBlob and truncated in the summary', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'im-tr-'));
  const file = join(dir, 's.jsonl');
  const big = 'x'.repeat(5000);
  writeFileSync(file, JSON.stringify({ type: 'assistant', uuid: 'big1', message: { role: 'assistant', content: [{ type: 'text', text: big }] } }), 'utf8');
  const page = await readTranscriptPage({ jsonlPath: file, numBefore: 10, numAfter: 0 });
  assert.equal(page.entries[0].hasBlob, true);
  assert.ok(page.entries[0].summary.length < 5000);
});

test('readTranscriptBlob returns the full raw entry by id, or null', async () => {
  const file = fixture();
  const blob = await readTranscriptBlob(file, 'a1');
  assert.equal(blob?.uuid, 'a1');
  assert.equal(await readTranscriptBlob(file, 'nope'), null);
});
