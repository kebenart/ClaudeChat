/**
 * TOTP service for two-factor authentication.
 *
 * Generates and verifies TOTP codes using otplib.
 * Seals/unseals the TOTP secret using AES-256-GCM with a key derived from JWT_SECRET.
 */

import crypto from 'node:crypto';

import { generateSecret, generateSync, generateURI, verifySync } from 'otplib';

const ISSUER = 'claudecodeui-local';

function getKey(): Buffer {
  const seed = process.env.JWT_SECRET;
  if (!seed) throw new Error('JWT_SECRET must be set before sealing TOTP secrets');
  return crypto.createHash('sha256').update(seed).digest();
}

export const totpService = {
  generateSecret(): string {
    return generateSecret();
  },

  sealSecret(secret: string): string {
    const key = getKey();
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
    const enc = Buffer.concat([cipher.update(secret, 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();
    return Buffer.concat([iv, tag, enc]).toString('base64');
  },

  unsealSecret(sealed: string): string {
    const buf = Buffer.from(sealed, 'base64');
    const iv = buf.subarray(0, 12);
    const tag = buf.subarray(12, 28);
    const enc = buf.subarray(28);
    const decipher = crypto.createDecipheriv('aes-256-gcm', getKey(), iv);
    decipher.setAuthTag(tag);
    const dec = Buffer.concat([decipher.update(enc), decipher.final()]);
    return dec.toString('utf8');
  },

  verifyCode(secret: string, code: string): boolean {
    const result = verifySync({ secret, token: code });
    // verifySync returns an object with { valid, ... } or false
    if (typeof result === 'boolean') return result;
    if (typeof result === 'object' && result !== null) return (result as { valid: boolean }).valid;
    return false;
  },

  provisioningUri(username: string, secret: string): string {
    return generateURI({ label: username, issuer: ISSUER, secret });
  },
};
