import { createReadStream } from 'node:fs';
import readline from 'node:readline';

/** Coarse classification used by the client to fold tool activity in the raw
 *  transcript viewer. `text` = a real user/assistant message; the rest are
 *  collapsible "执行了 N 个操作" noise. */
export type TranscriptEntryKind = 'text' | 'tool_use' | 'tool_result' | 'thinking' | 'meta';

export interface TranscriptEntrySummary {
  id: string;
  type: string;
  /** 'user' | 'assistant' | other — the jsonl top-level role, for bubble side. */
  role: string;
  kind: TranscriptEntryKind;
  summary: string; // short summary; large blobs must be fetched via readTranscriptBlob
  hasBlob: boolean;
}

export interface TranscriptPage {
  entries: TranscriptEntrySummary[];
  hasMoreBefore: boolean;
  hasMoreAfter: boolean;
}

const BLOB_THRESHOLD = 2000; // chars

function summarize(obj: any) {
  const content = obj?.message?.content;
  let text = '';
  if (typeof content === 'string') {
    text = content;
  } else if (Array.isArray(content)) {
    text = content
      .map((b) => {
        if (b?.type === 'tool_use') return `🛠️ ${b?.name ?? 'tool'}`;
        if (b?.type === 'tool_result') {
          const c = b?.content;
          const inner =
            typeof c === 'string'
              ? c
              : Array.isArray(c)
                ? c.map((x: any) => x?.text ?? '').join(' ')
                : '';
          return `↩︎ ${inner || 'tool_result'}`;
        }
        return b?.text ?? b?.name ?? b?.type ?? '';
      })
      .join(' ');
  }
  const hasBlob = text.length > BLOB_THRESHOLD;
  return { summary: hasBlob ? `${text.slice(0, 200)}…` : text, hasBlob };
}

/** Classify an entry so the client can fold tool activity. */
function classify(obj: any): { role: string; kind: TranscriptEntryKind } {
  const t = obj?.type;
  const content = obj?.message?.content;
  const blocks = Array.isArray(content) ? content : [];
  const types = new Set<string>(blocks.map((b) => b?.type).filter(Boolean));
  const hasText =
    typeof content === 'string' ? content.trim().length > 0 : types.has('text');

  if (t === 'assistant') {
    if (hasText) return { role: 'assistant', kind: 'text' };
    if (types.has('tool_use')) return { role: 'assistant', kind: 'tool_use' };
    if (types.has('thinking') || types.has('redacted_thinking')) {
      return { role: 'assistant', kind: 'thinking' };
    }
    return { role: 'assistant', kind: 'text' };
  }
  if (t === 'user') {
    if (types.has('tool_result')) return { role: 'user', kind: 'tool_result' };
    return { role: 'user', kind: 'text' };
  }
  return { role: typeof t === 'string' ? t : 'meta', kind: 'meta' };
}

async function readAll(jsonlPath: string): Promise<any[]> {
  const out: any[] = [];
  let stream;
  try {
    stream = createReadStream(jsonlPath, { encoding: 'utf8' });
  } catch {
    return out;
  }
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
  try {
    for await (const line of rl) {
      if (!line.trim()) continue;
      try {
        out.push(JSON.parse(line));
      } catch {
        // skip malformed line
      }
    }
  } catch {
    // unreadable — return what we have
  } finally {
    rl.close();
    stream.destroy();
  }
  return out;
}

/** Cursor-paginated raw transcript (Zulip-style anchor + numBefore/numAfter). */
export async function readTranscriptPage(opts: {
  jsonlPath: string;
  anchor?: string; // entry id
  numBefore: number;
  numAfter: number;
}): Promise<TranscriptPage> {
  const all = await readAll(opts.jsonlPath);
  const withIds = all.map((o, i) => ({ obj: o, id: o.uuid ?? `idx-${i}`, idx: i }));
  // No anchor → anchor at the END so `numBefore` returns the LATEST entries
  // (the transcript opens on the most recent activity, like a chat; scroll up
  // loads older). With an anchor → numBefore walks back / numAfter walks forward.
  let anchorIdx = withIds.length;
  if (opts.anchor) {
    const found = withIds.find((e) => e.id === opts.anchor);
    if (found) anchorIdx = found.idx;
  }
  const startIdx = Math.max(0, anchorIdx - opts.numBefore);
  const endIdx = Math.min(withIds.length, anchorIdx + opts.numAfter);
  const slice = withIds.slice(startIdx, endIdx);
  const entries = slice.map((e) => {
    const s = summarize(e.obj);
    const c = classify(e.obj);
    return {
      id: e.id,
      type: e.obj?.type ?? 'unknown',
      role: c.role,
      kind: c.kind,
      summary: s.summary,
      hasBlob: s.hasBlob,
    };
  });
  return {
    entries,
    hasMoreBefore: startIdx > 0,
    hasMoreAfter: endIdx < withIds.length,
  };
}

/** Returns the full raw payload for a single entry id (lazy blob fetch). */
export async function readTranscriptBlob(jsonlPath: string, entryId: string): Promise<any | null> {
  const all = await readAll(jsonlPath);
  const found = all.find((o, i) => (o.uuid ?? `idx-${i}`) === entryId);
  return found ?? null;
}
