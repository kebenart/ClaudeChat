#!/usr/bin/env node
/**
 * im-send-image.mjs — let Claude push an image into the IM chat.
 *
 * Run by Claude (a Bash tool call) after it produces an image — e.g. a
 * test-result screenshot:
 *
 *   node /ABS/PATH/claudecodeui-local/scripts/im-send-image.mjs <image-path> [caption...]
 *
 * It POSTs the absolute path to the server's loopback-only `/api/im-hook/image`,
 * which validates + copies the file into the managed media store and broadcasts
 * a kind:'image' bubble to every IM client. The conversation is identified by
 * `CLAUDE_CODE_SESSION_ID` (set by Claude Code in the Bash environment).
 *
 * Auth: `IM_HOOK_TOKEN` from the env, else read from the launchd plist (same
 * source the server uses). Endpoint is loopback + token gated.
 *
 * Exits non-zero with a message on failure so Claude can see it didn't send.
 */

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

function fail(msg) {
  console.error(`im-send-image: ${msg}`);
  process.exit(1);
}

const [, , rawPath, ...captionParts] = process.argv;
if (!rawPath) fail('usage: im-send-image.mjs <image-path> [caption...]');

const imagePath = path.resolve(process.cwd(), rawPath);
if (!fs.existsSync(imagePath)) fail(`file not found: ${imagePath}`);

const sessionId = process.env.CLAUDE_CODE_SESSION_ID;
if (!sessionId) {
  fail('CLAUDE_CODE_SESSION_ID is not set — run this from inside a Claude Code session.');
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

const port = process.env.SERVER_PORT || 3001;
const url = `http://127.0.0.1:${port}/api/im-hook/image`;
const body = {
  sessionId,
  projectPath: process.cwd(),
  imagePath,
  caption: captionParts.join(' '),
};

const controller = new AbortController();
const timeout = setTimeout(() => controller.abort(), 10000);
try {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'X-IM-Hook-Token': getToken() },
    body: JSON.stringify(body),
    signal: controller.signal,
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok || !json.ok) {
    fail(`server rejected the image (${res.status}): ${json.error || 'unknown error'}`);
  }
  console.log(`sent image to IM (${json.mediaId})`);
} catch (err) {
  fail(`could not reach the IM server at ${url}: ${err?.message || err}`);
} finally {
  clearTimeout(timeout);
}
