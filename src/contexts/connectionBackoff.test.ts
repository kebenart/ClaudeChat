import { test } from 'node:test';
import assert from 'node:assert/strict';

import { BACKOFF_SEQUENCE_MS, computeBackoffDelay } from './connectionBackoff';

test('attempt 0 with min jitter is half the first base', () => {
  assert.equal(computeBackoffDelay(0, () => 0), 500);
});

test('attempt 0 with max jitter is the full first base', () => {
  assert.equal(computeBackoffDelay(0, () => 1), 1000);
});

test('grows exponentially per the sequence (mid jitter)', () => {
  // base[2] = 4000ms; half=2000; 2000 + 0.5*2000 = 3000
  assert.equal(computeBackoffDelay(2, () => 0.5), 3000);
});

test('caps at the last sequence entry (30s) for large attempts', () => {
  const last = BACKOFF_SEQUENCE_MS[BACKOFF_SEQUENCE_MS.length - 1];
  assert.equal(computeBackoffDelay(99, () => 0), last / 2);
  assert.equal(computeBackoffDelay(99, () => 1), last);
});

test('negative attempt clamps to the first entry', () => {
  assert.equal(computeBackoffDelay(-5, () => 0), 500);
});

test('delay always lands within [base/2, base] for random rng', () => {
  for (let attempt = 0; attempt < 8; attempt++) {
    const i = Math.min(attempt, BACKOFF_SEQUENCE_MS.length - 1);
    const base = BACKOFF_SEQUENCE_MS[i];
    for (let k = 0; k < 50; k++) {
      const d = computeBackoffDelay(attempt);
      assert.ok(d >= base / 2 && d <= base, `attempt ${attempt}: ${d} not in [${base / 2}, ${base}]`);
    }
  }
});
