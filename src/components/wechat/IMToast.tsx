import { useEffect, useState } from 'react';
import { AlertTriangle, Info } from 'lucide-react';

import type { ImToastDetail } from '../../services/im/toast';

// MARK: - IMToast
//
// Transient top-center toast surface for IM sync / mutation failures. Listens
// on the window 'im:toast' bus (see services/im/toast.ts) and auto-dismisses
// each message after a few seconds. Mounted once by IMProvider so every web
// surface — sidebar, chat pane, contacts — shares it.

interface Toast {
  id: number;
  message: string;
  kind: ImToastDetail['kind'];
}

const DISMISS_MS = 3200;

export default function IMToast() {
  const [toasts, setToasts] = useState<Toast[]>([]);

  useEffect(() => {
    let seq = 0;
    const onToast = (event: Event) => {
      const detail = (event as CustomEvent<ImToastDetail>).detail;
      if (!detail?.message) return;
      const id = ++seq;
      setToasts((prev) => [...prev, { id, message: detail.message, kind: detail.kind }]);
      window.setTimeout(() => setToasts((prev) => prev.filter((t) => t.id !== id)), DISMISS_MS);
    };
    window.addEventListener('im:toast', onToast);
    return () => window.removeEventListener('im:toast', onToast);
  }, []);

  if (toasts.length === 0) return null;

  return (
    <div className="pointer-events-none fixed inset-x-0 top-4 z-[9999] flex flex-col items-center gap-2 px-4">
      {toasts.map((t) => (
        <div
          key={t.id}
          className="pointer-events-auto flex max-w-[90vw] items-center gap-2 rounded-full bg-black/85 px-4 py-2 text-[12px] font-medium text-white shadow-lg backdrop-blur-sm"
          role="status"
        >
          {t.kind === 'error' ? (
            <AlertTriangle className="h-3.5 w-3.5 shrink-0 text-orange-400" />
          ) : (
            <Info className="h-3.5 w-3.5 shrink-0 text-[var(--wc-accent,#07c160)]" />
          )}
          <span className="truncate">{t.message}</span>
        </div>
      ))}
    </div>
  );
}
