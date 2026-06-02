import assert from 'node:assert/strict';
import test from 'node:test';

import { runningSessionsService } from '@/services/running-sessions.service.js';

test('returns the IDs reported by the underlying getter', () => {
  const fakeGetter = () => ['sess-a', 'sess-b'];
  const ids = runningSessionsService.list(fakeGetter);
  assert.deepEqual(ids, ['sess-a', 'sess-b']);
});

test('returns an empty array when the underlying getter returns nothing iterable', () => {
  const fakeGetter = () => [] as string[];
  assert.deepEqual(runningSessionsService.list(fakeGetter), []);
});
