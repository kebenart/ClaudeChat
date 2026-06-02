import { createReadStream } from 'node:fs';
import fsp from 'node:fs/promises';
import readline from 'node:readline';

import { resolveContextWindow } from '@/shared/utils.js';

export interface ConversationContext {
  contextTokens: number; // input + cache_read + cache_creation of the last assistant usage
  windowTokens: number;  // model context window — varies by model (e.g. Opus 4.8 = 1M)
  pct: number;           // round(contextTokens / windowTokens * 100)
  model?: string;
}

/**
 * Compute per-conversation context-window occupancy from its session jsonl.
 *
 * Reads the LAST assistant entry that carries a `message.usage` object and
 * sums input + cache_read + cache_creation tokens (the live context), then
 * divides by the model's context window.
 *
 * `jsonlPath` is resolved by the caller (the IM route looks it up via
 * sessionsDb.getSessionById(id).jsonl_path — same locating logic used by the
 * transcript routes). Returns null when the file is missing/unreadable or has
 * no assistant usage entry yet.
 */
export async function getConversationContext(
  jsonlPath: string | null | undefined,
): Promise<ConversationContext | null> {
  if (!jsonlPath) return null;

  try {
    await fsp.access(jsonlPath);
  } catch {
    return null;
  }

  let inputTokens = 0;
  let cacheReadTokens = 0;
  let cacheCreationTokens = 0;
  let model: string | null = null;
  let found = false;

  // The latest usage is near the end, but jsonl is line-oriented and we can't
  // cheaply seek backwards, so we stream forward keeping the last match.
  const stream = createReadStream(jsonlPath, { encoding: 'utf8' });
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
  try {
    for await (const line of rl) {
      if (!line) continue;
      let entry: { type?: string; message?: { usage?: Record<string, number>; model?: string } };
      try {
        entry = JSON.parse(line);
      } catch {
        continue;
      }
      const usage = entry?.message?.usage;
      if (entry?.type !== 'assistant' || !usage) continue;
      inputTokens = usage.input_tokens ?? 0;
      cacheReadTokens = usage.cache_read_input_tokens ?? 0;
      cacheCreationTokens = usage.cache_creation_input_tokens ?? 0;
      model = entry.message?.model ?? null;
      found = true;
    }
  } finally {
    rl.close();
    stream.destroy();
  }

  if (!found) return null;

  const contextTokens = inputTokens + cacheReadTokens + cacheCreationTokens;
  const windowTokens = resolveContextWindow(model);
  const pct = Math.round((contextTokens / windowTokens) * 100);

  return {
    contextTokens,
    windowTokens,
    pct,
    ...(model ? { model } : {}),
  };
}
