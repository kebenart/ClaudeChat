import { open, stat } from 'node:fs/promises';

import { imDb } from '@/modules/database/index.js';
import { distillJsonl, isUserTextEntry } from '@/services/im-distill.service.js';
import { buildImMessageEvent, broadcastImEvent } from '@/services/im-events.service.js';
import type { ImMessageRow, RawJsonlEntry } from '@/shared/types.js';

export interface IngestOptions {
  sessionId: string;
  contactId: string | null;
  title: string | null;
  jsonlPath: string;
}

// Per-session incremental checkpoint. A session jsonl is append-only and a
// finalized turn never changes once the next user-text message starts, so we
// re-distill only from the last user-text *boundary* instead of re-reading the
// whole file on every watcher event. `offset` is the byte position of that
// boundary line; `size` is the file size we last saw (to detect truncation /
// rotation). This turns the per-event cost from O(whole session) into O(last
// turn) at O(1) memory per session — the output is byte-for-byte identical to a
// full re-distill because insertMessages is idempotent on (conversation, sourceId).
interface IngestCheckpoint {
  offset: number;
  size: number;
}
const checkpoints = new Map<string, IngestCheckpoint>();

/** Test hook: clear all incremental checkpoints (call between tests). */
export function __resetImIngestCheckpoints(): void {
  checkpoints.clear();
}
/** Test hook: the current rewind byte offset for a session (undefined if none). */
export function __imIngestCheckpoint(sessionId: string): number | undefined {
  return checkpoints.get(sessionId)?.offset;
}

interface SliceItem {
  entry: RawJsonlEntry;
  offset: number;
}

/**
 * Read jsonl entries from `start` to EOF, tracking each line's byte offset.
 * Splits on newline bytes (0x0A never occurs inside a UTF-8 multibyte sequence,
 * so this is byte-accurate). Malformed / partially-written trailing lines fail
 * JSON.parse and are skipped — they get re-read on the next event once complete.
 */
async function readSliceFrom(jsonlPath: string, start: number): Promise<{ items: SliceItem[]; size: number }> {
  const items: SliceItem[] = [];
  let size = 0;
  let fh;
  try {
    size = (await stat(jsonlPath)).size;
    if (start >= size) return { items, size };
    fh = await open(jsonlPath, 'r');
    const length = size - start;
    const buf = Buffer.alloc(length);
    await fh.read(buf, 0, length, start);

    const pushSeg = (segStart: number, segEnd: number) => {
      const text = buf.subarray(segStart, segEnd).toString('utf8').trim();
      if (!text) return;
      try {
        items.push({ entry: JSON.parse(text) as RawJsonlEntry, offset: start + segStart });
      } catch {
        // malformed or a still-being-written final line — skip; re-read later
      }
    };

    let lineStart = 0;
    for (let i = 0; i < buf.length; i++) {
      if (buf[i] === 0x0a) {
        pushSeg(lineStart, i);
        lineStart = i + 1;
      }
    }
    if (lineStart < buf.length) pushSeg(lineStart, buf.length); // trailing line w/o newline (EOF)
  } catch {
    // file missing / unreadable — return what we have
  } finally {
    await fh?.close();
  }
  return { items, size };
}

/** Read a session jsonl (incrementally from the last turn boundary), distill,
 *  and idempotently upsert into imDb. Returns the rows affected (inserted or
 *  content-changed). */
async function ingest(opts: IngestOptions): Promise<ImMessageRow[]> {
  imDb.ensureConversation(opts.sessionId, opts.contactId, opts.title);

  const prev = checkpoints.get(opts.sessionId);
  let start = prev?.offset ?? 0;
  // Truncation / rotation guard: if the file shrank below what we last saw, our
  // saved offset is stale — re-read from the top.
  if (prev) {
    let curSize: number | null = null;
    try {
      curSize = (await stat(opts.jsonlPath)).size;
    } catch {
      return []; // file gone — nothing to ingest
    }
    if (curSize < prev.size) start = 0;
  }

  const { items, size } = await readSliceFrom(opts.jsonlPath, start);
  const distilled = distillJsonl(items.map((i) => i.entry));
  const affected = imDb.insertMessages(opts.sessionId, distilled);

  // Advance the checkpoint to the last user-text boundary in this slice so the
  // next event re-distills only the still-growing final turn. If the slice held
  // no user-text line (e.g. only tool_results / assistant deltas appended to the
  // current turn), keep the prior start so we stay anchored at this turn's head.
  let boundary = start;
  for (let i = items.length - 1; i >= 0; i--) {
    if (isUserTextEntry(items[i].entry)) {
      boundary = items[i].offset;
      break;
    }
  }
  checkpoints.set(opts.sessionId, { offset: boundary, size });

  return affected;
}

/** Ingest a session jsonl into the IM stream. Returns the number of rows
 *  affected (inserted or content-changed). */
export async function ingestSessionJsonl(opts: IngestOptions): Promise<number> {
  const affected = await ingest(opts);
  return affected.length;
}

/**
 * Ingest + emit an `im:message` frame for each affected message (newly inserted
 * or content-changed, e.g. a streaming turn growing). `emit` defaults to the
 * real WS broadcast; tests inject a collector. Returns the affected count.
 */
export async function ingestAndBroadcast(
  opts: IngestOptions,
  emit: (frame: ReturnType<typeof buildImMessageEvent>) => void = broadcastImEvent
): Promise<number> {
  const affected = await ingest(opts);
  for (const row of affected) {
    emit(buildImMessageEvent(row));
  }
  return affected.length;
}
