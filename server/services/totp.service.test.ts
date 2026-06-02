import assert from 'node:assert/strict';
import { generateSecret, generateSync } from 'otplib';
import test from 'node:test';

import { totpService } from '@/services/totp.service.js';

process.env.JWT_SECRET = 'unit-test-key-do-not-use-in-prod';

test('sealSecret/unsealSecret round-trip yields the original secret', () => {
  const secret = generateSecret();
  const sealed = totpService.sealSecret(secret);
  assert.notEqual(sealed, secret);
  assert.equal(totpService.unsealSecret(sealed), secret);
});

test('verifyCode accepts a code generated from the same secret', () => {
  const secret = generateSecret();
  const code = generateSync({ secret });
  assert.equal(totpService.verifyCode(secret, code), true);
});

test('verifyCode rejects an obviously wrong code', () => {
  const secret = generateSecret();
  assert.equal(totpService.verifyCode(secret, '000000'), false);
});

test('provisioningUri encodes label and issuer', () => {
  const uri = totpService.provisioningUri('alice', 'JBSWY3DPEHPK3PXP');
  assert.match(uri, /^otpauth:\/\/totp\/claudecodeui-local:alice\?/);
  assert.match(uri, /secret=JBSWY3DPEHPK3PXP/);
  assert.match(uri, /issuer=claudecodeui-local/);
});
