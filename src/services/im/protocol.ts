// Wire shapes (mirror server serializeMessage + /api/im routes).

export interface WireMessage {
  id: string;
  conversationId: string;
  seq: number;
  role: string;
  kind: string;
  content: string;
  createdAt: number;
  toolTrace?: { count: number; rawRefStart: string; rawRefEnd: string };
  /** Server P2 long-message truncation: when true, `content` holds only the
   *  first 800 chars and the full body must be lazy-fetched via
   *  fetchMessageContent. Absent on short (≤800 char) messages. */
  truncated?: boolean;
  /** Total length of the full (un-truncated) body. Only set when truncated. */
  fullLength?: number;
}

// ── Interactive choice cards (kind:'choice') ──────────────────────────────
// A choice arrives as a normal IM message (over the chat WS as an im:message,
// and in /sync) with kind === 'choice'. Its `content` is a JSON string of one
// of the shapes below (AskUserQuestion pending / ExitPlanMode pending; both
// gain `answered:true` + `answer` once resolved). Mirrors the server's
// ChoiceCardContent in server/services/im-record.service.ts.

export interface ChoiceQuestionOption {
  label: string;
  description?: string;
}

export interface ChoiceQuestion {
  question: string;
  header?: string;
  multiSelect?: boolean;
  options: ChoiceQuestionOption[];
}

export interface ChoiceCardContent {
  requestId: string;
  toolName: 'AskUserQuestion' | 'ExitPlanMode';
  /** Present for AskUserQuestion. */
  questions?: ChoiceQuestion[];
  /** Present for ExitPlanMode (the plan text). */
  plan?: string;
  /** Terminal state: set once the user answers / approves / it is cancelled. */
  answered?: boolean;
  /** Human summary of what was chosen, e.g. "已选择 Red" / "已同意". */
  answer?: string;
}

/** Parse the JSON `content` of a kind:'choice' message into a typed card.
 *  Returns null on malformed payloads so callers can fall back to plain text. */
export function parseChoiceCard(content: string): ChoiceCardContent | null {
  try {
    const parsed = JSON.parse(content) as Partial<ChoiceCardContent>;
    if (
      !parsed ||
      typeof parsed.requestId !== 'string' ||
      (parsed.toolName !== 'AskUserQuestion' && parsed.toolName !== 'ExitPlanMode')
    ) {
      return null;
    }
    return parsed as ChoiceCardContent;
  } catch {
    return null;
  }
}

// ── Assistant-sent images (kind:'image') ──────────────────────────────────
// content is a small JSON `{ mediaId, caption }`. The bytes are fetched from
// GET /api/im/media/:mediaId (auth'd). Mirrors the server's recordImageMessage.

export interface ImageCardContent {
  mediaId: string;
  caption?: string;
  /** Original (full-res) byte size, for the "查看原图 (N MB)" affordance. */
  bytes?: number;
}

/** Parse the JSON `content` of a kind:'image' message. Returns null on a
 *  malformed payload or a media id that isn't the expected `<hex>.<ext>`. */
export function parseImageCard(content: string): ImageCardContent | null {
  try {
    const parsed = JSON.parse(content) as Partial<ImageCardContent>;
    if (
      !parsed ||
      typeof parsed.mediaId !== 'string' ||
      !/^[0-9a-f]{32}\.(png|jpe?g|gif|webp)$/.test(parsed.mediaId)
    ) {
      return null;
    }
    return {
      mediaId: parsed.mediaId,
      caption: typeof parsed.caption === 'string' ? parsed.caption : undefined,
      bytes: typeof parsed.bytes === 'number' ? parsed.bytes : undefined,
    };
  } catch {
    return null;
  }
}

export interface WireConversation {
  id: string;
  contactId: string | null;
  providerId: string;
  title: string | null;
  lastMessagePreview: string | null;
  lastSeq: number;
  lastActivityAt: number;
  isPinned: boolean;
  isMuted: boolean;
  /** Server-synced custom nickname (备注名). */
  note?: string | null;
  /** Server-synced WeChat "折叠的聊天" flag. */
  isFolded?: boolean;
  /** Server-synced "已删除" flag (WeChat-style delete-chat). Hidden on every
   *  client; resurrected server-side when a new message arrives. */
  isDeleted?: boolean;
}

export interface WireReadCursor {
  conversationId: string;
  deviceId: string;
  lastReadSeq: number;
}

export interface SyncResponse {
  messages: WireMessage[];
  conversations: WireConversation[];
  readCursors: WireReadCursor[];
  cursor: number;
  hasMore: boolean;
}

// Incoming WS frames we care about.
export type ImFrame =
  | { type: 'im:message'; message: WireMessage }
  | { type: 'im:read'; conversationId: string; deviceId: string; lastReadSeq: number }
  | { type: 'im:poke'; since: number }
  | {
      type: 'im:status';
      conversationId: string;
      isProcessing: boolean;
      toolCount: number;
      currentTool: string | null;
    };

/** Per-conversation live progress derived from im:status frames. Cleared once
 *  the terminal `isProcessing:false` frame for that conversation arrives. */
export interface ImConversationProgress {
  isProcessing: boolean;
  toolCount: number;
  currentTool: string | null;
}

export function isImFrame(value: unknown): value is ImFrame {
  return (
    typeof value === 'object' &&
    value !== null &&
    typeof (value as { type?: unknown }).type === 'string' &&
    (value as { type: string }).type.startsWith('im:')
  );
}
