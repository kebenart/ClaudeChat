/**
 * Claude SDK Integration
 *
 * This module provides SDK-based integration with Claude using the @anthropic-ai/claude-agent-sdk.
 * It mirrors the interface of claude-cli.js but uses the SDK internally for better performance
 * and maintainability.
 *
 * Key features:
 * - Direct SDK integration without child processes
 * - Session management with abort capability
 * - Options mapping between CLI and SDK formats
 * - WebSocket message streaming
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import crypto from 'crypto';
import { promises as fs } from 'fs';
import path from 'path';
import os from 'os';
import { CLAUDE_MODELS } from '../shared/modelConstants.js';
import { resolveClaudeCodeExecutablePath } from './shared/claude-cli-path.js';
import {
  createNotificationEvent,
  notifyRunFailed,
  notifyRunStopped,
  notifyUserIfEnabled
} from './services/notification-orchestrator.js';
import { sessionsService } from './modules/providers/services/sessions.service.js';
import { providerAuthService } from './modules/providers/services/provider-auth.service.js';
import { createNormalizedMessage, resolveContextWindow } from './shared/utils.js';
import { sessionsDb } from './modules/database/index.js';
import {
  recordUserMessage,
  recordAssistantMessage,
  recordChoiceCard,
  resolveChoiceCard,
  beginSdkTurn,
  endSdkTurn,
} from './services/im-record.service.js';
import { buildImStatusEvent, broadcastImEvent } from './services/im-events.service.js';

const activeSessions = new Map();
const pendingToolApprovals = new Map();

// Idempotency guard for "reliable send": a client may resend a message after a
// lost ack (bad network), so we dedup by `options.clientMsgId`. Keeps a
// Map<clientMsgId, timestamp>; a duplicate within the TTL is skipped entirely
// (no second Claude invocation → no double reply / double cost). Swept on each
// call so it can't grow unbounded.
const recentClientMsgIds = new Map();
const CLIENT_MSG_DEDUP_TTL_MS = 5 * 60 * 1000;

const TOOL_APPROVAL_TIMEOUT_MS = parseInt(process.env.CLAUDE_TOOL_APPROVAL_TIMEOUT_MS, 10) || 55000;

const TOOLS_REQUIRING_INTERACTION = new Set(['AskUserQuestion', 'ExitPlanMode']);

function createRequestId() {
  if (typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  return crypto.randomBytes(16).toString('hex');
}

function waitForToolApproval(requestId, options = {}) {
  const { timeoutMs = TOOL_APPROVAL_TIMEOUT_MS, signal, onCancel, metadata } = options;

  return new Promise(resolve => {
    let settled = false;

    const finalize = (decision) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(decision);
    };

    let timeout;

    const cleanup = () => {
      pendingToolApprovals.delete(requestId);
      if (timeout) clearTimeout(timeout);
      if (signal && abortHandler) {
        signal.removeEventListener('abort', abortHandler);
      }
    };

    // timeoutMs 0 = wait indefinitely (interactive tools)
    if (timeoutMs > 0) {
      timeout = setTimeout(() => {
        onCancel?.('timeout');
        finalize(null);
      }, timeoutMs);
    }

    const abortHandler = () => {
      onCancel?.('cancelled');
      finalize({ cancelled: true });
    };

    if (signal) {
      if (signal.aborted) {
        onCancel?.('cancelled');
        finalize({ cancelled: true });
        return;
      }
      signal.addEventListener('abort', abortHandler, { once: true });
    }

    const resolver = (decision) => {
      finalize(decision);
    };
    // Attach metadata for getPendingApprovalsForSession lookup
    if (metadata) {
      Object.assign(resolver, metadata);
    }
    pendingToolApprovals.set(requestId, resolver);
  });
}

function resolveToolApproval(requestId, decision) {
  const resolver = pendingToolApprovals.get(requestId);
  if (resolver) {
    resolver(decision);
  }
}

/**
 * Test-only: register a pending interactive approval exactly as the live
 * interception does (same metadata keys the REST/WS reconstruction reads),
 * returning a promise that settles with the decision once resolved. Lets tests
 * exercise resolveInteractiveAnswer / the /respond route without a real query.
 */
function __registerPendingApprovalForTests(requestId, { sessionId, toolName, input }) {
  return waitForToolApproval(requestId, {
    timeoutMs: 0,
    metadata: { _sessionId: sessionId ?? null, _toolName: toolName, _input: input, _receivedAt: new Date() },
  });
}

/**
 * Look up a pending interactive approval by requestId. Returns the metadata
 * stashed on the resolver (sessionId, toolName, the ORIGINAL tool input) or null
 * if there's no such pending request. The REST `/respond` route uses this to
 * reconstruct the decision from the stored input it never saw.
 */
function getPendingApprovalInfo(requestId) {
  const resolver = pendingToolApprovals.get(requestId);
  if (!resolver) return null;
  return {
    requestId,
    sessionId: resolver._sessionId || null,
    toolName: resolver._toolName || null,
    input: resolver._input,
  };
}

/**
 * Turn an IM-shaped answer ({answers} for AskUserQuestion / {approve} for
 * ExitPlanMode) into a `canUseTool`/hook decision relative to a stored tool
 * input. Shared by the WS handler, the REST route, and the interactive-tool
 * interception so all three speak one contract.
 *
 * AskUserQuestion: `answers` maps question text → selected labels; we fold each
 * to a comma-joined string under `updatedInput.answers` (the exact shape the
 * original web panel produced), preserving the rest of the stored input.
 * ExitPlanMode: `approve:true` allows, `approve:false` denies.
 *
 * Returns `{ allow, updatedInput?, message? }` or null if the payload doesn't
 * carry an IM-shaped answer for this tool.
 */
function buildDecisionFromImAnswer(toolName, storedInput, payload) {
  if (!payload || typeof payload !== 'object') return null;

  if (toolName === 'ExitPlanMode') {
    if (typeof payload.approve === 'boolean') {
      return payload.approve
        ? { allow: true, updatedInput: storedInput }
        : { allow: false, message: 'Plan rejected by user' };
    }
    return null;
  }

  // AskUserQuestion (and any future question-style tool)
  const answers = payload.answers;
  if (answers && typeof answers === 'object') {
    const folded = {};
    for (const [question, labels] of Object.entries(answers)) {
      folded[question] = Array.isArray(labels) ? labels.join(', ') : String(labels);
    }
    const base = storedInput && typeof storedInput === 'object' ? storedInput : {};
    return { allow: true, updatedInput: { ...base, answers: folded } };
  }
  return null;
}

/**
 * Build the short human summary shown on the resolved choice card ("已选择 …" /
 * "已同意"). For AskUserQuestion it reads the folded answers off updatedInput; for
 * ExitPlanMode an allow means the plan was approved.
 */
function summarizeInteractiveAnswer(toolName, originalInput, updatedInput) {
  if (toolName === 'ExitPlanMode') return '已同意';
  const answers = updatedInput && typeof updatedInput === 'object' ? updatedInput.answers : null;
  if (answers && typeof answers === 'object') {
    const parts = Object.values(answers).map(v => (Array.isArray(v) ? v.join(', ') : String(v))).filter(Boolean);
    if (parts.length > 0) return `已选择 ${parts.join(' / ')}`;
  }
  return '已选择';
}

/**
 * Resolve a pending interactive approval from an IM-shaped answer, identified by
 * requestId alone (the caller — REST/WS — need not know the stored tool input).
 * Returns:
 *   { ok:true }                 — resolved
 *   { ok:false, code:'not_found' } — no such pending request
 *   { ok:false, code:'bad_request' } — payload doesn't carry a valid answer
 */
function resolveInteractiveAnswer(requestId, payload) {
  // SDK (in-process) pending approval — an awaiting query() resolver.
  const info = getPendingApprovalInfo(requestId);
  if (info) {
    const decision = buildDecisionFromImAnswer(info.toolName, info.input, payload);
    if (!decision) return { ok: false, code: 'bad_request' };
    resolveToolApproval(requestId, decision);
    return { ok: true };
  }
  // Terminal (hook-driven) pending choice — answered via the HTTP poll, no
  // in-process resolver. Stash the decision for the polling hook to pick up.
  const term = pendingTerminalChoices.get(requestId);
  if (term) {
    if (term.decision) return { ok: true }; // already answered — idempotent
    const decision = buildDecisionFromImAnswer(term.toolName, term.input, payload);
    if (!decision) return { ok: false, code: 'bad_request' };
    term.decision = decision;
    try {
      resolveChoiceCard({
        sessionId: term.sessionId,
        contactId: term.contactId,
        title: term.title,
        requestId,
        toolName: term.toolName === 'ExitPlanMode' ? 'ExitPlanMode' : 'AskUserQuestion',
        questions: term.toolName === 'ExitPlanMode' ? undefined : term.questions,
        plan: term.toolName === 'ExitPlanMode' ? term.plan : undefined,
        answer: summarizeInteractiveAnswer(term.toolName, term.input, decision.updatedInput),
      });
    } catch (err) {
      console.error('IM terminal choice resolve failed', err instanceof Error ? err.message : String(err));
    }
    return { ok: true };
  }
  return { ok: false, code: 'not_found' };
}

// ── Terminal (hook-driven) interactive choices ─────────────────────────────
//
// A TERMINAL Claude session (not the SDK) that hits AskUserQuestion/ExitPlanMode
// fires a blocking PreToolUse settings hook (scripts/im-claude-choice-hook.mjs)
// which POSTs the question here and then HTTP-polls for the answer the user gives
// on any device. There is no in-process resolver to await — the decision is
// stashed in this registry for the poll to read. App (SDK) sessions never use
// this path: their PreToolUse is handled in-process (and the /api/im-hook/choice
// route defers when isSdkTurnActive), so there's no double-handling.
const pendingTerminalChoices = new Map(); // requestId -> { sessionId, contactId, title, toolName, input, questions, plan, decision, createdAt }
const TERMINAL_CHOICE_TTL_MS = 15 * 60 * 1000;

function registerTerminalChoice({ requestId, sessionId, contactId, title, toolName, input }) {
  const now = Date.now();
  for (const [id, e] of pendingTerminalChoices) {
    if (now - e.createdAt > TERMINAL_CHOICE_TTL_MS) pendingTerminalChoices.delete(id);
  }
  const questions = toolName === 'AskUserQuestion' && Array.isArray(input?.questions) ? input.questions : [];
  const plan = toolName === 'ExitPlanMode' && typeof input?.plan === 'string' ? input.plan : '';
  try {
    recordChoiceCard({
      sessionId,
      contactId,
      title,
      requestId,
      toolName: toolName === 'ExitPlanMode' ? 'ExitPlanMode' : 'AskUserQuestion',
      questions: toolName === 'ExitPlanMode' ? undefined : questions,
      plan: toolName === 'ExitPlanMode' ? plan : undefined,
    });
  } catch (err) {
    console.error('IM terminal choice record failed', err instanceof Error ? err.message : String(err));
  }
  pendingTerminalChoices.set(requestId, {
    sessionId, contactId, title, toolName, input, questions, plan, decision: null, createdAt: now,
  });
  return requestId;
}

/** Poll target for the choice hook. `{ found, answered, decision? }`. The entry
 *  is removed once the answered decision is read. */
function getTerminalChoiceDecision(requestId) {
  const e = pendingTerminalChoices.get(requestId);
  if (!e) return { found: false };
  if (!e.decision) return { found: true, answered: false };
  pendingTerminalChoices.delete(requestId);
  return { found: true, answered: true, decision: e.decision };
}

// Match stored permission entries against a tool + input combo.
// This only supports exact tool names and the Bash(command:*) shorthand
// used by the UI; it intentionally does not implement full glob semantics,
// introduced to stay consistent with the UI's "Allow rule" format.
function matchesToolPermission(entry, toolName, input) {
  if (!entry || !toolName) {
    return false;
  }

  if (entry === toolName) {
    return true;
  }

  const bashMatch = entry.match(/^Bash\((.+):\*\)$/);
  if (toolName === 'Bash' && bashMatch) {
    const allowedPrefix = bashMatch[1];
    let command = '';

    if (typeof input === 'string') {
      command = input.trim();
    } else if (input && typeof input === 'object' && typeof input.command === 'string') {
      command = input.command.trim();
    }

    if (!command) {
      return false;
    }

    return command.startsWith(allowedPrefix);
  }

  return false;
}

/**
 * Maps CLI options to SDK-compatible options format
 * @param {Object} options - CLI options
 * @returns {Object} SDK-compatible options
 */
function mapCliOptionsToSDK(options = {}) {
  const { sessionId, cwd, toolsSettings, permissionMode } = options;

  const sdkOptions = {};

  // Forward all host env vars (e.g. ANTHROPIC_BASE_URL) to the subprocess.
  // Since SDK 0.2.113, options.env replaces process.env instead of overlaying it.
  sdkOptions.env = { ...process.env };

  // Resolve the executable eagerly on Windows because the SDK uses raw child_process.spawn,
  // which does not reliably follow npm's shell wrappers like cross-spawn does.
  sdkOptions.pathToClaudeCodeExecutable = resolveClaudeCodeExecutablePath(process.env.CLAUDE_CLI_PATH);

  // Map working directory
  if (cwd) {
    sdkOptions.cwd = cwd;
  }

  // Map permission mode
  if (permissionMode && permissionMode !== 'default') {
    sdkOptions.permissionMode = permissionMode;
  }

  // Map tool settings
  const settings = toolsSettings || {
    allowedTools: [],
    disallowedTools: [],
    skipPermissions: false
  };

  // Handle tool permissions
  if (settings.skipPermissions && permissionMode !== 'plan') {
    // When skipping permissions, use bypassPermissions mode
    sdkOptions.permissionMode = 'bypassPermissions';
  }

  let allowedTools = [...(settings.allowedTools || [])];

  // Add plan mode default tools
  if (permissionMode === 'plan') {
    const planModeTools = ['Read', 'Task', 'exit_plan_mode', 'TodoRead', 'TodoWrite', 'WebFetch', 'WebSearch'];
    for (const tool of planModeTools) {
      if (!allowedTools.includes(tool)) {
        allowedTools.push(tool);
      }
    }
  }

  sdkOptions.allowedTools = allowedTools;

  // Use the tools preset to make all default built-in tools available (including AskUserQuestion).
  // This was introduced in SDK 0.1.57. Omitting this preserves existing behavior (all tools available),
  // but being explicit ensures forward compatibility and clarity.
  sdkOptions.tools = { type: 'preset', preset: 'claude_code' };

  sdkOptions.disallowedTools = settings.disallowedTools || [];

  // Map model (default to sonnet)
  // Valid models: sonnet, opus, haiku, opusplan, sonnet[1m]
  sdkOptions.model = options.model || CLAUDE_MODELS.DEFAULT;
  // Model logged at query start below

  // Map system prompt configuration
  sdkOptions.systemPrompt = {
    type: 'preset',
    preset: 'claude_code'  // Required to use CLAUDE.md
  };

  // Map setting sources for CLAUDE.md loading
  // This loads CLAUDE.md from project, user (~/.config/claude/CLAUDE.md), and local directories
  sdkOptions.settingSources = ['project', 'user', 'local'];

  // Map resume session
  if (sessionId) {
    sdkOptions.resume = sessionId;
  }

  return sdkOptions;
}

/**
 * Adds a session to the active sessions map
 * @param {string} sessionId - Session identifier
 * @param {Object} queryInstance - SDK query instance
 * @param {Array<string>} tempImagePaths - Temp image file paths for cleanup
 * @param {string} tempDir - Temp directory for cleanup
 */
function addSession(sessionId, queryInstance, tempImagePaths = [], tempDir = null, writer = null) {
  activeSessions.set(sessionId, {
    instance: queryInstance,
    startTime: Date.now(),
    status: 'active',
    tempImagePaths,
    tempDir,
    writer
  });
}

/**
 * Removes a session from the active sessions map
 * @param {string} sessionId - Session identifier
 */
function removeSession(sessionId) {
  activeSessions.delete(sessionId);
}

/**
 * Gets a session from the active sessions map
 * @param {string} sessionId - Session identifier
 * @returns {Object|undefined} Session data or undefined
 */
function getSession(sessionId) {
  return activeSessions.get(sessionId);
}

/**
 * Gets all active session IDs
 * @returns {Array<string>} Array of active session IDs
 */
function getAllSessions() {
  return Array.from(activeSessions.keys());
}

/**
 * Transforms SDK messages to WebSocket format expected by frontend
 * @param {Object} sdkMessage - SDK message object
 * @returns {Object} Transformed message ready for WebSocket
 */
function transformMessage(sdkMessage) {
  // Extract parent_tool_use_id for subagent tool grouping
  if (sdkMessage.parent_tool_use_id) {
    return {
      ...sdkMessage,
      parentToolUseId: sdkMessage.parent_tool_use_id
    };
  }
  return sdkMessage;
}

/**
 * Extracts token usage from SDK result messages
 * @param {Object} resultMessage - SDK result message
 * @returns {Object|null} Token budget object or null
 */
function extractTokenBudget(resultMessage) {
  if (resultMessage.type !== 'result' || !resultMessage.modelUsage) {
    return null;
  }

  // Get the first model's usage data
  const modelKey = Object.keys(resultMessage.modelUsage)[0];
  const modelData = resultMessage.modelUsage[modelKey];

  if (!modelData) {
    return null;
  }

  // Use cumulative tokens if available (tracks total for the session)
  // Otherwise fall back to per-request tokens
  const inputTokens = modelData.cumulativeInputTokens || modelData.inputTokens || 0;
  const outputTokens = modelData.cumulativeOutputTokens || modelData.outputTokens || 0;
  const cacheReadTokens = modelData.cumulativeCacheReadInputTokens || modelData.cacheReadInputTokens || 0;
  const cacheCreationTokens = modelData.cumulativeCacheCreationInputTokens || modelData.cacheCreationInputTokens || 0;

  // Total used = input + output + cache tokens
  const totalUsed = inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens;

  const contextWindow = resolveContextWindow(modelKey);

  return {
    used: totalUsed,
    total: contextWindow,
    model: modelKey,
  };
}

/**
 * Handles image processing for SDK queries
 * Saves base64 images to temporary files and returns modified prompt with file paths
 * @param {string} command - Original user prompt
 * @param {Array} images - Array of image objects with base64 data
 * @param {string} cwd - Working directory for temp file creation
 * @returns {Promise<Object>} {modifiedCommand, tempImagePaths, tempDir}
 */
async function handleImages(command, images, cwd) {
  const tempImagePaths = [];
  let tempDir = null;

  if (!images || images.length === 0) {
    return { modifiedCommand: command, tempImagePaths, tempDir };
  }

  try {
    // Create temp directory in the project directory
    const workingDir = cwd || process.cwd();
    tempDir = path.join(workingDir, '.tmp', 'images', Date.now().toString());
    await fs.mkdir(tempDir, { recursive: true });

    // Save each image to a temp file
    for (const [index, image] of images.entries()) {
      // Extract base64 data and mime type
      const matches = image.data.match(/^data:([^;]+);base64,(.+)$/);
      if (!matches) {
        console.error('Invalid image data format');
        continue;
      }

      const [, mimeType, base64Data] = matches;
      const extension = mimeType.split('/')[1] || 'png';
      const filename = `image_${index}.${extension}`;
      const filepath = path.join(tempDir, filename);

      // Write base64 data to file
      await fs.writeFile(filepath, Buffer.from(base64Data, 'base64'));
      tempImagePaths.push(filepath);
    }

    // Include the full image paths in the prompt
    let modifiedCommand = command;
    if (tempImagePaths.length > 0 && command && command.trim()) {
      const imageNote = `\n\n[Images provided at the following paths:]\n${tempImagePaths.map((p, i) => `${i + 1}. ${p}`).join('\n')}`;
      modifiedCommand = command + imageNote;
    }

    // Images processed
    return { modifiedCommand, tempImagePaths, tempDir };
  } catch (error) {
    console.error('Error processing images for SDK:', error);
    return { modifiedCommand: command, tempImagePaths, tempDir };
  }
}

/**
 * Cleans up temporary image files
 * @param {Array<string>} tempImagePaths - Array of temp file paths to delete
 * @param {string} tempDir - Temp directory to remove
 */
async function cleanupTempFiles(tempImagePaths, tempDir) {
  if (!tempImagePaths || tempImagePaths.length === 0) {
    return;
  }

  try {
    // Delete individual temp files
    for (const imagePath of tempImagePaths) {
      await fs.unlink(imagePath).catch(err =>
        console.error(`Failed to delete temp image ${imagePath}:`, err)
      );
    }

    // Delete temp directory
    if (tempDir) {
      await fs.rm(tempDir, { recursive: true, force: true }).catch(err =>
        console.error(`Failed to delete temp directory ${tempDir}:`, err)
      );
    }

    // Temp files cleaned
  } catch (error) {
    console.error('Error during temp file cleanup:', error);
  }
}

/**
 * Loads MCP server configurations from ~/.claude.json
 * @param {string} cwd - Current working directory for project-specific configs
 * @returns {Object|null} MCP servers object or null if none found
 */
async function loadMcpConfig(cwd) {
  try {
    const claudeConfigPath = path.join(os.homedir(), '.claude.json');

    // Check if config file exists
    try {
      await fs.access(claudeConfigPath);
    } catch (error) {
      // File doesn't exist, return null
      // No config file
      return null;
    }

    // Read and parse config file
    let claudeConfig;
    try {
      const configContent = await fs.readFile(claudeConfigPath, 'utf8');
      claudeConfig = JSON.parse(configContent);
    } catch (error) {
      console.error('Failed to parse ~/.claude.json:', error.message);
      return null;
    }

    // Extract MCP servers (merge global and project-specific)
    let mcpServers = {};

    // Add global MCP servers
    if (claudeConfig.mcpServers && typeof claudeConfig.mcpServers === 'object') {
      mcpServers = { ...claudeConfig.mcpServers };
      // Global MCP servers loaded
    }

    // Add/override with project-specific MCP servers
    if (claudeConfig.claudeProjects && cwd) {
      const projectConfig = claudeConfig.claudeProjects[cwd];
      if (projectConfig && projectConfig.mcpServers && typeof projectConfig.mcpServers === 'object') {
        mcpServers = { ...mcpServers, ...projectConfig.mcpServers };
        // Project MCP servers merged
      }
    }

    // Return null if no servers found
    if (Object.keys(mcpServers).length === 0) {
      return null;
    }
    return mcpServers;
  } catch (error) {
    console.error('Error loading MCP config:', error.message);
    return null;
  }
}

/**
 * Executes a Claude query using the SDK
 * @param {string} command - User prompt/command
 * @param {Object} options - Query options
 * @param {Object} ws - WebSocket connection
 * @returns {Promise<void>}
 */
async function queryClaudeSDK(command, options = {}, ws) {
  // Idempotency: skip a duplicate send (resend after a lost ack) so we never
  // double-invoke Claude. Sweep expired entries first to bound the map.
  const { clientMsgId } = options;
  if (typeof clientMsgId === 'string' && clientMsgId.length > 0) {
    const now = Date.now();
    for (const [id, ts] of recentClientMsgIds) {
      if (now - ts > CLIENT_MSG_DEDUP_TTL_MS) recentClientMsgIds.delete(id);
    }
    const seenAt = recentClientMsgIds.get(clientMsgId);
    if (seenAt !== undefined && now - seenAt <= CLIENT_MSG_DEDUP_TTL_MS) {
      console.log(`[claude-sdk] dedup: skipping duplicate clientMsgId ${clientMsgId}`);
      return;
    }
    recentClientMsgIds.set(clientMsgId, now);
  }

  // Resume cwd correction: the SDK locates a resumed session by cwd → project
  // dir, but a caller's cwd can be wrong. A terminal session ingested via the
  // hook carries the cwd at hook-fire time, which may have wandered into a
  // subdir (the user cd'd) — its IM contactId then points at the wrong project
  // and `resume` fails with "No conversation found with session ID". The session
  // jsonl always lives under its ORIGINAL project root, which the watcher
  // recorded as `sessions.project_path`. Trust that over the caller's cwd when
  // resuming a known session.
  if (typeof options.sessionId === 'string' && options.sessionId.length > 0) {
    try {
      const realRoot = sessionsDb.getSessionById(options.sessionId)?.project_path;
      if (typeof realRoot === 'string' && realRoot.length > 0 && realRoot !== options.cwd) {
        options = { ...options, cwd: realRoot, projectPath: realRoot };
      }
    } catch {
      /* best-effort — fall back to the caller's cwd */
    }
  }

  const { sessionId, sessionSummary } = options;
  let capturedSessionId = sessionId;
  let sessionCreatedSent = false;
  let tempImagePaths = [];
  let tempDir = null;

  // ── IM authoritative recording (Phase 1) ──────────────────────────────────
  // Record the USER bubble the instant we accept a real prompt (before any
  // image-path injection mutates `command`), and accumulate the assistant turn
  // to record ONCE at completion. `imContactId` mirrors how the file-watcher
  // ingest seeds the conversation contact (= project path / cwd). While a turn
  // is in flight we flag the session so the watcher suppresses its streaming
  // re-broadcast (see im-record.service for the de-streaming rationale).
  const imContactId = typeof options.cwd === 'string' && options.cwd.length > 0 ? options.cwd : null;
  const imTitle = typeof sessionSummary === 'string' && sessionSummary.length > 0 ? sessionSummary : null;
  const hasUserPrompt = typeof command === 'string' && command.trim().length > 0;
  // Accumulated assistant turn state, mirrors distillJsonl's flush logic so the
  // sourceId/content match what a later watcher pass would produce.
  let imAssistantText = '';
  let imFirstAssistantId = null;
  let imLastAssistantId = null;
  let imToolCount = 0;
  let imRawRefStart = null;
  let imRawRefEnd = null;
  let imTurnIsError = false;
  let imLastAssistantTs = 0;
  let imAssistantRecorded = false;
  // Coarse live-progress (Phase 2): name of the most recent tool_use and a
  // throttle clock so we broadcast at most ~1/sec per turn. This is the ONLY
  // thing broadcast during a turn besides the single assistant bubble at the end.
  let imCurrentTool = null;
  let imLastStatusAt = 0;
  const IM_STATUS_THROTTLE_MS = 1000;

  // Broadcast a lightweight im:status frame. `force` bypasses the throttle and
  // is used for the terminal isProcessing:false so the client always clears the
  // typing row.
  const emitImStatus = (sid, isProcessing, force) => {
    if (!sid) return;
    const now = Date.now();
    if (!force && now - imLastStatusAt < IM_STATUS_THROTTLE_MS) return;
    imLastStatusAt = now;
    try {
      broadcastImEvent(buildImStatusEvent({
        conversationId: sid,
        isProcessing,
        toolCount: imToolCount,
        currentTool: imCurrentTool,
      }));
    } catch (err) {
      console.error('IM status broadcast failed', err instanceof Error ? err.message : String(err));
    }
  };

  const recordImUser = (sid) => {
    if (!hasUserPrompt || !sid) return;
    try {
      recordUserMessage({
        sessionId: sid,
        contactId: imContactId,
        title: imTitle,
        content: command,
        clientMsgId: typeof clientMsgId === 'string' ? clientMsgId : null,
      });
    } catch (err) {
      console.error('IM record user failed', err instanceof Error ? err.message : String(err));
    }
  };

  const recordImAssistant = (sid, isError) => {
    if (imAssistantRecorded || !sid) return;
    imAssistantRecorded = true;
    try {
      recordAssistantMessage({
        sessionId: sid,
        contactId: imContactId,
        title: imTitle,
        content: imAssistantText,
        sourceId: imFirstAssistantId,
        createdAt: imLastAssistantTs || Date.now(),
        isError: isError === true || imTurnIsError,
        toolCount: imToolCount,
        rawRefStart: imRawRefStart,
        rawRefEnd: imRawRefEnd,
      });
    } catch (err) {
      console.error('IM record assistant failed', err instanceof Error ? err.message : String(err));
    } finally {
      endSdkTurn(sid);
    }
  };

  // If we already know the session id (resume), gate + record the user bubble now.
  if (hasUserPrompt && capturedSessionId) {
    beginSdkTurn(capturedSessionId);
    recordImUser(capturedSessionId);
  }

  const emitNotification = (event) => {
    notifyUserIfEnabled({
      userId: ws?.userId || null,
      writer: ws,
      event
    });
  };

  try {
    // Map CLI options to SDK format
    const sdkOptions = mapCliOptionsToSDK(options);

    // Load MCP configuration
    const mcpServers = await loadMcpConfig(options.cwd);
    if (mcpServers) {
      sdkOptions.mcpServers = mcpServers;
    }

    // Handle images - save to temp files and modify prompt
    const imageResult = await handleImages(command, options.images, options.cwd);
    const finalCommand = imageResult.modifiedCommand;
    tempImagePaths = imageResult.tempImagePaths;
    tempDir = imageResult.tempDir;

    // ── Interactive-tool interception (AskUserQuestion / ExitPlanMode) ─────────
    //
    // EMPIRICALLY VERIFIED against @anthropic-ai/claude-agent-sdk 0.2.116: under
    // `permissionMode: 'bypassPermissions'` (which the IM app ALWAYS sends) the
    // SDK resolves at the mode step and SKIPS canUseTool entirely — AskUserQuestion
    // never reached the client and got auto-answered. A `PreToolUse` hook, however,
    // DOES fire in every mode (bypass, default, plan, …) and runs BEFORE the mode
    // bypass, so it is the authoritative interception point. Returning
    // `permissionDecision:'allow'` + `updatedInput` from the hook also short-circuits
    // the permission flow so canUseTool does NOT additionally fire for the same tool
    // (verified in default mode too) — no double cards. We therefore drive interactive
    // tools entirely from this hook and leave canUseTool to gate ordinary tools.
    //
    // Flow: emit a live IM choice card + the legacy permission_request frame, block
    // on waitForToolApproval (indefinite), then flip the card to its terminal state
    // and return the injected answer to Claude via hookSpecificOutput.updatedInput.
    const customApprovalTimeoutMs = Number.isFinite(options?.approvalTimeoutMs)
      ? options.approvalTimeoutMs
      : undefined;
    const imChoiceContactId = imContactId;
    const imChoiceTitle = imTitle;

    const handleInteractiveTool = async (toolName, input, context) => {
      const requestId = createRequestId();
      const sid = capturedSessionId || sessionId || null;

      // Emit the interactive card as a live IM message (recorded + broadcast
      // mid-turn — the one allowed exception to "no body during a turn").
      if (sid) {
        try {
          if (toolName === 'ExitPlanMode') {
            recordChoiceCard({
              sessionId: sid,
              contactId: imChoiceContactId,
              title: imChoiceTitle,
              requestId,
              toolName: 'ExitPlanMode',
              plan: typeof input?.plan === 'string' ? input.plan : '',
            });
          } else {
            recordChoiceCard({
              sessionId: sid,
              contactId: imChoiceContactId,
              title: imChoiceTitle,
              requestId,
              toolName: 'AskUserQuestion',
              questions: Array.isArray(input?.questions) ? input.questions : [],
            });
          }
        } catch (err) {
          console.error('IM choice card record failed', err instanceof Error ? err.message : String(err));
        }
      }

      // Keep the legacy WS permission_request frame for the existing web/iOS panels.
      ws.send(createNormalizedMessage({ kind: 'permission_request', requestId, toolName, input, sessionId: sid, provider: 'claude' }));
      emitNotification(createNotificationEvent({
        provider: 'claude',
        sessionId: sid,
        kind: 'action_required',
        code: 'permission.required',
        meta: { toolName, sessionName: sessionSummary },
        severity: 'warning',
        requiresUserAction: true,
        dedupeKey: `claude:permission:${sid || 'none'}:${requestId}`
      }));

      // Interactive tools wait INDEFINITELY (timeoutMs:0) — a mobile user may
      // answer minutes later; the card hangs as an unanswered item meanwhile.
      const decision = await waitForToolApproval(requestId, {
        timeoutMs: 0,
        signal: context?.signal,
        metadata: {
          _sessionId: sid,
          _toolName: toolName,
          _input: input,
          _receivedAt: new Date(),
        },
        onCancel: (reason) => {
          ws.send(createNormalizedMessage({ kind: 'permission_cancelled', requestId, reason, sessionId: sid, provider: 'claude' }));
        }
      });

      // Resolve the card to its terminal state on every device.
      const flipCard = (answer) => {
        if (!sid) return;
        try {
          resolveChoiceCard({
            sessionId: sid,
            contactId: imChoiceContactId,
            title: imChoiceTitle,
            requestId,
            toolName: toolName === 'ExitPlanMode' ? 'ExitPlanMode' : 'AskUserQuestion',
            questions: toolName === 'ExitPlanMode' ? undefined : (Array.isArray(input?.questions) ? input.questions : []),
            plan: toolName === 'ExitPlanMode' ? (typeof input?.plan === 'string' ? input.plan : '') : undefined,
            answer,
          });
        } catch (err) {
          console.error('IM choice card resolve failed', err instanceof Error ? err.message : String(err));
        }
      };

      if (!decision || decision.cancelled) {
        flipCard('已取消');
        return { behavior: 'deny', message: decision?.cancelled ? 'Interactive request cancelled' : 'Interactive request timed out' };
      }

      if (decision.allow) {
        const updated = decision.updatedInput ?? input;
        flipCard(summarizeInteractiveAnswer(toolName, input, updated));
        return { behavior: 'allow', updatedInput: updated };
      }

      flipCard('已拒绝');
      return { behavior: 'deny', message: decision.message ?? 'User denied tool use' };
    };

    sdkOptions.hooks = {
      Notification: [{
        matcher: '',
        hooks: [async (input) => {
          const message = typeof input?.message === 'string' ? input.message : 'Claude requires your attention.';
          emitNotification(createNotificationEvent({
            provider: 'claude',
            sessionId: capturedSessionId || sessionId || null,
            kind: 'action_required',
            code: 'agent.notification',
            meta: { message, sessionName: sessionSummary },
            severity: 'warning',
            requiresUserAction: true,
            dedupeKey: `claude:hook:notification:${capturedSessionId || sessionId || 'none'}:${message}`
          }));
          return {};
        }]
      }],
      // Interactive tools (AskUserQuestion / ExitPlanMode) — intercepted here so
      // they work even under bypassPermissions (canUseTool is skipped in that mode).
      PreToolUse: [{
        matcher: 'AskUserQuestion|ExitPlanMode',
        hooks: [async (hookInput) => {
          const toolName = hookInput?.tool_name;
          const toolInput = hookInput?.tool_input ?? {};
          const result = await handleInteractiveTool(toolName, toolInput, { signal: undefined });
          if (result.behavior === 'allow') {
            return {
              hookSpecificOutput: {
                hookEventName: 'PreToolUse',
                permissionDecision: 'allow',
                updatedInput: result.updatedInput,
              },
            };
          }
          return {
            hookSpecificOutput: {
              hookEventName: 'PreToolUse',
              permissionDecision: 'deny',
              permissionDecisionReason: result.message || 'Denied by user',
            },
          };
        }]
      }]
    };

    sdkOptions.canUseTool = async (toolName, input, context) => {
      // Interactive tools are handled by the PreToolUse hook above (it fires in
      // every mode and short-circuits this callback). If we somehow reach here
      // for one (older SDK), fall back to the same interactive path.
      if (TOOLS_REQUIRING_INTERACTION.has(toolName)) {
        return handleInteractiveTool(toolName, input, context);
      }

      if (sdkOptions.permissionMode === 'bypassPermissions') {
        return { behavior: 'allow', updatedInput: input };
      }

      const isDisallowed = (sdkOptions.disallowedTools || []).some(entry =>
        matchesToolPermission(entry, toolName, input)
      );
      if (isDisallowed) {
        return { behavior: 'deny', message: 'Tool disallowed by settings' };
      }

      const isAllowed = (sdkOptions.allowedTools || []).some(entry =>
        matchesToolPermission(entry, toolName, input)
      );
      if (isAllowed) {
        return { behavior: 'allow', updatedInput: input };
      }

      const requestId = createRequestId();
      ws.send(createNormalizedMessage({ kind: 'permission_request', requestId, toolName, input, sessionId: capturedSessionId || sessionId || null, provider: 'claude' }));
      emitNotification(createNotificationEvent({
        provider: 'claude',
        sessionId: capturedSessionId || sessionId || null,
        kind: 'action_required',
        code: 'permission.required',
        meta: { toolName, sessionName: sessionSummary },
        severity: 'warning',
        requiresUserAction: true,
        dedupeKey: `claude:permission:${capturedSessionId || sessionId || 'none'}:${requestId}`
      }));

      // IM clients (e.g. the iOS app) can opt into a longer approval window and
      // "auto-execute if I don't answer in time" so an async mobile user never
      // stalls a run. Both come from the claude-command options; absent them the
      // classic UI keeps its 55s-then-deny default.
      const autoApproveOnTimeout = options?.autoApproveOnTimeout === true;

      const decision = await waitForToolApproval(requestId, {
        timeoutMs: customApprovalTimeoutMs ?? undefined,
        signal: context?.signal,
        metadata: {
          _sessionId: capturedSessionId || sessionId || null,
          _toolName: toolName,
          _input: input,
          _receivedAt: new Date(),
        },
        onCancel: (reason) => {
          ws.send(createNormalizedMessage({ kind: 'permission_cancelled', requestId, reason, sessionId: capturedSessionId || sessionId || null, provider: 'claude' }));
        }
      });
      if (!decision) {
        // Timed out. Opt-in auto-approve runs the tool; otherwise deny (default).
        if (autoApproveOnTimeout) {
          return { behavior: 'allow', updatedInput: input };
        }
        return { behavior: 'deny', message: 'Permission request timed out' };
      }

      if (decision.cancelled) {
        return { behavior: 'deny', message: 'Permission request cancelled' };
      }

      if (decision.allow) {
        if (decision.rememberEntry && typeof decision.rememberEntry === 'string') {
          if (!sdkOptions.allowedTools.includes(decision.rememberEntry)) {
            sdkOptions.allowedTools.push(decision.rememberEntry);
          }
          if (Array.isArray(sdkOptions.disallowedTools)) {
            sdkOptions.disallowedTools = sdkOptions.disallowedTools.filter(entry => entry !== decision.rememberEntry);
          }
        }
        return { behavior: 'allow', updatedInput: decision.updatedInput ?? input };
      }

      return { behavior: 'deny', message: decision.message ?? 'User denied tool use' };
    };

    // Set stream-close timeout for interactive tools (Query constructor reads it synchronously). Claude Agent SDK has a default of 5s and this overrides it
    const prevStreamTimeout = process.env.CLAUDE_CODE_STREAM_CLOSE_TIMEOUT;
    process.env.CLAUDE_CODE_STREAM_CLOSE_TIMEOUT = '300000';

    let queryInstance;
    try {
      queryInstance = query({
        prompt: finalCommand,
        options: sdkOptions
      });
    } catch (hookError) {
      // Older/newer SDK versions may not accept hook shapes yet.
      // Keep notification behavior operational via runtime events even if hook registration fails.
      console.warn('Failed to initialize Claude query with hooks, retrying without hooks:', hookError?.message || hookError);
      delete sdkOptions.hooks;
      queryInstance = query({
        prompt: finalCommand,
        options: sdkOptions
      });
    }

    // Restore immediately — Query constructor already captured the value
    if (prevStreamTimeout !== undefined) {
      process.env.CLAUDE_CODE_STREAM_CLOSE_TIMEOUT = prevStreamTimeout;
    } else {
      delete process.env.CLAUDE_CODE_STREAM_CLOSE_TIMEOUT;
    }

    // Track the query instance for abort capability
    if (capturedSessionId) {
      addSession(capturedSessionId, queryInstance, tempImagePaths, tempDir, ws);
    }

    // Process streaming messages
    console.log('Starting async generator loop for session:', capturedSessionId || 'NEW');
    for await (const message of queryInstance) {
      // Capture session ID from first message
      if (message.session_id && !capturedSessionId) {

        capturedSessionId = message.session_id;
        addSession(capturedSessionId, queryInstance, tempImagePaths, tempDir, ws);

        // Set session ID on writer
        if (ws.setSessionId && typeof ws.setSessionId === 'function') {
          ws.setSessionId(capturedSessionId);
        }

        // Send session-created event only once for new sessions
        if (!sessionId && !sessionCreatedSent) {
          sessionCreatedSent = true;
          ws.send(createNormalizedMessage({ kind: 'session_created', newSessionId: capturedSessionId, sessionId: capturedSessionId, provider: 'claude' }));
        }

        // Brand-new session: now that we know its id, gate the watcher and
        // record the authoritative user bubble (a resume already did this above).
        if (!sessionId) {
          beginSdkTurn(capturedSessionId);
          recordImUser(capturedSessionId);
        }
      } else {
        // session_id already captured
      }

      // Transform and normalize message via adapter
      const transformedMessage = transformMessage(message);
      const sid = capturedSessionId || sessionId || null;

      // Use adapter to normalize SDK events into NormalizedMessage[]
      const normalized = sessionsService.normalizeMessage('claude', transformedMessage, sid);
      for (const msg of normalized) {
        // Preserve parentToolUseId from SDK wrapper for subagent tool grouping
        if (transformedMessage.parentToolUseId && !msg.parentToolUseId) {
          msg.parentToolUseId = transformedMessage.parentToolUseId;
        }
        ws.send(msg);
      }

      // Accumulate the assistant turn for the single IM bubble recorded at
      // completion. Mirrors distillJsonl's assistant branch: concatenate text
      // blocks, count tool_use blocks, and key the bubble on the turn's FIRST
      // assistant uuid (the same sourceId a later watcher distill would use, so
      // they dedup). NOTE: do NOT broadcast here — that would be streaming.
      if (message.type === 'assistant') {
        const rawContent = message.message?.content;
        if (typeof rawContent === 'string') {
          imAssistantText += rawContent;
        } else if (Array.isArray(rawContent)) {
          let hasToolUse = false;
          for (const block of rawContent) {
            if (block?.type === 'text' && typeof block.text === 'string') imAssistantText += block.text;
            else if (block?.type === 'tool_use') {
              imToolCount += 1;
              hasToolUse = true;
              if (typeof block.name === 'string') imCurrentTool = block.name;
            }
          }
          if (hasToolUse && message.uuid) {
            if (imRawRefStart === null) imRawRefStart = message.uuid;
            imRawRefEnd = message.uuid;
            // Coarse progress: a tool started — broadcast a throttled status frame
            // so long agentic turns visibly "move" without streaming content.
            emitImStatus(sid, true, false);
          }
        }
        if (imFirstAssistantId === null && message.uuid) imFirstAssistantId = message.uuid;
        if (message.uuid) imLastAssistantId = message.uuid;
        if (message.isError) imTurnIsError = true;
        const tsVal = message.timestamp ? Date.parse(message.timestamp) : NaN;
        imLastAssistantTs = Number.isFinite(tsVal) ? tsVal : Date.now();
      }

      // Extract and send token budget updates from result messages
      if (message.type === 'result') {
        const models = Object.keys(message.modelUsage || {});
        if (models.length > 0) {
          // Model info available in result message
        }
        if (message.is_error || message.subtype === 'error') imTurnIsError = true;
        const tokenBudgetData = extractTokenBudget(message);
        if (tokenBudgetData) {
          ws.send(createNormalizedMessage({ kind: 'status', text: 'token_budget', tokenBudget: tokenBudgetData, sessionId: capturedSessionId || sessionId || null, provider: 'claude' }));
        }
      }
    }

    // Mark this comment for clarity: imLastAssistantId is captured for parity
    // with distill (the rawRef end) even though only the first id keys the row.
    void imLastAssistantId;

    // Clean up session on completion
    if (capturedSessionId) {
      removeSession(capturedSessionId);
    }

    // Clean up temporary image files
    await cleanupTempFiles(tempImagePaths, tempDir);

    // Record the ONE authoritative assistant bubble for this turn + broadcast it
    // once (clears the watcher gate). Idempotent on sourceId, so the watcher's
    // later jsonl pass dedups instead of re-broadcasting.
    recordImAssistant(capturedSessionId || sessionId || null, false);

    // Clear the typing row: terminal status frame (forced past the throttle).
    emitImStatus(capturedSessionId || sessionId || null, false, true);

    // Send completion event
    ws.send(createNormalizedMessage({ kind: 'complete', exitCode: 0, isNewSession: !sessionId && !!command, sessionId: capturedSessionId, provider: 'claude' }));
    notifyRunStopped({
      userId: ws?.userId || null,
      provider: 'claude',
      sessionId: capturedSessionId || sessionId || null,
      sessionName: sessionSummary,
      stopReason: 'completed'
    });
    // Complete

  } catch (error) {
    console.error('SDK query error:', error);

    // Clean up session on error
    if (capturedSessionId) {
      removeSession(capturedSessionId);
    }

    // Clean up temporary image files on error
    await cleanupTempFiles(tempImagePaths, tempDir);

    // Check if Claude CLI is installed for a clearer error message
    const installed = await providerAuthService.isProviderInstalled('claude');
    const errorContent = !installed
      ? 'Claude Code is not installed. Please install it first: https://docs.anthropic.com/en/docs/claude-code'
      : error.message;

    // Record the assistant turn as an error bubble (whatever text streamed plus
    // the error), broadcast once, and clear the watcher gate.
    const sidForIm = capturedSessionId || sessionId || null;
    if (sidForIm) {
      if (!imAssistantText.trim()) imAssistantText = errorContent;
      recordImAssistant(sidForIm, true);
    }

    // Clear the typing row even on failure (forced past the throttle).
    emitImStatus(sidForIm, false, true);

    // Send error to WebSocket
    ws.send(createNormalizedMessage({ kind: 'error', content: errorContent, sessionId: capturedSessionId || sessionId || null, provider: 'claude' }));
    notifyRunFailed({
      userId: ws?.userId || null,
      provider: 'claude',
      sessionId: capturedSessionId || sessionId || null,
      sessionName: sessionSummary,
      error
    });
  }
}

/**
 * Aborts an active SDK session
 * @param {string} sessionId - Session identifier
 * @returns {boolean} True if session was aborted, false if not found
 */
async function abortClaudeSDKSession(sessionId) {
  const session = getSession(sessionId);

  if (!session) {
    console.log(`Session ${sessionId} not found`);
    return false;
  }

  try {
    console.log(`Aborting SDK session: ${sessionId}`);

    // Call interrupt() on the query instance
    await session.instance.interrupt();

    // Update session status
    session.status = 'aborted';

    // Clean up temporary image files
    await cleanupTempFiles(session.tempImagePaths, session.tempDir);

    // Clean up session
    removeSession(sessionId);

    return true;
  } catch (error) {
    console.error(`Error aborting session ${sessionId}:`, error);
    return false;
  }
}

/**
 * Checks if an SDK session is currently active
 * @param {string} sessionId - Session identifier
 * @returns {boolean} True if session is active
 */
function isClaudeSDKSessionActive(sessionId) {
  const session = getSession(sessionId);
  return session && session.status === 'active';
}

/**
 * Gets all active SDK session IDs
 * @returns {Array<string>} Array of active session IDs
 */
function getActiveClaudeSDKSessions() {
  return getAllSessions();
}

/**
 * Get pending tool approvals for a specific session.
 * @param {string} sessionId - The session ID
 * @returns {Array} Array of pending permission request objects
 */
function getPendingApprovalsForSession(sessionId) {
  const pending = [];
  for (const [requestId, resolver] of pendingToolApprovals.entries()) {
    if (resolver._sessionId === sessionId) {
      pending.push({
        requestId,
        toolName: resolver._toolName || 'UnknownTool',
        input: resolver._input,
        context: resolver._context,
        sessionId,
        receivedAt: resolver._receivedAt || new Date(),
      });
    }
  }
  return pending;
}

/**
 * Reconnect a session's WebSocketWriter to a new raw WebSocket.
 * Called when client reconnects (e.g. page refresh) while SDK is still running.
 * @param {string} sessionId - The session ID
 * @param {Object} newRawWs - The new raw WebSocket connection
 * @returns {boolean} True if writer was successfully reconnected
 */
function reconnectSessionWriter(sessionId, newRawWs) {
  const session = getSession(sessionId);
  if (!session?.writer?.updateWebSocket) return false;
  session.writer.updateWebSocket(newRawWs);
  console.log(`[RECONNECT] Writer swapped for session ${sessionId}`);
  return true;
}

// Export public API
export {
  queryClaudeSDK,
  abortClaudeSDKSession,
  isClaudeSDKSessionActive,
  getActiveClaudeSDKSessions,
  resolveToolApproval,
  getPendingApprovalInfo,
  resolveInteractiveAnswer,
  registerTerminalChoice,
  getTerminalChoiceDecision,
  getPendingApprovalsForSession,
  reconnectSessionWriter,
  __registerPendingApprovalForTests
};
