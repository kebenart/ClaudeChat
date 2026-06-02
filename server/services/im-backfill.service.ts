import { sessionsDb } from '@/modules/database/index.js';
import { ingestSessionJsonl } from '@/services/im-ingest.service.js';
import { IM_RETENTION_MS } from '@/services/im-retention.service.js';

/**
 * One-time startup backfill: distill recently-active existing sessions into the
 * IM hub so the conversation list is populated immediately, without waiting for
 * a live jsonl change. Only sessions updated within the retention window are
 * backfilled (older ones would be pruned anyway); bounded by `limit`.
 */
export async function backfillRecentSessions(limit = 50, now: number = Date.now()): Promise<number> {
  const cutoff = now - IM_RETENTION_MS;
  const sessions = sessionsDb.getAllSessions();
  const recent = sessions
    .filter((s) => typeof s.jsonl_path === 'string' && s.jsonl_path.length > 0)
    .filter((s) => (Date.parse(s.updated_at ?? s.created_at ?? '') || 0) >= cutoff)
    .sort((a, b) => {
      const ta = Date.parse(a.updated_at ?? a.created_at ?? '') || 0;
      const tb = Date.parse(b.updated_at ?? b.created_at ?? '') || 0;
      return tb - ta;
    })
    .slice(0, limit);

  let count = 0;
  for (const s of recent) {
    try {
      await ingestSessionJsonl({
        sessionId: s.session_id,
        jsonlPath: s.jsonl_path as string,
        contactId: s.project_path ?? null,
        title: s.custom_name ?? null,
      });
      count += 1;
    } catch {
      // Skip unreadable/missing files; the watcher will pick up live changes.
    }
  }
  return count;
}
