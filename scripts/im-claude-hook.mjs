#!/usr/bin/env node
/**
 * im-claude-hook.mjs — Claude Code settings hook → IM hub bridge.
 *
 * Wired into ~/.claude/settings.json on the `UserPromptSubmit` and `Stop` hook
 * events. Claude pipes the hook input JSON on stdin; this script maps it to the
 * IM ingest body and POSTs it to the local server's `/api/im-hook/ingest`. The
 * effect: Claude sessions run directly in a terminal (not via the IM app/SDK)
 * also land in the IM hub.
 *
 * Hook input (stdin JSON) fields used:
 *   - hook_event_name: 'UserPromptSubmit' | 'Stop'
 *   - session_id, cwd, transcript_path
 *   - prompt (UserPromptSubmit only)
 *
 * Mapping → POST body:
 *   UserPromptSubmit → { event:'user', sessionId, projectPath:cwd, content:prompt }
 *   Stop            → { event:'stop', sessionId, projectPath:cwd, transcriptPath }
 *
 * Robustness contract: this MUST NEVER block or fail a Claude run. Every error
 * (server off, network down, bad/empty JSON, timeout) is swallowed and the
 * process ALWAYS exits 0 with no meaningful stdout. The POST has a hard 2s
 * timeout via AbortController.
 *
 * Env: SERVER_PORT (default 3001), IM_HOOK_TOKEN (sent as X-IM-Hook-Token).
 */

function readStdin() {
  return new Promise((resolve) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      data += chunk;
    });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', () => resolve(data));
  });
}

async function main() {
  const raw = await readStdin();

  let input;
  try {
    input = JSON.parse(raw);
  } catch {
    return; // nothing parseable — stay silent, exit 0
  }

  const event = input?.hook_event_name;
  let body;
  if (event === 'UserPromptSubmit') {
    body = {
      event: 'user',
      sessionId: input.session_id,
      projectPath: input.cwd,
      content: input.prompt,
    };
  } else if (event === 'Stop') {
    body = {
      event: 'stop',
      sessionId: input.session_id,
      projectPath: input.cwd,
      transcriptPath: input.transcript_path,
    };
  } else {
    return; // unrelated event — nothing to do
  }

  const port = process.env.SERVER_PORT || 3001;
  const url = `http://127.0.0.1:${port}/api/im-hook/ingest`;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2000);
  try {
    await fetch(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'X-IM-Hook-Token': process.env.IM_HOOK_TOKEN || '',
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch {
    // server off / network down / aborted — swallow
  } finally {
    clearTimeout(timeout);
  }
}

main()
  .catch(() => {})
  .finally(() => {
    // Emit an empty (valid) hook response and always succeed.
    process.stdout.write('{}');
    process.exit(0);
  });
