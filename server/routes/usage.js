import { Router } from 'express';

/**
 * @param {{
 *   summarize: () => Promise<import('../services/usage-rollup.service.js').UsageSummary>,
 *   getClaudeLimits?: (force?: boolean) => Promise<import('../services/claude-usage.service.js').ClaudeUsageLimits | null>,
 * }} deps
 */
export default function createUsageRouter({ summarize, getClaudeLimits }) {
  const router = Router();

  router.get('/summary', async (_req, res) => {
    try {
      const data = await summarize();
      res.json(data);
    } catch (err) {
      res.status(500).json({ error: err.message });
    }
  });

  // GET /api/usage/claude-limits — Claude account usage limits (5h + weekly)
  // from the Anthropic OAuth usage endpoint. Always 200 so the UI degrades
  // gracefully; when unavailable (no token / network / non-200) returns a
  // null-filled shape rather than an error. The OAuth token is never exposed.
  // `?force=1` (alias `refresh=1`) requests a manual refresh; the service still
  // enforces a 5-minute floor between actual upstream calls.
  router.get('/claude-limits', async (req, res) => {
    try {
      const force = req.query.force === '1' || req.query.refresh === '1';
      const limits = getClaudeLimits ? await getClaudeLimits(force) : null;
      if (limits) {
        res.json(limits);
      } else {
        res.json({ fiveHour: null, sevenDay: null });
      }
    } catch {
      res.json({ fiveHour: null, sevenDay: null });
    }
  });

  // Network RTT from this hub to api.anthropic.com (the Claude SERVER), routed
  // through the hub's proxy. Distinct from the client↔hub WS latency: the client
  // can't reach api.anthropic.com directly (geo-blocked in CN), so the hub probes
  // it. Cheap HEAD, no body, no tokens; the client controls cadence.
  router.get('/claude-ping', async (_req, res) => {
    try {
      res.json(await pingClaudeServer());
    } catch {
      res.json({ ms: null, ok: false, via: 'direct' });
    }
  });

  return router;
}
