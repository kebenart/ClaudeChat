import { useEffect, useRef, useState } from 'react';
import { Loader2, ImageOff } from 'lucide-react';

import { authenticatedFetch } from '../../utils/api';
import type { ImageCardContent } from '../../services/im/protocol';

// MARK: - WeChatImageBubble
//
// An assistant-sent image (kind:'image'). The media endpoint requires the JWT,
// so a plain <img src> can't carry auth — we authenticated-fetch the bytes,
// turn them into an object URL, and render that. The bubble loads the small
// THUMBNAIL (?thumb=1); clicking fetches the full-res original on demand and
// opens it in a new tab. Spinner while loading, fallback on error.

function sizeLabel(bytes?: number): string | null {
  if (!bytes || bytes <= 0) return null;
  return bytes >= 1024 * 1024 ? `${(bytes / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

export default function WeChatImageBubble({ image }: { image: ImageCardContent }) {
  const [url, setUrl] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const [openingFull, setOpeningFull] = useState(false);
  const urlRef = useRef<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setUrl(null);
    setFailed(false);
    void (async () => {
      try {
        const res = await authenticatedFetch(`/api/im/media/${encodeURIComponent(image.mediaId)}?thumb=1`);
        if (!res.ok) throw new Error(String(res.status));
        const blob = await res.blob();
        if (cancelled) return;
        const objectUrl = URL.createObjectURL(blob);
        urlRef.current = objectUrl;
        setUrl(objectUrl);
      } catch {
        if (!cancelled) setFailed(true);
      }
    })();
    return () => {
      cancelled = true;
      if (urlRef.current) {
        URL.revokeObjectURL(urlRef.current);
        urlRef.current = null;
      }
    };
  }, [image.mediaId]);

  // Fetch the full-res original (auth'd) and open it in a new tab.
  const openOriginal = async () => {
    if (openingFull) return;
    setOpeningFull(true);
    try {
      const res = await authenticatedFetch(`/api/im/media/${encodeURIComponent(image.mediaId)}`);
      if (!res.ok) throw new Error(String(res.status));
      const blob = await res.blob();
      window.open(URL.createObjectURL(blob), '_blank', 'noopener');
    } catch {
      /* ignore — the thumbnail stays visible */
    } finally {
      setOpeningFull(false);
    }
  };

  const size = sizeLabel(image.bytes);

  return (
    <div className="flex max-w-[260px] flex-col gap-1">
      <div className="relative overflow-hidden rounded-lg border border-zinc-200/70 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        {url ? (
          <img
            src={url}
            alt={image.caption || '图片'}
            className="block max-h-[320px] w-full cursor-zoom-in object-contain"
            onClick={openOriginal}
            title={size ? `查看原图 (${size})` : '查看原图'}
          />
        ) : failed ? (
          <div className="flex h-28 w-44 items-center justify-center gap-1.5 text-zinc-400">
            <ImageOff className="h-4 w-4" />
            <span className="text-[12px]">图片加载失败</span>
          </div>
        ) : (
          <div className="flex h-28 w-44 items-center justify-center text-zinc-400">
            <Loader2 className="h-4 w-4 animate-spin" />
          </div>
        )}
        {url && (
          <button
            type="button"
            onClick={openOriginal}
            disabled={openingFull}
            className="absolute bottom-1.5 right-1.5 flex items-center gap-1 rounded-full bg-black/45 px-2 py-0.5 text-[10px] text-white backdrop-blur-sm hover:bg-black/60 disabled:opacity-60"
          >
            {openingFull && <Loader2 className="h-3 w-3 animate-spin" />}
            {openingFull ? '加载中…' : size ? `查看原图 ${size}` : '查看原图'}
          </button>
        )}
      </div>
      {image.caption && (
        <div className="px-0.5 text-[12px] text-zinc-600 dark:text-zinc-300">{image.caption}</div>
      )}
    </div>
  );
}
