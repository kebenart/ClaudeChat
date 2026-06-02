import fsp from 'node:fs/promises';
import path from 'node:path';
import readline from 'node:readline';
import { createReadStream } from 'node:fs';

export interface ModelTotals {
  input: number;
  output: number;
  cacheCreation: number;
  cacheRead: number;
  costUsd: number;
}

export interface TokenTotals {
  input: number;
  output: number;
  cacheCreation: number;
  cacheRead: number;
  total: number;        // input + output + cacheCreation + cacheRead
  costUsd: number;
  byModel: Record<string, ModelTotals>;
}

export interface UsageSummary {
  asOf: number;          // ms epoch
  fiveHour: TokenTotals;
  week: TokenTotals;
}

// Per-million pricing in USD. Best-effort defaults; not authoritative.
const PRICES: Record<string, { input: number; output: number; cacheCreation: number; cacheRead: number }> = {
  default:   { input: 3,    output: 15,   cacheCreation: 3.75,  cacheRead: 0.30 },
  opus:      { input: 15,   output: 75,   cacheCreation: 18.75, cacheRead: 1.50 },
  haiku:     { input: 0.80, output: 4,    cacheCreation: 1.00,  cacheRead: 0.08 },
};

function priceFor(modelId: string) {
  const id = (modelId || '').toLowerCase();
  if (id.includes('opus')) return PRICES.opus;
  if (id.includes('haiku')) return PRICES.haiku;
  return PRICES.default;
}

function emptyTotals(): TokenTotals {
  return { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, total: 0, costUsd: 0, byModel: {} };
}

function addUsage(
  t: TokenTotals,
  modelId: string,
  input: number,
  output: number,
  cacheCreation: number,
  cacheRead: number,
) {
  t.input += input;
  t.output += output;
  t.cacheCreation += cacheCreation;
  t.cacheRead += cacheRead;
  t.total += input + output + cacheCreation + cacheRead;
  const px = priceFor(modelId);
  const cost =
    (input          / 1_000_000) * px.input +
    (output         / 1_000_000) * px.output +
    (cacheCreation  / 1_000_000) * px.cacheCreation +
    (cacheRead      / 1_000_000) * px.cacheRead;
  t.costUsd += cost;
  const key = modelId || 'unknown';
  const m: ModelTotals = t.byModel[key] ??= { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, costUsd: 0 };
  m.input += input;
  m.output += output;
  m.cacheCreation += cacheCreation;
  m.cacheRead += cacheRead;
  m.costUsd += cost;
}

async function safeReaddir(dir: string): Promise<string[]> {
  try { return await fsp.readdir(dir); } catch { return []; }
}

export const usageRollupService = {
  async summarize(rootDir: string, now = Date.now()): Promise<UsageSummary> {
    const fiveHourCutoff = now - 5 * 60 * 60 * 1000;
    const weekCutoff = now - 7 * 24 * 60 * 60 * 1000;
    const fiveHour = emptyTotals();
    const week = emptyTotals();

    const projects = await safeReaddir(rootDir);
    for (const project of projects) {
      const projectDir = path.join(rootDir, project);
      const files = await safeReaddir(projectDir);
      for (const file of files) {
        if (!file.endsWith('.jsonl')) continue;
        const full = path.join(projectDir, file);
        let stat;
        try { stat = await fsp.stat(full); } catch { continue; }
        // Skip files entirely outside our largest window (stat-level fast path).
        if (stat.mtimeMs < weekCutoff) continue;

        const stream = createReadStream(full, { encoding: 'utf8' });
        const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
        try {
          for await (const line of rl) {
            if (!line) continue;
            let obj: any;
            try { obj = JSON.parse(line); } catch { continue; }
            if (obj?.type !== 'assistant' || !obj?.message?.usage) continue;
            const ts = Date.parse(obj.timestamp || obj.message?.timestamp || '');
            if (!Number.isFinite(ts)) continue;
            if (ts < weekCutoff) continue;
            const u = obj.message.usage;
            const model: string = obj.message?.model || 'unknown';
            const input: number = u.input_tokens ?? 0;
            const output: number = u.output_tokens ?? 0;
            const cc: number = u.cache_creation_input_tokens ?? 0;
            const cr: number = u.cache_read_input_tokens ?? 0;
            addUsage(week, model, input, output, cc, cr);
            if (ts >= fiveHourCutoff) addUsage(fiveHour, model, input, output, cc, cr);
          }
        } finally {
          rl.close();
          stream.destroy();
        }
      }
    }

    return { asOf: now, fiveHour, week };
  },
};
