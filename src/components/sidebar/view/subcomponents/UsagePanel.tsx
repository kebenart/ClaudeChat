import { useEffect, useState } from 'react';
import { authenticatedFetch } from '../../../../utils/api';

interface ModelTotals {
  input: number;
  output: number;
  cacheCreation: number;
  cacheRead: number;
  costUsd: number;
}

interface Totals {
  input: number;
  output: number;
  cacheCreation: number;
  cacheRead: number;
  total: number;
  costUsd: number;
  byModel: Record<string, ModelTotals>;
}

interface Summary {
  asOf: number;
  fiveHour: Totals;
  week: Totals;
}

const POLL_MS = 60_000; // once a minute

function fmtTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

function fmtUsd(n: number): string {
  if (n < 0.01) return '<$0.01';
  if (n < 10) return `$${n.toFixed(2)}`;
  return `$${n.toFixed(0)}`;
}

export function UsagePanel() {
  const [data, setData] = useState<Summary | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const tick = async () => {
      try {
        const res = await authenticatedFetch('/api/usage/summary');
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const next: Summary = await res.json();
        if (!cancelled) {
          setData(next);
          setErr(null);
        }
      } catch (e: unknown) {
        if (!cancelled) setErr(e instanceof Error ? e.message : String(e));
      }
    };
    void tick();
    const id = setInterval(tick, POLL_MS);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  if (err) return <div className="px-3 py-2 text-xs text-red-500">Usage: {err}</div>;
  if (!data) return <div className="px-3 py-2 text-xs text-muted-foreground">Usage…</div>;

  return (
    <div className="space-y-1 border-t border-border px-3 py-2 text-xs">
      <div className="flex items-center justify-between gap-2">
        <span className="font-semibold uppercase tracking-wide text-muted-foreground">5h</span>
        <span className="font-mono">{fmtTokens(data.fiveHour.total)}</span>
        <span className="font-mono text-muted-foreground">{fmtUsd(data.fiveHour.costUsd)}</span>
      </div>
      <div className="flex items-center justify-between gap-2">
        <span className="font-semibold uppercase tracking-wide text-muted-foreground">7d</span>
        <span className="font-mono">{fmtTokens(data.week.total)}</span>
        <span className="font-mono text-muted-foreground">{fmtUsd(data.week.costUsd)}</span>
      </div>
    </div>
  );
}
