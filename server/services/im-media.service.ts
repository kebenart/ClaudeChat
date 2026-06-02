import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

import { getDatabasePath } from '@/modules/database/index.js';

/**
 * IM media store — assistant-sent images (e.g. test-result screenshots).
 *
 * Images arrive by absolute path from the loopback hook (scripts/im-send-image.mjs
 * runs on the same machine as the server). We NEVER serve that original path:
 * the file is validated (extension + magic bytes + size) and COPIED into a
 * server-managed directory under a random id, and clients only ever fetch by
 * that sanitized id via `GET /api/im/media/:id`. This blocks path-traversal /
 * arbitrary-file reads — a request can only ever name a file we put there.
 *
 * The store lives next to the SQLite DB (`<db dir>/im-media`).
 */

const MAX_BYTES = 12 * 1024 * 1024; // 12 MB
const EXT_BY_MIME: Record<string, string> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
};
// A media id is `<32 hex>.<ext>` — the only shape the GET endpoint will resolve.
const ID_RE = /^[0-9a-f]{32}\.(png|jpe?g|gif|webp)$/;

function mediaDir(): string {
  const dir = path.join(path.dirname(getDatabasePath()), 'im-media');
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function normalizeExt(ext: string): keyof typeof EXT_BY_MIME | null {
  const e = ext.replace(/^\./, '').toLowerCase();
  return e in EXT_BY_MIME ? (e as keyof typeof EXT_BY_MIME) : null;
}

/** Sniff the leading bytes so a renamed non-image can't slip through. */
function sniffExt(buf: Buffer): keyof typeof EXT_BY_MIME | null {
  if (buf.length >= 8 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return 'png';
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'jpg';
  if (buf.length >= 6 && buf.toString('ascii', 0, 6).match(/^GIF8[79]a$/)) return 'gif';
  if (buf.length >= 12 && buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') return 'webp';
  return null;
}

export interface SavedImage {
  /** `<hex>.<ext>` — the public media id used in the message + GET path. */
  id: string;
  bytes: number;
}

/**
 * Validate `srcPath` is a real, in-size, magic-byte-verified image and copy it
 * into the media store. Throws an Error (message safe to surface) on any
 * rejection. The declared extension must match the sniffed bytes.
 */
export function saveImageFromPath(srcPath: string): SavedImage {
  if (typeof srcPath !== 'string' || srcPath.length === 0) throw new Error('no image path');
  let stat: fs.Stats;
  try {
    stat = fs.statSync(srcPath);
  } catch {
    throw new Error(`image not found: ${srcPath}`);
  }
  if (!stat.isFile()) throw new Error('not a file');
  if (stat.size === 0) throw new Error('empty file');
  if (stat.size > MAX_BYTES) throw new Error(`image too large (${stat.size} > ${MAX_BYTES} bytes)`);

  const declared = normalizeExt(path.extname(srcPath));
  if (!declared) throw new Error('unsupported extension (png/jpg/jpeg/gif/webp only)');

  const buf = fs.readFileSync(srcPath);
  const sniffed = sniffExt(buf);
  if (!sniffed) throw new Error('file is not a recognized image');
  // jpg/jpeg are the same format; otherwise the declared ext must match bytes.
  const same = sniffed === declared || (sniffed === 'jpg' && declared === 'jpeg');
  if (!same) throw new Error(`extension/content mismatch (looks like ${sniffed})`);

  const ext = sniffed === 'jpg' && declared === 'jpeg' ? 'jpeg' : sniffed;
  const hex = randomBytes(16).toString('hex');
  const id = `${hex}.${ext}`;
  const dir = mediaDir();
  const originalPath = path.join(dir, id);
  fs.writeFileSync(originalPath, buf);

  // Best-effort thumbnail (macOS `sips`): a ~640px JPEG (tens of KB) that the
  // chat bubbles load instead of the multi-MB original. If sips is unavailable
  // (non-macOS) it just doesn't exist and clients fall back to the original.
  try {
    execFileSync(
      'sips',
      ['-Z', '640', '-s', 'format', 'jpeg', '-s', 'formatOptions', '62', originalPath, '--out', path.join(dir, `${hex}.thumb.jpg`)],
      { stdio: 'ignore', timeout: 8000 },
    );
  } catch {
    /* no thumbnail — clients use the original */
  }
  return { id, bytes: stat.size };
}

export interface ResolvedMedia {
  absPath: string;
  contentType: string;
}

/** Resolve a media id to an on-disk file + MIME, or null. Rejects any id that
 *  isn't exactly `<32 hex>.<ext>` (no traversal, no surprises). When `wantThumb`
 *  is set, returns the small JPEG thumbnail if one exists, else the original. */
export function resolveMedia(id: string, wantThumb = false): ResolvedMedia | null {
  if (typeof id !== 'string' || !ID_RE.test(id)) return null;
  const dir = mediaDir();
  if (wantThumb) {
    const hex = id.split('.')[0];
    const thumbPath = path.join(dir, `${hex}.thumb.jpg`);
    if (fs.existsSync(thumbPath)) return { absPath: thumbPath, contentType: 'image/jpeg' };
    // no thumbnail → fall through to the original
  }
  const absPath = path.join(dir, id);
  if (!fs.existsSync(absPath)) return null;
  const ext = normalizeExt(path.extname(id));
  if (!ext) return null;
  return { absPath, contentType: EXT_BY_MIME[ext] };
}
