import fsp from 'node:fs/promises';
import path from 'node:path';
import readline from 'node:readline';
import { createReadStream } from 'node:fs';

export interface RecentSessionsOptions {
  rootDir: string;
  windowMin: number;
}

export interface SessionMeta {
  id: string;
  title: string | null;
  project: string | null;      // basename of cwd, for display
  cwd: string | null;           // full absolute project path
  mtime: number;
}

async function safeReaddir(dir: string): Promise<string[]> {
  try {
    return await fsp.readdir(dir);
  } catch {
    return [];
  }
}

function extractUserText(content: unknown): string | null {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    for (const block of content) {
      if (block && typeof block === 'object' && (block as any).type === 'text' && typeof (block as any).text === 'string') {
        return (block as any).text;
      }
    }
  }
  return null;
}

const LINE_LIMIT = 60;

async function readJsonlMeta(filePath: string): Promise<{ title: string | null; project: string | null; cwd: string | null }> {
  let aiTitle: string | null = null;
  let firstUser: string | null = null;
  let cwd: string | null = null;
  let lines = 0;

  try {
    const stream = createReadStream(filePath, { encoding: 'utf8' });
    const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
    for await (const line of rl) {
      lines++;
      if (lines > LINE_LIMIT && (aiTitle || firstUser) && cwd !== null) break;
      let obj: any;
      try { obj = JSON.parse(line); } catch { continue; }
      if (!aiTitle && obj?.type === 'ai-title' && typeof obj.aiTitle === 'string') {
        aiTitle = obj.aiTitle;
      }
      if (!firstUser && obj?.type === 'user' && obj?.message) {
        const text = extractUserText(obj.message.content);
        if (text && text.trim()) firstUser = text.trim();
      }
      if (cwd === null && typeof obj?.cwd === 'string') {
        cwd = obj.cwd;
      }
    }
    rl.close();
    stream.destroy();
  } catch {
    // file disappeared / unreadable — return what we have
  }

  // Use || so empty strings fall through to the next fallback.
  const title = (aiTitle || (firstUser ? firstUser.slice(0, 80) : null)) || null;
  const project = cwd ? path.basename(cwd) || cwd : null;
  return { title, project, cwd };
}

export const liveSessionsService = {
  /**
   * Walks ~/.claude/projects/<encoded>/*.jsonl one level deep, returns
   * sessions whose mtime is within the window, enriched with title +
   * project label parsed from the JSONL preamble.
   */
  async list({ rootDir, windowMin }: RecentSessionsOptions): Promise<SessionMeta[]> {
    const cutoff = Date.now() - windowMin * 60 * 1000;
    const projects = await safeReaddir(rootDir);
    const out: SessionMeta[] = [];
    for (const project of projects) {
      const projectDir = path.join(rootDir, project);
      const files = await safeReaddir(projectDir);
      for (const file of files) {
        if (!file.endsWith('.jsonl')) continue;
        const full = path.join(projectDir, file);
        try {
          const stat = await fsp.stat(full);
          if (stat.mtimeMs < cutoff) continue;
          const id = file.slice(0, -'.jsonl'.length);
          const meta = await readJsonlMeta(full);
          out.push({ id, title: meta.title, project: meta.project, cwd: meta.cwd, mtime: stat.mtimeMs });
        } catch {}
      }
    }
    // newest first
    out.sort((a, b) => b.mtime - a.mtime);
    return out;
  },

  /**
   * Look up the JSONL metadata for a single known sessionId. Used to
   * enrich the "running" set returned by claude-sdk's activeSessions Map.
   * Searches all project subdirectories one level deep.
   */
  async lookupById(rootDir: string, sessionId: string): Promise<SessionMeta | null> {
    const projects = await safeReaddir(rootDir);
    for (const project of projects) {
      const candidate = path.join(rootDir, project, `${sessionId}.jsonl`);
      try {
        const stat = await fsp.stat(candidate);
        const meta = await readJsonlMeta(candidate);
        return { id: sessionId, title: meta.title, project: meta.project, cwd: meta.cwd, mtime: stat.mtimeMs };
      } catch {
        // not in this project dir
      }
    }
    return null;
  },
};
