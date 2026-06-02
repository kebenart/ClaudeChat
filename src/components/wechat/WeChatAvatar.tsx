import { useMemo, useState } from 'react';

// Avatar gallery (226 cute/anime avatars from qqe9.com), auto-generated.
import { AVATAR_GALLERY } from './avatarGallery';

// MARK: - WeChatAvatar
//
// 1:1 port of the macOS app's `AvatarView` (Sources/ChatKit/UI/Avatar/AvatarView.swift)
// + `AvatarHashing` (Sources/ChatKit/UI/Avatar/AvatarHashing.swift).
//
// Visual contract (matches SwiftUI output exactly):
//   - Rounded square (4px corner), NOT a circle.
//   - Background color is djb2-derived from `seed` % palette length.
//   - Letter is the first CJK ideograph in `title`, or first ASCII letter
//     uppercased, or "?" fallback.
//   - Font size is `size * 0.42`, white, weight 500.
//
// The Swift palette has 12 colors; we mirror them via inline hex (avoids
// Tailwind purge skipping rare classes and keeps colors identical to native).

// MUST stay in lock-step with `Sources/ChatKit/UI/Avatar/AvatarHashing.swift::palette`.
const PALETTE = [
  '#e15c5c', // red
  '#d97316', // orange
  '#ca8a04', // amber
  '#36a3a0', // teal
  '#22a86d', // green
  '#3b82f6', // blue
  '#5a8fc0', // steel blue
  '#6366f1', // indigo
  '#7a4fd6', // purple
  '#db2777', // pink
  '#7c6547', // brown
  '#64748b', // slate
] as const;

/**
 * djb2 polynomial hash, identical to the Swift implementation:
 *   var hash: UInt64 = 5381
 *   for scalar in seed.unicodeScalars { hash = (hash &* 31) &+ UInt64(scalar.value) }
 *
 * BigInt is used because plain JS numbers lose precision past 2^53 and we need
 * the same modulo result the Swift `UInt64` wrap-around produces.
 */
function djb2Bigint(seed: string): bigint {
  let hash = 5381n;
  const mask = 0xffffffffffffffffn; // emulate UInt64 overflow
  for (let i = 0; i < seed.length; i += 1) {
    const code = seed.codePointAt(i);
    if (code === undefined) {
      continue;
    }
    hash = (hash * 31n) & mask;
    hash = (hash + BigInt(code)) & mask;
    // Skip the low surrogate when we just consumed a non-BMP code point.
    if (code > 0xffff) {
      i += 1;
    }
  }
  return hash;
}

function colorForSeed(seed: string): string {
  if (!seed) {
    return PALETTE[0];
  }
  const idx = Number(djb2Bigint(seed) % BigInt(PALETTE.length));
  return PALETTE[idx];
}

function textForTitle(title: string): string {
  if (!title) {
    return '?';
  }
  for (let i = 0; i < title.length; i += 1) {
    const v = title.codePointAt(i);
    if (v === undefined) {
      continue;
    }
    if (
      (v >= 0x4e00 && v <= 0x9fff) || // CJK Unified Ideographs
      (v >= 0x3400 && v <= 0x4dbf) || // CJK Ext-A
      (v >= 0x20000 && v <= 0x2a6df) || // CJK Ext-B
      (v >= 0xf900 && v <= 0xfaff) // CJK Compatibility Ideographs
    ) {
      return String.fromCodePoint(v);
    }
    if (v > 0xffff) {
      i += 1;
    }
  }
  for (const ch of title) {
    // ASCII letter check — must match Swift `char.isLetter && char.isASCII`.
    if (/[A-Za-z]/.test(ch)) {
      return ch.toUpperCase();
    }
  }
  return '?';
}

interface Props {
  seed: string;
  title: string;
  size?: number;
}

// Pure deterministic hash → gallery slot, BYTE-FOR-BYTE identical to the Swift
// `AvatarGallery.index(for:)` (djb2 seed 5381, ×31, 64-bit wrap, % count) over
// the same 226-image gallery in the same order. This is what makes the SAME
// conversation show the SAME avatar on web, iOS and macOS. (Previously web used
// a per-browser localStorage "no-repeat" assignment, which diverged from the
// native clients and differed between browsers — we trade occasional repeats
// for cross-platform consistency.)
function avatarUrl(seed: string): string {
  const n = AVATAR_GALLERY.length;
  const key = seed || 'anon';
  return AVATAR_GALLERY[Number(djb2Bigint(key) % BigInt(n))];
}

export default function WeChatAvatar({ seed, title, size = 38 }: Props) {
  const bg = useMemo(() => colorForSeed(seed), [seed]);
  const letter = useMemo(() => textForTitle(title), [title]);
  const url = useMemo(() => avatarUrl(seed), [seed]);
  const [imgFailed, setImgFailed] = useState(false);
  const fontSize = Math.round(size * 0.42);

  return (
    <div
      aria-hidden
      className="relative flex shrink-0 select-none items-center justify-center overflow-hidden font-medium text-white"
      style={{
        width: size,
        height: size,
        backgroundColor: bg,
        borderRadius: 4,
        fontSize,
        lineHeight: 1,
      }}
    >
      {/* Initials fallback sits underneath; the image covers it once loaded. */}
      {letter}
      {!imgFailed && (
        <img
          src={url}
          alt=""
          draggable={false}
          loading="lazy"
          onError={() => setImgFailed(true)}
          className="absolute inset-0 h-full w-full object-cover"
          style={{ borderRadius: 4 }}
        />
      )}
    </div>
  );
}
