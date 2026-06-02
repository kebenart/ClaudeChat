import { exec } from 'node:child_process';
import { promisify } from 'node:util';
import fsp from 'node:fs/promises';
import path from 'node:path';

const execAsync = promisify(exec);

/**
 * Detects live Claude CLI session IDs by scanning OS processes.
 *
 * Two signals, in priority order:
 *   1. `claude --resume <uuid>` — session id is already in argv, no DB/FS lookup needed
 *   2. Otherwise — derive session id from the process's cwd: encode it to a
 *      project directory name (~/.claude/projects/<encoded>/) and take the
 *      most recently modified .jsonl inside.
 *
 * This complements the JSONL-mtime scan: a `claude` process that's been idle
 * (user left iTerm open without typing) doesn't update its jsonl, but the
 * process is still alive and we want it in the Live list.
 */

interface ProcessLine {
  pid: string;
  command: string;
}

function listClaudeProcesses(psOutput: string): ProcessLine[] {
  const lines = psOutput.split('\n');
  const out: ProcessLine[] = [];
  for (const raw of lines) {
    const m = raw.match(/^\s*(\d+)\s+(.*)$/);
    if (!m) continue;
    const pid = m[1];
    const command = m[2];
    // Match a claude / claude.exe invocation. Excludes:
    //   - "hapi claude ..." (hapi wrappers — claudecodeui SDK set covers them)
    //   - macOS "Claude" app (capital C, GUI app, not CLI)
    //   - "claude_*" or things where claude is a substring
    if (!/(^|\/)claude(\.exe)?(\s|$)/.test(command)) continue;
    if (/\bhapi\s+claude\b/.test(command)) continue;
    if (/\/Claude\.app\//.test(command)) continue;
    out.push({ pid, command });
  }
  return out;
}

function extractResumeId(command: string): string | null {
  const m = command.match(/--resume[=\s]+([0-9a-f-]{36})/i);
  return m ? m[1] : null;
}

async function processCwd(pid: string): Promise<string | null> {
  try {
    const { stdout } = await execAsync(
      `lsof -p ${pid} 2>/dev/null | awk '$4=="cwd" {print $NF; exit}'`,
      { maxBuffer: 1024 * 1024 }
    );
    const cwd = stdout.trim();
    return cwd || null;
  } catch {
    return null;
  }
}

function encodeCwdToProjectDir(cwd: string): string {
  return cwd.replace(/[^a-zA-Z0-9-]/g, '-');
}

async function newestJsonlId(rootDir: string, encoded: string): Promise<string | null> {
  const dir = path.join(rootDir, encoded);
  let entries: string[] = [];
  try {
    entries = await fsp.readdir(dir);
  } catch {
    return null;
  }
  let best: { id: string; mtime: number } | null = null;
  for (const f of entries) {
    if (!f.endsWith('.jsonl')) continue;
    try {
      const stat = await fsp.stat(path.join(dir, f));
      if (!best || stat.mtimeMs > best.mtime) {
        best = { id: f.slice(0, -'.jsonl'.length), mtime: stat.mtimeMs };
      }
    } catch {
      // file gone
    }
  }
  return best ? best.id : null;
}

export const processSessionsService = {
  /**
   * Returns the set of session IDs owned by currently-running claude processes.
   */
  async list(rootDir: string): Promise<string[]> {
    let psOut = '';
    try {
      const { stdout } = await execAsync('ps -axo pid,command', {
        maxBuffer: 5 * 1024 * 1024,
      });
      psOut = stdout;
    } catch {
      return [];
    }

    const procs = listClaudeProcesses(psOut);
    const ids = new Set<string>();

    // Phase 1: cheap — extract --resume IDs
    const needCwdLookup: ProcessLine[] = [];
    for (const p of procs) {
      const id = extractResumeId(p.command);
      if (id) {
        ids.add(id);
      } else {
        needCwdLookup.push(p);
      }
    }

    // Phase 2: lsof + readdir per remaining process. Run in parallel.
    await Promise.all(
      needCwdLookup.map(async (p) => {
        const cwd = await processCwd(p.pid);
        if (!cwd) return;
        const encoded = encodeCwdToProjectDir(cwd);
        const id = await newestJsonlId(rootDir, encoded);
        if (id) ids.add(id);
      })
    );

    return Array.from(ids);
  },

  // Exposed for tests
  _internal: {
    listClaudeProcesses,
    extractResumeId,
    encodeCwdToProjectDir,
  },
};
