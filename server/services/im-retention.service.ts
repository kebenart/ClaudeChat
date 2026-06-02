import { imDb } from '@/modules/database/index.js';

/** IM conversations are retained for this many days of inactivity. Active
 *  conversations keep refreshing last_activity_at, so they're never pruned. */
export const IM_RETENTION_DAYS = 3;

export const IM_RETENTION_MS = IM_RETENTION_DAYS * 24 * 60 * 60 * 1000;

/** Delete conversations whose last activity is older than the retention window.
 *  `now` is injectable for tests. Returns the number of conversations removed. */
export function pruneExpiredConversations(now: number = Date.now()): number {
  return imDb.pruneConversationsOlderThan(now - IM_RETENTION_MS);
}
