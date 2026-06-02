// claude-ping.service — network latency from the hub to Anthropic's API edge.
//
// This is distinct from the two other "latency" signals:
//   • WS ping/pong (client ↔ hub) — measured in the client.
//   • Claude reply time (prompt → first token) — depends on model load.
// This one measures the round-trip from THIS machine (the service hub) to the
// Claude SERVER (api.anthropic.com), routed through the same proxy the real API
// calls use — api.anthropic.com is often blocked in CN, so a dedicated proxy
// (CLAUDE_USAGE_PROXY / HTTPS_PROXY) is honored exactly like claude-usage.service.

const PING_URL = 'https://api.anthropic.com/';

function resolveProxy(): string | undefined {
  return (
    process.env.CLAUDE_USAGE_PROXY ||
    process.env.HTTPS_PROXY ||
    process.env.https_proxy ||
    process.env.HTTP_PROXY ||
    process.env.http_proxy ||
    undefined
  );
}

async function getDispatcher(proxy: string | undefined): Promise<unknown | undefined> {
  if (!proxy) return undefined;
  try {
    const { ProxyAgent } = await import('undici');
    return new ProxyAgent(proxy);
  } catch {
    return undefined;
  }
}

export interface ClaudePing {
  /** Round-trip ms to api.anthropic.com; null when unreachable / timed out. */
  ms: number | null;
  /** True when the Claude server answered (any HTTP status counts as reachable). */
  ok: boolean;
  /** Whether the probe went through a proxy or hit the edge directly. */
  via: 'proxy' | 'direct';
}

// A HEAD to the API root is enough: any HTTP response (even 404/401) proves we
// reached Anthropic's edge and gives the network round-trip. We never read a
// body and never spend tokens. Each call opens a fresh connection, so the number
// includes TLS setup — consistent across calls, representative of a cold reach.
// Timeout for the reachability probe. The proxy path (which the real API calls
// also use) routinely takes ~5-6s for this cold HEAD, so an 8s cap sat right on
// top of normal latency — a small proxy hiccup tipped it over and the probe
// falsely reported 不可达. 15s leaves comfortable headroom while still bounding
// a genuinely dead link. We keep the proxy (matches how real calls are routed).
const PING_TIMEOUT_MS = 15000;

export async function pingClaudeServer(): Promise<ClaudePing> {
  const proxy = resolveProxy();
  const dispatcher = await getDispatcher(proxy);
  const via: ClaudePing['via'] = dispatcher ? 'proxy' : 'direct';
  const start = Date.now();
  try {
    await fetch(PING_URL, {
      method: 'HEAD',
      // @ts-expect-error - undici dispatcher option not in lib.dom fetch types
      dispatcher,
      signal: AbortSignal.timeout(PING_TIMEOUT_MS),
    });
    return { ms: Date.now() - start, ok: true, via };
  } catch {
    return { ms: null, ok: false, via };
  }
}
