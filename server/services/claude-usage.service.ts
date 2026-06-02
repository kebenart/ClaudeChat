import { execFile } from 'node:child_process';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

// --- Public shapes -------------------------------------------------------

export interface UsageWindow {
  utilizationPct: number; // 0–100
  resetsAt: string;       // RFC3339 timestamp
}

export interface ClaudeUsageLimits {
  fiveHour: UsageWindow | null;
  sevenDay: UsageWindow | null;
  perModel?: {
    sevenDayOpus: UsageWindow | null;
    sevenDaySonnet: UsageWindow | null;
  };
  asOf: number; // ms epoch
}

// --- Credential reading --------------------------------------------------

interface OAuthCreds {
  accessToken: string;
  refreshToken?: string;
  expiresAt?: number; // ms epoch
}

function debug(msg: string, ...rest: unknown[]): void {
  // Keep the access token out of logs — callers must never pass it here.
  if (process.env.DEBUG || process.env.CLAUDE_USAGE_DEBUG) {
    console.debug(`[claude-usage] ${msg}`, ...rest);
  }
}

function parseCredsBlob(raw: string): OAuthCreds | null {
  try {
    const obj = JSON.parse(raw);
    const oauth = obj?.claudeAiOauth;
    if (!oauth || typeof oauth.accessToken !== 'string' || oauth.accessToken.length === 0) {
      return null;
    }
    return {
      accessToken: oauth.accessToken,
      refreshToken: typeof oauth.refreshToken === 'string' ? oauth.refreshToken : undefined,
      expiresAt: typeof oauth.expiresAt === 'number' ? oauth.expiresAt : undefined,
    };
  } catch {
    return null;
  }
}

// File first (cross-platform), macOS Keychain fallback.
async function readOAuthCreds(): Promise<OAuthCreds | null> {
  const credPath = path.join(os.homedir(), '.claude', '.credentials.json');
  try {
    const raw = await fsp.readFile(credPath, 'utf8');
    const creds = parseCredsBlob(raw);
    if (creds) return creds;
    debug('credentials.json present but missing claudeAiOauth.accessToken');
  } catch {
    debug('no ~/.claude/.credentials.json (will try keychain on macOS)');
  }

  if (process.platform === 'darwin') {
    try {
      const { stdout } = await execFileAsync('security', [
        'find-generic-password',
        '-s',
        'Claude Code-credentials',
        '-w',
      ]);
      const creds = parseCredsBlob(stdout);
      if (creds) return creds;
      debug('keychain entry present but unparseable');
    } catch {
      debug('keychain lookup failed (no entry / no access)');
    }
  }

  return null;
}

// --- Proxy-aware fetch ---------------------------------------------------

const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';

function proxyUrl(): string | null {
  return (
    // Dedicated proxy for ONLY this usage call. In CN, api.anthropic.com is
    // geo-blocked (direct → 403 "Request not allowed"), so the request must exit
    // via a non-CN node. Using a usage-specific var (not the global HTTP_PROXY)
    // keeps the Claude SDK subprocess off the proxy so it isn't tied to Clash.
    process.env.CLAUDE_USAGE_PROXY ||
    process.env.HTTPS_PROXY ||
    process.env.https_proxy ||
    process.env.HTTP_PROXY ||
    process.env.http_proxy ||
    process.env.ALL_PROXY ||
    process.env.all_proxy ||
    null
  );
}

// Build a dispatcher for the global fetch when a proxy is configured.
// undici ships with Node 24 and exposes ProxyAgent; if it is somehow absent we
// fall back to a direct (no-proxy) call rather than failing hard.
async function proxyDispatcher(): Promise<unknown | undefined> {
  const proxy = proxyUrl();
  if (!proxy) return undefined;
  try {
    const undici = await import('undici');
    if (typeof undici.ProxyAgent === 'function') {
      debug(`using proxy ${proxy}`);
      return new undici.ProxyAgent(proxy);
    }
  } catch {
    debug('undici not importable; calling api.anthropic.com directly');
  }
  return undefined;
}

// --- Cache ---------------------------------------------------------------

const SUCCESS_TTL_MS = 30 * 60 * 1000; // cache successes for 30min
const FAILURE_TTL_MS = 30 * 1000;
// Minimum gap between actual upstream calls on the *forced* (manual-refresh)
// path. Upstream is itself ~5min rate-limited, so a manual refresh inside this
// floor is served from cache rather than hammering the endpoint.
const MANUAL_REFRESH_FLOOR_MS = 5 * 60 * 1000;

interface CacheEntry {
  value: ClaudeUsageLimits | null;
  expiresAt: number;
}

let cache: CacheEntry | null = null;
let lastUpstreamFetchAt = 0; // ms epoch of the last actual upstream call

// --- Normalization -------------------------------------------------------

function toWindow(raw: unknown): UsageWindow | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.utilization !== 'number' || typeof r.resets_at !== 'string') return null;
  return { utilizationPct: r.utilization, resetsAt: r.resets_at };
}

// --- Public API ----------------------------------------------------------

/**
 * Reads the local Claude Code OAuth token, calls the validated usage endpoint
 * (honoring HTTP(S) proxy env in CN), and returns normalized limits.
 *
 * Returns `null` (never throws) on any failure: no token, expired token,
 * network error, or non-200 response. Failures are logged at debug level only.
 * The access token is never logged or returned.
 *
 * Token refresh is intentionally NOT implemented: if the access token's
 * `expiresAt` is in the past we return null. Implementing the OAuth refresh
 * flow is deferred.
 */
export async function getClaudeUsageLimits(force = false): Promise<ClaudeUsageLimits | null> {
  const now = Date.now();

  // Normal path: serve the 30min cache while it's fresh.
  if (!force && cache && cache.expiresAt > now) {
    return cache.value;
  }
  // Forced (manual-refresh) path: honour the 5min floor — within it, return the
  // cached value (even if past its TTL) instead of hitting the rate-limited
  // upstream again.
  if (force && cache && now - lastUpstreamFetchAt < MANUAL_REFRESH_FLOOR_MS) {
    return cache.value;
  }

  lastUpstreamFetchAt = now;
  const result = await fetchClaudeUsageLimits(now);

  // Cache successes for 30min, failures for 30s. 429 backoff is handled inside
  // fetchClaudeUsageLimits by extending the failure TTL via the cache write below.
  return result.value !== null
    ? cacheAndReturn(result.value, now + SUCCESS_TTL_MS)
    : cacheAndReturn(null, now + (result.retryAfterMs ?? FAILURE_TTL_MS));
}

function cacheAndReturn(value: ClaudeUsageLimits | null, expiresAt: number): ClaudeUsageLimits | null {
  cache = { value, expiresAt };
  return value;
}

interface FetchResult {
  value: ClaudeUsageLimits | null;
  retryAfterMs?: number; // for 429 backoff
}

async function fetchClaudeUsageLimits(now: number): Promise<FetchResult> {
  const creds = await readOAuthCreds();
  if (!creds) {
    debug('no oauth token available');
    return { value: null };
  }
  if (typeof creds.expiresAt === 'number' && creds.expiresAt <= now) {
    debug('oauth access token expired; refresh not implemented, returning null');
    return { value: null };
  }

  const dispatcher = await proxyDispatcher();

  let res: Response;
  try {
    res = await fetch(USAGE_URL, {
      method: 'GET',
      headers: {
        Authorization: `Bearer ${creds.accessToken}`,
        'anthropic-beta': 'oauth-2025-04-20',
        'User-Agent': 'claude-code/2.1',
      },
      // undici's fetch accepts a per-request dispatcher; typed as unknown here.
      ...(dispatcher ? ({ dispatcher } as Record<string, unknown>) : {}),
    });
  } catch (err) {
    debug('network error calling usage endpoint', (err as Error)?.message);
    return { value: null };
  }

  if (res.status === 429) {
    const retryAfter = Number(res.headers.get('retry-after'));
    const retryAfterMs = Number.isFinite(retryAfter) && retryAfter > 0
      ? retryAfter * 1000
      : 60 * 1000;
    debug(`rate limited (429), backing off ${retryAfterMs}ms`);
    return { value: null, retryAfterMs };
  }

  if (!res.ok) {
    debug(`non-200 from usage endpoint: ${res.status}`);
    return { value: null };
  }

  let body: Record<string, unknown>;
  try {
    body = (await res.json()) as Record<string, unknown>;
  } catch (err) {
    debug('failed to parse usage JSON', (err as Error)?.message);
    return { value: null };
  }

  const value: ClaudeUsageLimits = {
    fiveHour: toWindow(body.five_hour),
    sevenDay: toWindow(body.seven_day),
    perModel: {
      sevenDayOpus: toWindow(body.seven_day_opus),
      sevenDaySonnet: toWindow(body.seven_day_sonnet),
    },
    asOf: now,
  };
  return { value };
}
