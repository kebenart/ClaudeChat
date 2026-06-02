import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildImMessageEvent,
  buildImReadEvent,
  buildImPokeEvent,
  buildImStatusEvent,
  serializeMessage,
  IM_CONTENT_PREVIEW_LIMIT,
} from '@/services/im-events.service.js';
import type { ImMessageRow } from '@/shared/types.js';

const baseRow: ImMessageRow = {
  pk: 10,
  conversation_id: 'c1',
  source_id: 's2',
  seq: 2,
  role: 'assistant',
  kind: 'result',
  content: 'done',
  tool_trace_count: 3,
  raw_ref_start: 'a1',
  raw_ref_end: 'tr1',
  created_at: 5,
  rev: 1,
};

test('buildImMessageEvent shapes the wire frame with toolTrace', () => {
  const frame = buildImMessageEvent(baseRow);
  assert.equal(frame.type, 'im:message');
  assert.equal(frame.message.id, 's2');
  assert.equal(frame.message.conversationId, 'c1');
  assert.equal(frame.message.seq, 2);
  assert.equal(frame.message.kind, 'result');
  assert.equal(frame.message.content, 'done');
  assert.deepEqual(frame.message.toolTrace, { count: 3, rawRefStart: 'a1', rawRefEnd: 'tr1' });
});

test('serializeMessage omits toolTrace when there is no tool activity', () => {
  const msg = serializeMessage({ ...baseRow, tool_trace_count: 0, raw_ref_start: null, raw_ref_end: null });
  assert.equal('toolTrace' in msg, false);
  assert.equal(msg.id, 's2');
});

test('buildImReadEvent shapes the read frame', () => {
  const frame = buildImReadEvent('c1', 'deviceA', 7);
  assert.equal(frame.type, 'im:read');
  assert.equal(frame.conversationId, 'c1');
  assert.equal(frame.deviceId, 'deviceA');
  assert.equal(frame.lastReadSeq, 7);
});

test('buildImPokeEvent shapes the poke frame', () => {
  const frame = buildImPokeEvent(42);
  assert.equal(frame.type, 'im:poke');
  assert.equal(frame.since, 42);
});

test('buildImStatusEvent shapes the coarse-progress frame', () => {
  const frame = buildImStatusEvent({
    conversationId: 'c1',
    isProcessing: true,
    toolCount: 3,
    currentTool: 'Bash',
  });
  assert.equal(frame.type, 'im:status');
  assert.equal(frame.conversationId, 'c1');
  assert.equal(frame.isProcessing, true);
  assert.equal(frame.toolCount, 3);
  assert.equal(frame.currentTool, 'Bash');

  const done = buildImStatusEvent({ conversationId: 'c1', isProcessing: false, toolCount: 0, currentTool: null });
  assert.equal(done.isProcessing, false);
  assert.equal(done.currentTool, null);
});

test('serializeMessage truncates long content and reports fullLength', () => {
  const long = 'x'.repeat(IM_CONTENT_PREVIEW_LIMIT + 50);
  const msg = serializeMessage({ ...baseRow, content: long });
  assert.equal(msg.truncated, true);
  assert.equal(msg.fullLength, IM_CONTENT_PREVIEW_LIMIT + 50);
  assert.equal(msg.content.length, IM_CONTENT_PREVIEW_LIMIT);
  assert.equal(msg.content, long.slice(0, IM_CONTENT_PREVIEW_LIMIT));
});

test('serializeMessage leaves short content untouched (no truncated flag)', () => {
  const msg = serializeMessage({ ...baseRow, content: 'short body' });
  assert.equal('truncated' in msg, false);
  assert.equal('fullLength' in msg, false);
  assert.equal(msg.content, 'short body');
});
