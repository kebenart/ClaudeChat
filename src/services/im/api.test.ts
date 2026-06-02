import test from 'node:test';
import assert from 'node:assert/strict';

import { buildSyncUrl, buildMessagesUrl, buildTranscriptUrl } from '@/services/im/urls.js';

test('buildSyncUrl encodes the cursor', () => {
  assert.equal(buildSyncUrl(0), '/api/im/sync?since=0');
  assert.equal(buildSyncUrl(42), '/api/im/sync?since=42');
});

test('buildSyncUrl appends recent only when > 0', () => {
  assert.equal(buildSyncUrl(0, 50), '/api/im/sync?since=0&recent=50');
  assert.equal(buildSyncUrl(0, 0), '/api/im/sync?since=0'); // 0 → omitted
  assert.equal(buildSyncUrl(7), '/api/im/sync?since=7'); // undefined → omitted
});

test('buildMessagesUrl encodes anchor/numBefore/numAfter and the conversation id', () => {
  assert.equal(buildMessagesUrl('c1', { numBefore: 40, numAfter: 0 }), '/api/im/conversations/c1/messages?numBefore=40&numAfter=0');
  assert.equal(
    buildMessagesUrl('a/b', { anchorSeq: 5, numBefore: 2, numAfter: 3 }),
    '/api/im/conversations/a%2Fb/messages?anchor=5&numBefore=2&numAfter=3'
  );
});

test('buildTranscriptUrl encodes paging', () => {
  assert.equal(buildTranscriptUrl('c1', { numBefore: 0, numAfter: 40 }), '/api/im/conversations/c1/transcript?numBefore=0&numAfter=40');
});
