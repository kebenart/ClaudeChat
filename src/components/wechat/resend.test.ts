import test from 'node:test';
import assert from 'node:assert/strict';

import { canResend, resolveResendPayload } from '@/components/wechat/resend.js';

test('canResend only accepts failed outgoing (user) bubbles', () => {
  assert.equal(canResend({ role: 'user', sendStatus: 'failed' }), true);
  assert.equal(canResend({ role: 'user', sendStatus: 'sending' }), false);
  assert.equal(canResend({ role: 'user', sendStatus: 'sent' }), false);
  assert.equal(canResend({ role: 'user', sendStatus: 'delivered' }), false);
  assert.equal(canResend({ role: 'user', sendStatus: undefined }), false);
  // Non-user roles are never resendable, even if somehow marked failed.
  assert.equal(canResend({ role: 'assistant', sendStatus: 'failed' }), false);
  assert.equal(canResend({ role: 'tool', sendStatus: 'failed' }), false);
  assert.equal(canResend({ role: 'system', sendStatus: 'failed' }), false);
});

test('resolveResendPayload prefers the captured resend snapshot (verbatim replay)', () => {
  const images = [{ data: 'data:image/png;base64,AAA', name: 'a.png' }];
  const payload = resolveResendPayload({
    role: 'user',
    sendStatus: 'failed',
    content: '> quoted\n\nhello', // rendered content
    resend: { text: '> quoted\n\nhello', images },
  });
  assert.deepEqual(payload, { text: '> quoted\n\nhello', images });
});

test('resolveResendPayload falls back to rendered content when no snapshot exists', () => {
  const payload = resolveResendPayload({
    role: 'user',
    sendStatus: 'failed',
    content: 'plain text',
    resend: undefined,
  });
  assert.deepEqual(payload, { text: 'plain text' });
});

test('resolveResendPayload returns null for non-resendable messages', () => {
  assert.equal(
    resolveResendPayload({ role: 'user', sendStatus: 'sent', content: 'x', resend: undefined }),
    null,
  );
  assert.equal(
    resolveResendPayload({ role: 'assistant', sendStatus: 'failed', content: 'x', resend: undefined }),
    null,
  );
});
