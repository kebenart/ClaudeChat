import { WS_OPEN_STATE, connectedClients } from '@/modules/websocket/index.js';
import type { ImMessageRow, RealtimeClientConnection } from '@/shared/types.js';

interface SerializedMessage {
  id: string;
  conversationId: string;
  seq: number;
  role: string;
  kind: string;
  content: string;
  createdAt: number;
  truncated?: boolean;
  fullLength?: number;
  toolTrace?: { count: number; rawRefStart: string; rawRefEnd: string };
}

// Bodies longer than this are sent as a truncated preview; clients lazy-load the
// full text via GET /api/im/conversations/:cid/messages/:mid/content. Keeps /sync
// and im:message frames small. Short messages are serialized unchanged.
export const IM_CONTENT_PREVIEW_LIMIT = 800;

/** Convert a DB row into the protocol message shape (camelCase, toolTrace folded). */
export function serializeMessage(row: ImMessageRow): SerializedMessage {
  const fullLength = row.content.length;
  // choice + image carry a small structured JSON payload clients must parse
  // whole (choice: requestId + questions/plan + answered; image: mediaId +
  // caption). Never truncate — a sliced JSON string is unparseable. Everything
  // else uses the preview-then-lazy-load path.
  const isTruncated =
    row.kind !== 'choice' && row.kind !== 'image' && fullLength > IM_CONTENT_PREVIEW_LIMIT;
  const base: SerializedMessage = {
    id: row.source_id,
    conversationId: row.conversation_id,
    seq: row.seq,
    role: row.role,
    kind: row.kind,
    content: isTruncated ? row.content.slice(0, IM_CONTENT_PREVIEW_LIMIT) : row.content,
    createdAt: row.created_at,
  };
  if (isTruncated) {
    base.truncated = true;
    base.fullLength = fullLength;
  }
  if (row.tool_trace_count > 0 && row.raw_ref_start && row.raw_ref_end) {
    base.toolTrace = {
      count: row.tool_trace_count,
      rawRefStart: row.raw_ref_start,
      rawRefEnd: row.raw_ref_end,
    };
  }
  return base;
}

export function buildImMessageEvent(row: ImMessageRow) {
  return { type: 'im:message' as const, message: serializeMessage(row) };
}

export function buildImReadEvent(conversationId: string, deviceId: string, lastReadSeq: number) {
  return { type: 'im:read' as const, conversationId, deviceId, lastReadSeq };
}

export function buildImPokeEvent(since: number) {
  return { type: 'im:poke' as const, since };
}

/**
 * Coarse live-progress frame broadcast while an agentic turn runs. This is NOT a
 * message: it is not stored in im_messages and must not trigger a window reload.
 * Clients render it on the "正在输入…" (typing) row. A terminal
 * `isProcessing:false` frame clears that row at turn completion.
 */
export function buildImStatusEvent(args: {
  conversationId: string;
  isProcessing: boolean;
  toolCount: number;
  currentTool: string | null;
}) {
  return {
    type: 'im:status' as const,
    conversationId: args.conversationId,
    isProcessing: args.isProcessing,
    toolCount: args.toolCount,
    currentTool: args.currentTool,
  };
}

/** Broadcast an IM event frame to every open chat WS client. */
export function broadcastImEvent(frame: unknown): void {
  const payload = JSON.stringify(frame);
  connectedClients.forEach((client: RealtimeClientConnection) => {
    if (client.readyState === WS_OPEN_STATE) {
      client.send(payload);
    }
  });
}
