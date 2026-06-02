import type { WebSocket } from 'ws';

import { connectedClients } from '@/modules/websocket/services/websocket-state.service.js';
import { WebSocketWriter } from '@/modules/websocket/services/websocket-writer.service.js';
import type {
  AnyRecord,
  AuthenticatedWebSocketRequest,
  LLMProvider,
} from '@/shared/types.js';
import { createNormalizedMessage, parseIncomingJsonObject } from '@/shared/utils.js';

type ChatIncomingMessage = AnyRecord & {
  type?: string;
  command?: string;
  options?: AnyRecord;
  provider?: string;
  sessionId?: string;
  requestId?: string;
  allow?: unknown;
  updatedInput?: unknown;
  message?: unknown;
  rememberEntry?: unknown;
  answers?: unknown;
  approve?: unknown;
};

const DEFAULT_PROVIDER: LLMProvider = 'claude';

type ChatWebSocketDependencies = {
  queryClaudeSDK: (command: string, options: unknown, writer: WebSocketWriter) => Promise<unknown>;
  abortClaudeSDKSession: (sessionId: string) => Promise<boolean>;
  resolveToolApproval: (
    requestId: string,
    payload: {
      allow: boolean;
      updatedInput?: unknown;
      message?: string;
      rememberEntry?: unknown;
    }
  ) => void;
  /**
   * Resolve a pending interactive approval from an IM-shaped answer
   * (AskUserQuestion `answers` / ExitPlanMode `approve`). The server reconstructs
   * `updatedInput` from the pending request's STORED tool input, so the caller
   * need not echo it back. Returns ok / not_found / bad_request.
   */
  resolveInteractiveAnswer: (
    requestId: string,
    payload: { answers?: unknown; approve?: unknown }
  ) => { ok: boolean; code?: string };
  isClaudeSDKSessionActive: (sessionId: string) => boolean;
  reconnectSessionWriter: (sessionId: string, ws: WebSocket) => boolean;
  getPendingApprovalsForSession: (sessionId: string) => unknown[];
  getActiveClaudeSDKSessions: () => unknown;
};

/**
 * Extracts the authenticated request user id in the formats currently produced
 * by platform and OSS auth code paths.
 */
function readRequestUserId(
  request: AuthenticatedWebSocketRequest | undefined
): string | number | null {
  const user = request?.user;
  if (!user) {
    return null;
  }

  if (typeof user.id === 'string' || typeof user.id === 'number') {
    return user.id;
  }

  if (typeof user.userId === 'string' || typeof user.userId === 'number') {
    return user.userId;
  }

  return null;
}

/**
 * Handles authenticated chat websocket messages used by the main chat panel.
 */
export function handleChatConnection(
  ws: WebSocket,
  request: AuthenticatedWebSocketRequest,
  dependencies: ChatWebSocketDependencies
): void {
  console.log('[INFO] Chat WebSocket connected');
  connectedClients.add(ws);

  const writer = new WebSocketWriter(ws, readRequestUserId(request));

  ws.on('message', async (rawMessage) => {
    try {
      const parsed = parseIncomingJsonObject(rawMessage);
      if (!parsed) {
        throw new Error('Invalid websocket payload');
      }

      const data = parsed as ChatIncomingMessage;
      const messageType = data.type;
      if (!messageType) {
        throw new Error('Message type is required');
      }

      // Client-driven heartbeat. Browsers can't send native WS ping frames, so
      // the web client sends an app-level {type:'ping'} every ~25s and treats a
      // long silence as a dead ("假死") connection. Reply immediately so the
      // client's liveness watchdog stays satisfied while the socket is healthy.
      if (messageType === 'ping') {
        writer.send({ type: 'pong' });
        return;
      }

      if (messageType === 'claude-command') {
        await dependencies.queryClaudeSDK(data.command ?? '', data.options, writer);
        return;
      }

      if (messageType === 'abort-session') {
        const provider: LLMProvider = DEFAULT_PROVIDER;
        const sessionId = typeof data.sessionId === 'string' ? data.sessionId : '';
        let success = false;

        success = await dependencies.abortClaudeSDKSession(sessionId);

        writer.send(
          createNormalizedMessage({
            kind: 'complete',
            exitCode: success ? 0 : 1,
            aborted: true,
            success,
            sessionId,
            provider,
          })
        );
        return;
      }

      if (messageType === 'claude-permission-response') {
        if (typeof data.requestId === 'string' && data.requestId.length > 0) {
          // IM shape: AskUserQuestion `answers` / ExitPlanMode `approve` — the
          // server reconstructs updatedInput from the stored tool input. Falls
          // back to the classic {allow, updatedInput} shape otherwise.
          const hasImAnswer =
            (data.answers !== undefined && data.answers !== null) ||
            typeof data.approve === 'boolean';
          if (hasImAnswer) {
            dependencies.resolveInteractiveAnswer(data.requestId, {
              answers: data.answers,
              approve: data.approve,
            });
          } else {
            dependencies.resolveToolApproval(data.requestId, {
              allow: Boolean(data.allow),
              updatedInput: data.updatedInput,
              message: typeof data.message === 'string' ? data.message : undefined,
              rememberEntry: data.rememberEntry,
            });
          }
        }
        return;
      }

      if (messageType === 'check-session-status') {
        const provider: LLMProvider = DEFAULT_PROVIDER;
        const sessionId = typeof data.sessionId === 'string' ? data.sessionId : '';
        let isActive = false;

        isActive = dependencies.isClaudeSDKSessionActive(sessionId);
        if (isActive) {
          dependencies.reconnectSessionWriter(sessionId, ws);
        }

        writer.send({
          type: 'session-status',
          sessionId,
          provider,
          isProcessing: isActive,
        });
        return;
      }

      if (messageType === 'get-pending-permissions') {
        const sessionId = typeof data.sessionId === 'string' ? data.sessionId : '';
        if (sessionId && dependencies.isClaudeSDKSessionActive(sessionId)) {
          const pending = dependencies.getPendingApprovalsForSession(sessionId);
          writer.send({
            type: 'pending-permissions-response',
            sessionId,
            data: pending,
          });
        }
        return;
      }

      if (messageType === 'get-active-sessions') {
        writer.send({
          type: 'active-sessions',
          sessions: {
            claude: dependencies.getActiveClaudeSDKSessions(),
          },
        });
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error('[ERROR] Chat WebSocket error:', message);
      writer.send({
        type: 'error',
        error: message,
      });
    }
  });

  ws.on('close', () => {
    console.log('[INFO] Chat client disconnected');
    connectedClients.delete(ws);
  });
}
