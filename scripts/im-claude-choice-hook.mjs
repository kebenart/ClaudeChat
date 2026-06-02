#!/usr/bin/env node
/**
 * im-claude-choice-hook.mjs — terminal interactive choice → IM choice card.
 *
 * Wired into ~/.claude/settings.json as a `PreToolUse` hook matching
 * `AskUserQuestion|ExitPlanMode`. When a TERMINAL Claude session hits one of
 * those tools, this hook:
 *   1. POSTs the question to the server's loopback `/api/im-hook/choice`, which
 *      records + broadcasts a 红包-style choice card to every IM client;
 *   2. BLOCKS, polling `/api/im-hook/choice/:requestId` until the user answers on
 *      a device (or it times out);
 *   3. returns the PreToolUse decision (allow + updatedInput, or deny) to Claude.
 *
 * App (SDK) sessions are handled in-process by the server's own PreToolUse hook;
 * the server replies `{ skip: true }` for them (isSdkTurnActive) and we defer.
 *
 * NEVER hard-fails Claude: any error / timeout returns `{}` (no decision), so
 * Claude falls back to asking in the terminal. The settings entry sets a long
 * `timeout` (≈10min) so a slow phone answer isn't cut off.
 *
 * Env: SERVER_PORT (default 3001), IM_HOOK_TOKEN (from the env or the plist).
 */

import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';

const INTERACTIVE = new Set(['AskUserQuestion', 'ExitPlanMode']);
const POLL_MS = 1500;
const MAX_MS = 9.5 * 60 * 1000;

function readStdin() {
  return new Promise((resolve) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => (data += c));
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', () => resolve(data));
  });
}

function getToken() {
  if (process.env.IM_HOOK_TOKEN) return process.env.IM_HOOK_TOKEN;
  try {
    const plist = path.join(os.homedir(), 'Library', 'LaunchAgents', 'com.user.claudecodeui-local.plist');
    return execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :EnvironmentVariables:IM_HOOK_TOKEN', plist], {
      encoding: 'utf8',
    }).trim();
  } catch {
    return '';
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function decide() {
  const raw = await readStdin();
  let input;
  try {
    input = JSON.parse(raw);
  } catch {
    return {};
  }
  if (input?.hook_event_name !== 'PreToolUse') return {};
  const toolName = input?.tool_name;
  if (!INTERACTIVE.has(toolName)) return {};
  const sessionId = input?.session_id;
  if (!sessionId) return {};
  const toolInput = input?.tool_input ?? {};

  const requestId = randomUUID();
  const port = process.env.SERVER_PORT || 3001;
  const base = `http://127.0.0.1:${port}/api/im-hook/choice`;
  const headers = { 'content-type': 'application/json', 'X-IM-Hook-Token': getToken() };

  // 1. Register the question (records + broadcasts the card).
  let reg;
  try {
    const res = await fetch(base, {
      method: 'POST',
      headers,
      body: JSON.stringify({ sessionId, projectPath: input?.cwd, requestId, toolName, input: toolInput }),
    });
    reg = await res.json().catch(() => ({}));
  } catch {
    return {}; // server off → defer to the terminal prompt
  }
  if (!reg?.ok || reg.skip) return {}; // SDK owns this session, or rejected → defer

  // 2. Poll for the answer.
  const deadline = Date.now() + MAX_MS;
  while (Date.now() < deadline) {
    await sleep(POLL_MS);
    let body;
    try {
      const res = await fetch(`${base}/${requestId}`, { headers });
      body = await res.json().catch(() => ({}));
    } catch {
      continue;
    }
    if (body?.answered && body.decision) {
      const d = body.decision;
      if (d.allow) {
        return {
          hookSpecificOutput: {
            hookEventName: 'PreToolUse',
            permissionDecision: 'allow',
            updatedInput: d.updatedInput ?? toolInput,
          },
        };
      }
      return {
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: d.message || '已被用户拒绝',
        },
      };
    }
    if (body?.found === false) break; // expired / cleared → stop polling
  }
  return {}; // timeout → defer
}

decide()
  .then((out) => {
    process.stdout.write(JSON.stringify(out ?? {}));
    process.exit(0);
  })
  .catch(() => {
    process.stdout.write('{}');
    process.exit(0);
  });
