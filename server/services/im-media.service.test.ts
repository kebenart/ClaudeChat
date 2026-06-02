import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// im-media derives its store from getDatabasePath() → <db dir>/im-media. Point
// DATABASE_PATH at a throwaway dir BEFORE importing the service so the test
// never touches the real ~/.cloudcli/im-media.
const TMP = mkdtempSync(join(tmpdir(), 'im-media-'));
process.env.DATABASE_PATH = join(TMP, 'auth.db');

const { saveImageFromPath, resolveMedia } = await import('@/services/im-media.service.js');

// A real 1x1 PNG (valid magic bytes).
const PNG_1x1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

test('saveImageFromPath copies a valid PNG and resolveMedia round-trips it', () => {
  const src = join(TMP, 'shot.png');
  writeFileSync(src, PNG_1x1);

  const saved = saveImageFromPath(src);
  assert.match(saved.id, /^[0-9a-f]{32}\.png$/);

  const resolved = resolveMedia(saved.id);
  assert.ok(resolved);
  assert.equal(resolved!.contentType, 'image/png');
  assert.ok(existsSync(resolved!.absPath));
});

test('resolveMedia rejects anything that is not a <hex>.<ext> id (no traversal)', () => {
  assert.equal(resolveMedia('../../etc/passwd'), null);
  assert.equal(resolveMedia('not-an-id'), null);
  assert.equal(resolveMedia('deadbeef.png'), null); // too short
  assert.equal(resolveMedia('00112233445566778899aabbccddeeff.bmp'), null); // bad ext
});

test('saveImageFromPath rejects a non-image file (magic-byte sniff)', () => {
  const src = join(TMP, 'fake.png');
  writeFileSync(src, 'this is not an image');
  assert.throws(() => saveImageFromPath(src), /not a recognized image/);
});

test('saveImageFromPath rejects a missing path and an unsupported extension', () => {
  assert.throws(() => saveImageFromPath(join(TMP, 'nope.png')), /not found/);
  const txt = join(TMP, 'note.txt');
  writeFileSync(txt, PNG_1x1);
  assert.throws(() => saveImageFromPath(txt), /unsupported extension/);
});
