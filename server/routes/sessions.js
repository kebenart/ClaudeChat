import { Router } from 'express';
import { projectsDb } from '../modules/database/index.js';

/**
 * @param {{
 *   getRunningIds: () => string[],
 *   getLiveMeta: () => Promise<Array<{id:string,title:string|null,project:string|null,cwd:string|null,mtime:number}>>,
 *   getProcessSessionIds?: () => Promise<string[]>,
 *   lookupSessionMeta: (id:string) => Promise<{id:string,title:string|null,project:string|null,cwd:string|null,mtime:number}|null>,
 *   windowMin: number,
 *   resolveProjectId?: (cwd: string) => string | null
 * }} deps
 */

/**
 * Attach projectId to a meta object and return the enriched entry.
 * Uses the optional deps.resolveProjectId for testability; falls back to projectsDb.
 * @param {{ id: string, title: string|null, project: string|null, cwd: string|null, mtime: number|null }} meta
 * @param {((cwd: string) => string | null) | undefined} resolveProjectId
 */
function enrichWithProjectId(meta, resolveProjectId) {
  let projectId = null;
  if (meta?.cwd) {
    try {
      if (resolveProjectId) {
        projectId = resolveProjectId(meta.cwd);
      } else {
        projectId = projectsDb.getProjectPath(meta.cwd)?.project_id ?? null;
      }
    } catch {
      projectId = null;
    }
  }
  return { ...meta, projectId };
}

export default function createSessionsRouter(deps) {
  const router = Router();
  router.get('/active', async (_req, res) => {
    try {
      const runningIds = deps.getRunningIds() ?? [];
      const [liveAll, processIds] = await Promise.all([
        Promise.resolve(deps.getLiveMeta()).then((v) => v ?? []),
        deps.getProcessSessionIds
          ? Promise.resolve(deps.getProcessSessionIds()).then((v) => v ?? [])
          : Promise.resolve([]),
      ]);

      // Order of preference for an id: SDK-active → mtime entry → process-only.
      const seen = new Set();
      const result = [];

      // 1) SDK-active set — enrich via lookupSessionMeta
      for (const id of runningIds) {
        if (seen.has(id)) continue;
        seen.add(id);
        const meta = (await deps.lookupSessionMeta(id)) ?? { id, title: null, project: null, cwd: null, mtime: null };
        result.push(enrichWithProjectId(meta, deps.resolveProjectId));
      }

      // 2) Mtime-derived entries — already enriched with meta
      for (const s of liveAll) {
        if (seen.has(s.id)) continue;
        seen.add(s.id);
        result.push(enrichWithProjectId(s, deps.resolveProjectId));
      }

      // 3) Process-derived ids that didn't appear above (typical case: an
      //    idle `claude --resume <id>` that hasn't written to its jsonl
      //    inside the live window). Lookup meta on demand.
      for (const id of processIds) {
        if (seen.has(id)) continue;
        seen.add(id);
        const meta = (await deps.lookupSessionMeta(id)) ?? { id, title: null, project: null, cwd: null, mtime: null };
        result.push(enrichWithProjectId(meta, deps.resolveProjectId));
      }

      res.json({ live: result, windowMin: deps.windowMin });
    } catch (err) {
      res.status(500).json({ error: err.message });
    }
  });
  return router;
}
