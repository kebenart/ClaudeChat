import { getConnection } from '@/modules/database/connection.js';
import type { DistilledMessage, ImMessageRow, ImConversationRow, ImReadCursorRow } from '@/shared/types.js';

export type { ImMessageRow, ImConversationRow, ImReadCursorRow } from '@/shared/types.js';

export const imDb = {
  ensureConversation(id: string, contactId: string | null, title: string | null): void {
    const db = getConnection();
    db.prepare(
      `INSERT INTO im_conversations (id, contact_id, title)
       VALUES (?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         contact_id = COALESCE(excluded.contact_id, im_conversations.contact_id),
         title = COALESCE(excluded.title, im_conversations.title)`
    ).run(id, contactId, title);
  },

  getMaxSeq(conversationId: string): number {
    const db = getConnection();
    const row = db
      .prepare('SELECT COALESCE(MAX(seq), 0) AS max_seq FROM im_messages WHERE conversation_id = ?')
      .get(conversationId) as { max_seq: number };
    return row.max_seq;
  },

  /**
   * Upsert distilled messages keyed on (conversation_id, source_id):
   *  - a never-seen source_id is INSERTed with the next monotonic seq;
   *  - a known source_id whose content/toolTrace changed is UPDATEd in place
   *    (seq preserved) — this is how a streaming assistant turn grows without
   *    orphaning stale partial rows;
   *  - a known source_id with identical content is a no-op.
   * Returns the affected rows (inserted or content-changed), ordered by seq —
   * callers broadcast these as `im:message` frames.
   */
  insertMessages(conversationId: string, messages: DistilledMessage[]): ImMessageRow[] {
    const db = getConnection();
    let seq = imDb.getMaxSeq(conversationId);
    // `rev` is a table-wide monotonic version; bumped on every insert AND
    // in-place update so the /sync cursor re-delivers streaming content edits.
    let rev = (db.prepare('SELECT COALESCE(MAX(rev), 0) AS max_rev FROM im_messages').get() as { max_rev: number }).max_rev;

    const selectExisting = db.prepare(
      `SELECT seq, content, tool_trace_count FROM im_messages
       WHERE conversation_id = ? AND source_id = ?`
    );
    const insert = db.prepare(
      `INSERT INTO im_messages
        (conversation_id, source_id, seq, role, kind, content, tool_trace_count, raw_ref_start, raw_ref_end, created_at, rev)
       VALUES (@conversation_id, @source_id, @seq, @role, @kind, @content, @tool_trace_count, @raw_ref_start, @raw_ref_end, @created_at, @rev)`
    );
    const update = db.prepare(
      `UPDATE im_messages
         SET content = @content, tool_trace_count = @tool_trace_count,
             raw_ref_start = @raw_ref_start, raw_ref_end = @raw_ref_end, created_at = @created_at, rev = @rev
       WHERE conversation_id = @conversation_id AND source_id = @source_id`
    );
    const updateConv = db.prepare(
      `UPDATE im_conversations
         SET last_seq = (SELECT COALESCE(MAX(seq), 0) FROM im_messages WHERE conversation_id = @id),
             last_message_preview = (
               SELECT substr(content, 1, 120) FROM im_messages
               WHERE conversation_id = @id ORDER BY seq DESC LIMIT 1
             ),
             last_activity_at = (
               SELECT created_at FROM im_messages
               WHERE conversation_id = @id ORDER BY seq DESC LIMIT 1
             )
       WHERE id = @id`
    );
    const clearDeleted = db.prepare('UPDATE im_conversations SET is_deleted = 0 WHERE id = ?');

    const affectedSeqs: number[] = [];
    let hadNewMessage = false;

    const tx = db.transaction((rows: DistilledMessage[]) => {
      for (const m of rows) {
        const toolCount = m.toolTrace?.count ?? 0;
        const params = {
          conversation_id: conversationId,
          source_id: m.sourceId,
          role: m.role,
          kind: m.kind,
          content: m.content,
          tool_trace_count: toolCount,
          raw_ref_start: m.toolTrace?.rawRefStart ?? null,
          raw_ref_end: m.toolTrace?.rawRefEnd ?? null,
          created_at: m.createdAt,
        };
        const existing = selectExisting.get(conversationId, m.sourceId) as
          | { seq: number; content: string; tool_trace_count: number }
          | undefined;

        if (!existing) {
          seq += 1;
          rev += 1;
          insert.run({ ...params, seq, rev });
          affectedSeqs.push(seq);
          hadNewMessage = true;
        } else if (existing.content !== m.content || existing.tool_trace_count !== toolCount) {
          rev += 1;
          update.run({ ...params, rev });
          affectedSeqs.push(existing.seq);
        }
      }
      // Derive conversation meta from the actual newest (max-seq) row so an
      // update to an OLDER message never clobbers the preview / activity.
      if (affectedSeqs.length > 0) {
        updateConv.run({ id: conversationId });
      }
      // Resurrect (WeChat-style): a genuinely NEW inbound message (a new
      // source_id — not just a content edit of an existing turn) un-hides a
      // soft-deleted conversation. A content-only update leaves hadNewMessage
      // false, so re-ingesting a growing turn won't keep flipping a deleted chat
      // back. The Apple clients already resurrect locally on the im:message frame
      // (applyFrame rebuilds the conv with isDeleted defaulting to false), so
      // this just keeps the server in agreement — the next /sync won't re-hide it.
      if (hadNewMessage) {
        clearDeleted.run(conversationId);
      }
    });
    tx(messages);

    if (affectedSeqs.length === 0) {
      return [];
    }
    const placeholders = affectedSeqs.map(() => '?').join(', ');
    return db
      .prepare(
        `SELECT * FROM im_messages WHERE conversation_id = ? AND seq IN (${placeholders})
         ORDER BY seq ASC`
      )
      .all(conversationId, ...affectedSeqs) as ImMessageRow[];
  },

  /**
   * Full body of a single message, looked up by the SAME id clients receive in
   * /sync (the serialized `id` == `source_id`). Returns null if not found.
   * Backs the lazy full-text endpoint for long, truncated messages.
   */
  getMessageContent(conversationId: string, sourceId: string): string | null {
    const db = getConnection();
    const row = db
      .prepare('SELECT content FROM im_messages WHERE conversation_id = ? AND source_id = ?')
      .get(conversationId, sourceId) as { content: string } | undefined;
    return row ? row.content : null;
  },

  listMessages(
    conversationId: string,
    opts: { anchorSeq?: number; numBefore: number; numAfter: number }
  ): ImMessageRow[] {
    const db = getConnection();
    const anchor = opts.anchorSeq ?? Number.MAX_SAFE_INTEGER;
    const before = db
      .prepare(
        `SELECT * FROM im_messages WHERE conversation_id = ? AND seq < ?
         ORDER BY seq DESC LIMIT ?`
      )
      .all(conversationId, anchor, opts.numBefore) as ImMessageRow[];
    const after = db
      .prepare(
        `SELECT * FROM im_messages WHERE conversation_id = ? AND seq >= ?
         ORDER BY seq ASC LIMIT ?`
      )
      .all(conversationId, anchor, opts.numAfter) as ImMessageRow[];
    return [...before.reverse(), ...after];
  },

  listConversations(): ImConversationRow[] {
    const db = getConnection();
    return db
      .prepare('SELECT * FROM im_conversations ORDER BY is_pinned DESC, last_activity_at DESC')
      .all() as ImConversationRow[];
  },

  /** Delete a conversation and all its messages + read cursors (atomic). */
  deleteConversation(id: string): void {
    const db = getConnection();
    const tx = db.transaction((cid: string) => {
      db.prepare('DELETE FROM im_messages WHERE conversation_id = ?').run(cid);
      db.prepare('DELETE FROM im_read_cursors WHERE conversation_id = ?').run(cid);
      db.prepare('DELETE FROM im_conversations WHERE id = ?').run(cid);
    });
    tx(id);
  },

  /** Delete every conversation belonging to a contact (project) — used when a
   *  contact is deleted, fully closing its conversations. Returns count removed. */
  deleteConversationsByContact(contactId: string): number {
    const db = getConnection();
    const ids = (db.prepare('SELECT id FROM im_conversations WHERE contact_id = ?').all(contactId) as { id: string }[]).map((r) => r.id);
    if (ids.length === 0) return 0;
    const tx = db.transaction(() => {
      for (const id of ids) {
        db.prepare('DELETE FROM im_messages WHERE conversation_id = ?').run(id);
        db.prepare('DELETE FROM im_read_cursors WHERE conversation_id = ?').run(id);
      }
      db.prepare('DELETE FROM im_conversations WHERE contact_id = ?').run(contactId);
    });
    tx();
    return ids.length;
  },

  /** Retention sweep: delete conversations whose last activity is older than
   *  `cutoffMs` (epoch ms), with their messages + read cursors. Active
   *  conversations keep a fresh last_activity_at so they're never pruned.
   *  Returns the number of conversations removed. */
  pruneConversationsOlderThan(cutoffMs: number): number {
    const db = getConnection();
    const ids = (db.prepare('SELECT id FROM im_conversations WHERE last_activity_at < ?').all(cutoffMs) as { id: string }[]).map((r) => r.id);
    if (ids.length === 0) return 0;
    const tx = db.transaction(() => {
      const delMsgs = db.prepare('DELETE FROM im_messages WHERE conversation_id = ?');
      const delCursors = db.prepare('DELETE FROM im_read_cursors WHERE conversation_id = ?');
      for (const id of ids) {
        delMsgs.run(id);
        delCursors.run(id);
      }
      db.prepare('DELETE FROM im_conversations WHERE last_activity_at < ?').run(cutoffMs);
    });
    tx();
    return ids.length;
  },

  setConversationState(
    id: string,
    state: { isPinned?: boolean; isMuted?: boolean; isFolded?: boolean; isDeleted?: boolean; note?: string | null },
  ): void {
    const db = getConnection();
    if (state.isPinned !== undefined) {
      db.prepare('UPDATE im_conversations SET is_pinned = ? WHERE id = ?').run(state.isPinned ? 1 : 0, id);
    }
    if (state.isMuted !== undefined) {
      db.prepare('UPDATE im_conversations SET is_muted = ? WHERE id = ?').run(state.isMuted ? 1 : 0, id);
    }
    if (state.isFolded !== undefined) {
      db.prepare('UPDATE im_conversations SET is_folded = ? WHERE id = ?').run(state.isFolded ? 1 : 0, id);
    }
    if (state.isDeleted !== undefined) {
      // Soft delete: hidden on every client. A later inbound message resurrects
      // it (insertMessages clears the flag), so a live conversation is never
      // lost — mirrors WeChat's "delete chat".
      db.prepare('UPDATE im_conversations SET is_deleted = ? WHERE id = ?').run(state.isDeleted ? 1 : 0, id);
    }
    if (state.note !== undefined) {
      const trimmed = state.note?.trim() ?? '';
      db.prepare('UPDATE im_conversations SET note = ? WHERE id = ?').run(trimmed || null, id);
    }
  },

  // MARK: Blacklist (server-synced project paths)

  listBlacklist(): string[] {
    const db = getConnection();
    return (db.prepare('SELECT path FROM im_blacklist ORDER BY path').all() as { path: string }[])
      .map((r) => r.path);
  },

  addBlacklist(path: string, now: number): void {
    const p = path.trim();
    if (!p) return;
    getConnection()
      .prepare('INSERT OR IGNORE INTO im_blacklist (path, created_at) VALUES (?, ?)')
      .run(p, now);
  },

  removeBlacklist(path: string): void {
    getConnection().prepare('DELETE FROM im_blacklist WHERE path = ?').run(path.trim());
  },

  setReadCursor(conversationId: string, deviceId: string, lastReadSeq: number): void {
    const db = getConnection();
    db.prepare(
      `INSERT INTO im_read_cursors (conversation_id, device_id, last_read_seq, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(conversation_id, device_id) DO UPDATE SET
         last_read_seq = MAX(im_read_cursors.last_read_seq, excluded.last_read_seq),
         updated_at = excluded.updated_at`
    ).run(conversationId, deviceId, lastReadSeq, Date.now());
  },

  getReadCursors(): ImReadCursorRow[] {
    const db = getConnection();
    return db.prepare('SELECT * FROM im_read_cursors').all() as ImReadCursorRow[];
  },

  /**
   * Global incremental sync keyed on `rev` (monotonic, bumped on insert AND
   * in-place update) so a client re-receives streaming content edits even if it
   * already synced past the row. Returns rows with rev > cursor + new cursor.
   */
  getMessagesSince(cursor: number, limit: number): { rows: ImMessageRow[]; cursor: number; hasMore: boolean } {
    const db = getConnection();
    const rows = db
      .prepare('SELECT * FROM im_messages WHERE rev > ? ORDER BY rev ASC LIMIT ?')
      .all(cursor, limit + 1) as ImMessageRow[];
    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;
    const newCursor = page.length > 0 ? page[page.length - 1].rev : cursor;
    return { rows: page, cursor: newCursor, hasMore };
  },

  /** Highest `rev` in the table (0 if empty) — the cold-start cursor watermark. */
  getMaxRev(): number {
    const db = getConnection();
    const row = db.prepare('SELECT MAX(rev) AS m FROM im_messages').get() as { m: number | null };
    return row.m ?? 0;
  },

  /**
   * Cold-start payload: the last `n` messages of EACH conversation (seq order).
   * A handful of conversations hold thousands of messages, so a full /sync
   * downloaded ~5000 rows and pegged the client CPU. This caps it to recent-N
   * per conversation; older history is lazy-loaded via listMessages on demand.
   */
  getRecentMessagesPerConversation(n: number): ImMessageRow[] {
    const db = getConnection();
    return db
      .prepare(
        `SELECT * FROM (
           SELECT *, ROW_NUMBER() OVER (PARTITION BY conversation_id ORDER BY seq DESC) AS rn
           FROM im_messages
         ) WHERE rn <= ? ORDER BY conversation_id ASC, seq ASC`
      )
      .all(n) as ImMessageRow[];
  },

  /**
   * True if a USER message with the exact same trimmed `content` was recorded in
   * this conversation at or after `sinceMs`. Backstop for the terminal hook: on a
   * brand-new app session the SDK records the user bubble (keyed by clientMsgId)
   * a hair before the hook's cross-process POST lands, and the hook would key the
   * same text under a DIFFERENT sourceId — a duplicate. This lets the hook skip a
   * user message the SDK already captured, independent of sourceId.
   */
  hasRecentUserMessage(conversationId: string, content: string, sinceMs: number): boolean {
    const db = getConnection();
    const row = db
      .prepare(
        `SELECT 1 FROM im_messages
         WHERE conversation_id = ? AND role = 'user' AND content = ? AND created_at >= ?
         LIMIT 1`
      )
      .get(conversationId, content, sinceMs);
    return row !== undefined;
  },
};
