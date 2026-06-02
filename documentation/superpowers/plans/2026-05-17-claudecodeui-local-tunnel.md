# claudecodeui-local Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a stripped-down, Claude-only fork of claudecodeui that lists only currently-active (or recently-active) Claude sessions, sits behind FRP+nginx so a phone can reach the Mac over public HTTPS, and gates login with password + TOTP 2FA.

**Architecture:** A copy of the upstream template lives at `~/CODE/claudecodeui-local`. Multi-provider code (Cursor/Codex/Gemini) is removed wholesale; provider registry narrows to `claude` only. A new `recent-sessions` service combines `claude-sdk.js`'s `activeSessions` keys (the "running" set) with a JSONL-mtime scan in `~/.claude/projects/<encoded>/*.jsonl` (the "recent" set). Auth gains a TOTP second factor stored encrypted in `auth.db`. The Mac runs `frpc` outbound to the existing Tencent Cloud server (<SERVER_IP>) where `frps` exposes a loopback port that the existing nginx reverse-proxies via a new HTTPS subdomain.

**Tech Stack:** Node 22, Express 4, better-sqlite3, ws, React 18 + TS + Vite, Tailwind, `@anthropic-ai/claude-agent-sdk`, `otplib` (new), `node:test` runner via `tsx`, FRP (frpc/frps), nginx, Let's Encrypt.

**Source template (read-only):** `~/Downloads/TEMP/claudecodeui-main`
**Target repo:** `~/CODE/claudecodeui-local`
**Spec:** `~/CODE/claudecodeui-local/docs/superpowers/specs/2026-05-17-claudecodeui-local-tunnel-design.md`

---

## File structure (where everything lives)

The plan keeps the upstream layout where possible. New files are listed by purpose.

**New server code:**
- `server/services/recent-sessions.service.ts` — JSONL-mtime scan.
- `server/services/totp.service.ts` — otplib wrapper + AES-GCM seal/unseal of the secret.
- `server/routes/sessions.js` — `GET /api/sessions/active` (running + recent).
- `server/routes/auth-totp.js` — TOTP setup, verify-setup, login-step-2 endpoints (mounted under `/api/auth`).
- `scripts/reset-totp.js` — emergency clearer.

**New frontend code:**
- `src/components/auth/view/TotpSetupScreen.tsx`
- `src/components/auth/view/TotpVerifyStep.tsx`
- `src/components/sidebar/RunningSessionsList.tsx` — replaces the prior "all sessions" list.

**New deploy artifacts:**
- `deploy/frpc.toml` (Mac template)
- `deploy/frps.toml` (server template)
- `deploy/nginx-cli.conf` (vhost)
- `deploy/launchd/com.user.frpc.plist`
- `deploy/systemd/frps.service`
- `deploy/README.md`

**Files removed wholesale:**
- `server/cursor-cli.js`, `server/gemini-cli.js`, `server/gemini-response-handler.js`, `server/openai-codex.js`, `server/sessionManager.js`
- `server/routes/cursor.js`, `server/routes/gemini.js`
- `server/modules/providers/list/cursor/`, `…/codex/`, `…/gemini/`

**Files edited heavily:** `server/index.js`, `server/modules/providers/provider.registry.ts`, `server/modules/database/schema.ts`, `server/modules/database/migrations.ts`, `server/middleware/auth.js`, `server/routes/auth.js`, `shared/types.ts`, `package.json`, `src/components/auth/view/LoginForm.tsx`, `src/components/provider-auth/`.

---

## Conventions used throughout this plan

**Test runner.** The upstream uses `node:test` invoked through `tsx`. Always run a single test file with:

```bash
npx tsx --test path/to/file.test.ts
```

To run a single named test inside a file:

```bash
npx tsx --test --test-name-pattern='<name fragment>' path/to/file.test.ts
```

**Commit hygiene.** Each task ends with a commit. Use conventional-commits prefixes — the repo enforces them with commitlint (`feat:`, `fix:`, `chore:`, `refactor:`, `test:`, `docs:`).

**TDD.** Tasks that add behavior follow red → green → refactor → commit. Pure deletion tasks verify with `npm run typecheck` + grep "no remaining references" instead of new tests.

**Paths.** Absolute (`~/CODE/claudecodeui-local/...`) wherever ambiguous; relative inside the repo otherwise.

**Working directory.** All commands assume `cd ~/CODE/claudecodeui-local` unless otherwise stated.

---

## Phase 0 — Repository bootstrap

### Task 0.1: Copy template, init git, install deps

**Files:**
- Create: entire `~/CODE/claudecodeui-local` tree (copy of template).

- [ ] **Step 1: Copy the template to the target directory**

```bash
# Run from your home dir, NOT from inside the source tree.
# NOTE: no --delete — the target dir already contains docs/superpowers/{specs,plans}/
# files (this spec and plan) that must be preserved.
rsync -a \
  --exclude node_modules --exclude dist --exclude dist-server --exclude .git \
  ~/Downloads/TEMP/claudecodeui-main/ ~/CODE/claudecodeui-local/
```

Expected: command exits 0. `ls ~/CODE/claudecodeui-local | head` lists `package.json`, `server`, `src`, etc.

- [ ] **Step 2: Move the design spec into the new tree (it already lives at the target — verify only)**

```bash
ls ~/CODE/claudecodeui-local/docs/superpowers/specs/2026-05-17-claudecodeui-local-tunnel-design.md
```

Expected: file exists.

- [ ] **Step 3: Initialize git**

```bash
cd ~/CODE/claudecodeui-local
git init
git add -A
git commit -m "chore: import claudecodeui-main template baseline"
```

- [ ] **Step 4: Rename the package and tighten metadata**

Edit `~/CODE/claudecodeui-local/package.json`:

- Replace the `"name"` field value with `"claudecodeui-local"`.
- Replace the `"description"` field value with `"Claude-only fork of claudecodeui with TOTP and FRP tunnel"`.
- Replace the entire `"keywords"` array with `["claude-code", "claude-code-ui", "self-hosted"]`.
- Remove the `"bin"`, `"homepage"`, `"repository"`, `"bugs"`, `"release"` script, and `"prepublishOnly"` script — this is a private app, not a publishable package.
- Remove the `"publishConfig"` block if present.

- [ ] **Step 5: Install dependencies**

```bash
npm install
```

Expected: install completes; `node_modules/` populated; no errors.

- [ ] **Step 6: Confirm a clean baseline build**

```bash
npm run typecheck
```

Expected: exits 0 (if it does not, do NOT proceed — the template has a pre-existing problem that needs fixing first; capture the output and stop).

- [ ] **Step 7: Commit**

```bash
git add package.json package-lock.json
git commit -m "chore: rename package to claudecodeui-local"
```

---

## Phase 1 — Strip multi-provider code

Each task in this phase is a deletion + reference-cleanup unit. The verification at the end of each task is the same trio: `git grep` for leftover names returns nothing, `npm run typecheck` passes, `npm run lint` passes.

### Task 1.1: Remove Cursor server integration

**Files:**
- Delete: `server/cursor-cli.js`
- Delete: `server/routes/cursor.js`
- Delete: `server/modules/providers/list/cursor/` (whole directory)
- Modify: `server/index.js` (remove Cursor imports + `app.use('/api/cursor', …)` + WS chat dispatch entries)
- Modify: `server/modules/providers/provider.registry.ts` (drop the `cursor` entry + its import)

- [ ] **Step 1: Find every reference to the names we are about to remove**

```bash
cd ~/CODE/claudecodeui-local
git grep -n -E 'cursor-cli|spawnCursor|abortCursorSession|isCursorSessionActive|getActiveCursorSessions|CursorProvider|cursorRoutes' server src shared
```

Expected: lists hits across `server/index.js`, `server/modules/providers/provider.registry.ts`, plus the files we are about to delete. Capture the list mentally — every one must be eliminated before the verification at Step 5.

- [ ] **Step 2: Delete the Cursor files**

```bash
git rm server/cursor-cli.js \
       server/routes/cursor.js
git rm -r server/modules/providers/list/cursor
```

- [ ] **Step 3: Edit `server/index.js` — remove the Cursor block**

Open `server/index.js`. Make the following exact removals:

- Delete the `import { spawnCursor, abortCursorSession, isCursorSessionActive, getActiveCursorSessions } from './cursor-cli.js';` block (around line 31).
- Delete `import cursorRoutes from './routes/cursor.js';` (around line 57).
- Inside the `chat:` object passed to `createWebSocketServer`, delete the four properties: `spawnCursor`, `abortCursorSession`, `isCursorSessionActive`, `getActiveCursorSessions`.
- Delete the line `app.use('/api/cursor', authenticateToken, cursorRoutes);` (around line 162) along with its preceding `// Cursor API Routes (protected)` comment.

- [ ] **Step 4: Edit `server/modules/providers/provider.registry.ts`**

- Delete the line `import { CursorProvider } from '@/modules/providers/list/cursor/cursor.provider.js';`.
- Delete the `cursor: new CursorProvider(),` entry inside the `providers` record literal.

- [ ] **Step 5: Verify no references remain and the project still type-checks**

```bash
git grep -n -E 'cursor-cli|spawnCursor|abortCursorSession|isCursorSessionActive|getActiveCursorSessions|CursorProvider|cursorRoutes' server || echo "OK: no server refs"
npm run typecheck
```

Expected: the grep echoes `OK: no server refs`; typecheck exits 0. Note: matches inside `src/` (frontend) are allowed at this step — they are handled in Task 1.7/1.8.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: remove Cursor provider integration from server"
```

### Task 1.2: Remove Codex server integration

**Files:**
- Delete: `server/openai-codex.js`
- Delete: `server/modules/providers/list/codex/` (whole directory)
- Modify: `server/index.js` (remove Codex imports + WS chat dispatch entries; there is no `/api/codex` route mount in upstream — verify before editing)
- Modify: `server/modules/providers/provider.registry.ts` (drop the `codex` entry + its import)

- [ ] **Step 1: Find references**

```bash
git grep -n -E 'openai-codex|queryCodex|abortCodexSession|isCodexSessionActive|getActiveCodexSessions|CodexProvider' server shared
```

Expected: hits in `server/index.js`, the registry, and the files about to be deleted.

- [ ] **Step 2: Delete files**

```bash
git rm server/openai-codex.js
git rm -r server/modules/providers/list/codex
```

- [ ] **Step 3: Edit `server/index.js`**

- Delete the `import { queryCodex, abortCodexSession, isCodexSessionActive, getActiveCodexSessions } from './openai-codex.js';` block (around line 37).
- Inside the `chat:` object: delete properties `queryCodex`, `abortCodexSession`, `isCodexSessionActive`, `getActiveCodexSessions`.

- [ ] **Step 4: Edit `server/modules/providers/provider.registry.ts`**

- Delete `import { CodexProvider } from '@/modules/providers/list/codex/codex.provider.js';`.
- Delete `codex: new CodexProvider(),` inside the `providers` record.

- [ ] **Step 5: Verify**

```bash
git grep -n -E 'openai-codex|queryCodex|abortCodexSession|isCodexSessionActive|getActiveCodexSessions|CodexProvider' server || echo "OK: no server refs"
npm run typecheck
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: remove Codex provider integration from server"
```

### Task 1.3: Remove Gemini server integration (and `sessionManager.js`)

`server/sessionManager.js` is a Gemini-only in-memory session store (stores under `~/.gemini/sessions`). It is dead with Gemini.

**Files:**
- Delete: `server/gemini-cli.js`, `server/gemini-response-handler.js`, `server/sessionManager.js`
- Delete: `server/routes/gemini.js`
- Delete: `server/modules/providers/list/gemini/`
- Modify: `server/index.js` (remove Gemini imports + WS dispatch + route mount + the `shell.getSessionById` wiring that uses sessionManager)
- Modify: `server/modules/providers/provider.registry.ts`

- [ ] **Step 1: Find references**

```bash
git grep -n -E 'gemini-cli|gemini-response-handler|spawnGemini|abortGeminiSession|isGeminiSessionActive|getActiveGeminiSessions|GeminiProvider|geminiRoutes|sessionManager' server shared
```

- [ ] **Step 2: Delete files**

```bash
git rm server/gemini-cli.js \
       server/gemini-response-handler.js \
       server/sessionManager.js \
       server/routes/gemini.js
git rm -r server/modules/providers/list/gemini
```

- [ ] **Step 3: Edit `server/index.js`**

- Delete the `import { spawnGemini, abortGeminiSession, isGeminiSessionActive, getActiveGeminiSessions } from './gemini-cli.js';` block (around line 43).
- Delete `import sessionManager from './sessionManager.js';`.
- Delete `import geminiRoutes from './routes/gemini.js';`.
- Inside the `chat:` object: delete `spawnGemini`, `abortGeminiSession`, `isGeminiSessionActive`, `getActiveGeminiSessions`.
- Inside the `shell:` object passed to `createWebSocketServer`, replace the `getSessionById: (sessionId) => sessionManager.getSession(sessionId),` line with `getSessionById: () => null,` (the shell route currently consults sessionManager only to look up a Gemini session; the function is required by the WS shell adapter signature but the lookup is no longer meaningful — returning `null` makes the adapter treat every WS shell as fresh).
- Delete `app.use('/api/gemini', authenticateToken, geminiRoutes);` along with its preceding `// Gemini API Routes (protected)` comment.

- [ ] **Step 4: Edit `server/modules/providers/provider.registry.ts`**

- Delete `import { GeminiProvider } from '@/modules/providers/list/gemini/gemini.provider.js';`.
- Delete `gemini: new GeminiProvider(),`.

- [ ] **Step 5: Audit WS shell adapter for further sessionManager references**

```bash
git grep -n 'sessionManager\|getSessionById' server
```

Expected: only the `getSessionById: () => null,` line in `server/index.js` matches. If anything else does, open the file and either remove the call site or stub similarly.

- [ ] **Step 6: Verify**

```bash
git grep -n -E 'gemini-cli|gemini-response-handler|spawnGemini|abortGeminiSession|isGeminiSessionActive|getActiveGeminiSessions|GeminiProvider|geminiRoutes' server || echo "OK"
git grep -n 'sessionManager\|./sessionManager' server || echo "OK: sessionManager gone"
npm run typecheck
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: remove Gemini provider and sessionManager from server"
```

### Task 1.4: Narrow `LLMProvider` type to `'claude'`

**Files:**
- Modify: `shared/types.ts`

- [ ] **Step 1: Find the current type definition**

```bash
git grep -n 'LLMProvider' shared
```

Open `shared/types.ts`. The export looks like `export type LLMProvider = 'claude' | 'cursor' | 'codex' | 'gemini';`.

- [ ] **Step 2: Narrow it**

Replace the union with:

```ts
export type LLMProvider = 'claude';
```

- [ ] **Step 3: Typecheck**

```bash
npm run typecheck
```

Expected: passes. If you see "Type '\"codex\"' is not assignable to type '\"claude\"'" or similar in any remaining code, that code still references a removed provider and must be cleaned up before this step can pass.

- [ ] **Step 4: Commit**

```bash
git add shared/types.ts
git commit -m "refactor: narrow LLMProvider type to 'claude' only"
```

### Task 1.5: Strip provider-auth UI to Claude-only

**Files:**
- Modify: `src/components/provider-auth/view/ProviderLoginModal.tsx`
- Modify: `src/components/provider-auth/types.ts`
- Modify: `src/components/provider-auth/hooks/` contents

- [ ] **Step 1: Find every non-claude reference inside `src/components/provider-auth/`**

```bash
git grep -n -E 'cursor|codex|gemini' src/components/provider-auth
```

- [ ] **Step 2: Remove non-claude branches**

For each match, delete the branch / case / array entry. The modal will end up with only the Claude API-key option (or Claude CLI delegation, whichever the code already supports). Do not invent new code — strictly delete.

- [ ] **Step 3: Typecheck and lint**

```bash
npm run typecheck
npm run lint
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: drop non-claude branches from provider-auth UI"
```

### Task 1.6: Remove provider selector UI from sidebar / main-content / settings

The upstream UI has a "select provider" pill row near the top of the sidebar and inside the chat header. Find every such place by name.

**Files:**
- Modify: components under `src/components/sidebar/`, `src/components/main-content/`, and `src/components/quick-settings-panel/` if they expose a provider switcher.

- [ ] **Step 1: Find references**

```bash
git grep -n -i -E 'provider.*selector|providerTab|select.*provider|providers\.map\(|LLMProvider' src
```

- [ ] **Step 2: For each match, decide:**

  - If the file lists providers (e.g., `providers.map(p => <PillButton …>)`), replace the dynamic list with the single literal `'claude'`, and remove any UI that exposes the choice (since there's nothing to choose).
  - If the file branches on provider id, keep only the claude branch.

This is mechanical. When you finish, every `LLMProvider` use in `src/` should either be a literal `'claude'` or pass through a value the type system already narrows to `'claude'`.

- [ ] **Step 3: Typecheck**

```bash
npm run typecheck
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: remove provider-selector UI; claude is the only option"
```

### Task 1.7: Drop non-claude i18n keys

**Files:**
- Modify: every `src/i18n/locales/<lang>/*.json` file containing cursor/codex/gemini keys.

- [ ] **Step 1: Find candidate keys**

```bash
git grep -l -E '"(cursor|codex|gemini)"' src/i18n/locales
```

- [ ] **Step 2: Remove the keys**

For each file, remove the top-level objects keyed `cursor`, `codex`, `gemini` (if present), and any string with those names inside `chat`, `sidebar`, `settings`, etc.

Verify each JSON still parses:

```bash
for f in $(git grep -l '' src/i18n/locales/); do
  node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))" || { echo "BROKEN: $f"; break; }
done
```

Expected: no `BROKEN` lines.

- [ ] **Step 3: Commit**

```bash
git add src/i18n/locales
git commit -m "refactor: drop non-claude i18n keys"
```

### Task 1.8: Remove non-claude npm dependencies

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Inspect the dependency list for provider-specific packages**

The known one is `@openai/codex-sdk`. Confirm with:

```bash
node -e "const p=require('./package.json'); for (const k of Object.keys(p.dependencies)) if(/codex|cursor|gemini/i.test(k)) console.log(k);"
```

Expected output: at minimum `@openai/codex-sdk`.

- [ ] **Step 2: Uninstall**

```bash
npm uninstall @openai/codex-sdk
```

(Add any others surfaced in Step 1 to the same command line.)

- [ ] **Step 3: Verify nothing imports them**

```bash
git grep -n '@openai/codex-sdk' server src || echo "OK"
```

- [ ] **Step 4: Typecheck**

```bash
npm run typecheck
```

- [ ] **Step 5: Commit**

```bash
git add package.json package-lock.json
git commit -m "chore: remove non-claude provider dependencies"
```

### Task 1.9: Full sweep — assert no residual provider references

This is a single verification step. If it fails, go back to the relevant task above; do not paper over.

- [ ] **Step 1: Sweep**

```bash
git grep -n -E '\b(cursor|codex|gemini)\b' server src shared scripts deploy 2>/dev/null | \
  grep -v -E '/i18n/locales/.*/auth\.json|README|CHANGELOG'
```

Expected: empty output. Any leftover hit must be removed or explicitly justified (e.g., a string literal that happens to contain "cursor" as a CSS class name — unlikely, but possible).

- [ ] **Step 2: Build the full project**

```bash
npm run build
```

Expected: client + server build both succeed.

- [ ] **Step 3: Commit (no changes expected; this is just the gate)**

```bash
git status   # should show clean tree
```

---

## Phase 2 — Session filter (running + recent)

### Task 2.1: Add a typed export for the running-session getter

The upstream `claude-sdk.js` exports `getActiveClaudeSDKSessions()` returning `Array.from(activeSessions.keys())` (server/claude-sdk.js:787 / line 833 in upstream baseline). We will wrap it in a service so the route layer doesn't depend on the SDK module directly.

**Files:**
- Create: `server/services/running-sessions.service.ts`
- Test: `server/services/running-sessions.service.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// server/services/running-sessions.service.test.ts
import assert from 'node:assert/strict';
import test from 'node:test';

import { runningSessionsService } from '@/services/running-sessions.service.js';

test('returns the IDs reported by the underlying getter', () => {
  const fakeGetter = () => ['sess-a', 'sess-b'];
  const ids = runningSessionsService.list(fakeGetter);
  assert.deepEqual(ids, ['sess-a', 'sess-b']);
});

test('returns an empty array when the underlying getter returns nothing iterable', () => {
  const fakeGetter = () => [] as string[];
  assert.deepEqual(runningSessionsService.list(fakeGetter), []);
});
```

- [ ] **Step 2: Run the test, confirm it fails**

```bash
npx tsx --test server/services/running-sessions.service.test.ts
```

Expected: failure ("Cannot find module '@/services/running-sessions.service.js'").

- [ ] **Step 3: Implement**

```ts
// server/services/running-sessions.service.ts
export const runningSessionsService = {
  /**
   * Returns the IDs of Claude sessions whose SDK driver is still attached.
   * Injectable getter keeps this file decoupled from claude-sdk.js for tests.
   */
  list(getActiveIds: () => string[]): string[] {
    const result = getActiveIds();
    return Array.isArray(result) ? result : [];
  },
};
```

- [ ] **Step 4: Run the test, confirm it passes**

```bash
npx tsx --test server/services/running-sessions.service.test.ts
```

Expected: 2 passing.

- [ ] **Step 5: Commit**

```bash
git add server/services/running-sessions.service.ts server/services/running-sessions.service.test.ts
git commit -m "feat(sessions): add running-sessions service"
```

### Task 2.2: Add a "recent" session scanner

Walks `~/.claude/projects/<encoded>/*.jsonl` and returns IDs whose mtime is ≤ `windowMin` minutes ago. The session ID is the filename minus `.jsonl`.

**Files:**
- Create: `server/services/recent-sessions.service.ts`
- Test: `server/services/recent-sessions.service.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// server/services/recent-sessions.service.test.ts
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { recentSessionsService } from '@/services/recent-sessions.service.js';

test('returns session IDs from .jsonl files modified within window', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'recent-sessions-'));
  try {
    const projDir = path.join(tmp, '-Users-tester-CODE-foo');
    await fs.mkdir(projDir, { recursive: true });
    const fresh = path.join(projDir, 'aaaa-bbbb-cccc.jsonl');
    const stale = path.join(projDir, 'old-old-old.jsonl');
    await fs.writeFile(fresh, '');
    await fs.writeFile(stale, '');
    const oldMtime = new Date(Date.now() - 60 * 60 * 1000); // 60 min ago
    await fs.utimes(stale, oldMtime, oldMtime);

    const ids = await recentSessionsService.list({ rootDir: tmp, windowMin: 30 });
    assert.deepEqual(ids.sort(), ['aaaa-bbbb-cccc']);
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('returns an empty array when the root directory is missing', async () => {
  const ids = await recentSessionsService.list({
    rootDir: '/nonexistent/path/that/should/not/exist',
    windowMin: 30,
  });
  assert.deepEqual(ids, []);
});
```

- [ ] **Step 2: Run the test, confirm it fails**

```bash
npx tsx --test server/services/recent-sessions.service.test.ts
```

- [ ] **Step 3: Implement**

```ts
// server/services/recent-sessions.service.ts
import fsp from 'node:fs/promises';
import path from 'node:path';

export interface RecentSessionsOptions {
  rootDir: string;
  windowMin: number;
}

async function safeReaddir(dir: string): Promise<string[]> {
  try {
    return await fsp.readdir(dir);
  } catch {
    return [];
  }
}

export const recentSessionsService = {
  async list({ rootDir, windowMin }: RecentSessionsOptions): Promise<string[]> {
    const cutoff = Date.now() - windowMin * 60 * 1000;
    const projects = await safeReaddir(rootDir);
    const recentIds: string[] = [];

    for (const project of projects) {
      const projectDir = path.join(rootDir, project);
      const files = await safeReaddir(projectDir);
      for (const file of files) {
        if (!file.endsWith('.jsonl')) continue;
        const full = path.join(projectDir, file);
        try {
          const stat = await fsp.stat(full);
          if (stat.mtimeMs >= cutoff) {
            recentIds.push(file.slice(0, -'.jsonl'.length));
          }
        } catch {
          // Skip files that disappeared mid-scan.
        }
      }
    }
    return recentIds;
  },
};
```

- [ ] **Step 4: Run the test, confirm passes**

```bash
npx tsx --test server/services/recent-sessions.service.test.ts
```

- [ ] **Step 5: Commit**

```bash
git add server/services/recent-sessions.service.ts server/services/recent-sessions.service.test.ts
git commit -m "feat(sessions): scan ~/.claude/projects for recently-touched session IDs"
```

### Task 2.3: Combined API endpoint `GET /api/sessions/active`

Returns:

```jsonc
{
  "running": ["sess-1", "sess-2"],          // SDK-attached
  "recent":  ["sess-3"],                    // mtime ≤ window, not in running
  "windowMin": 30
}
```

**Files:**
- Create: `server/routes/sessions.js`
- Test: `server/routes/sessions.test.ts`
- Modify: `server/index.js` (mount the route)

- [ ] **Step 1: Write the failing test**

```ts
// server/routes/sessions.test.ts
import assert from 'node:assert/strict';
import express from 'express';
import http from 'node:http';
import test from 'node:test';

import sessionsRouter from '@/routes/sessions.js';

function startServer(deps: Parameters<typeof sessionsRouter>[0]) {
  const app = express();
  app.use('/api/sessions', sessionsRouter(deps));
  return new Promise<{ url: string; close: () => void }>(resolve => {
    const server = http.createServer(app).listen(0, () => {
      const port = (server.address() as any).port;
      resolve({
        url: `http://127.0.0.1:${port}`,
        close: () => server.close(),
      });
    });
  });
}

test('GET /active returns running and recent sets with running-first dedup', async () => {
  const { url, close } = await startServer({
    getRunningIds: () => ['sess-a', 'sess-b'],
    getRecentIds: async () => ['sess-a', 'sess-c'],
    windowMin: 30,
  });
  try {
    const res = await fetch(`${url}/api/sessions/active`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body.running.sort(), ['sess-a', 'sess-b']);
    assert.deepEqual(body.recent, ['sess-c']);
    assert.equal(body.windowMin, 30);
  } finally {
    close();
  }
});
```

- [ ] **Step 2: Run, confirm it fails**

```bash
npx tsx --test server/routes/sessions.test.ts
```

- [ ] **Step 3: Implement the route module**

```js
// server/routes/sessions.js
import { Router } from 'express';

/**
 * @param {{
 *   getRunningIds: () => string[],
 *   getRecentIds: () => Promise<string[]>,
 *   windowMin: number
 * }} deps
 */
export default function createSessionsRouter(deps) {
  const router = Router();
  router.get('/active', async (_req, res) => {
    try {
      const running = deps.getRunningIds() ?? [];
      const recentAll = (await deps.getRecentIds()) ?? [];
      const runningSet = new Set(running);
      const recent = recentAll.filter(id => !runningSet.has(id));
      res.json({ running, recent, windowMin: deps.windowMin });
    } catch (err) {
      res.status(500).json({ error: err.message });
    }
  });
  return router;
}
```

- [ ] **Step 4: Run, confirm passes**

```bash
npx tsx --test server/routes/sessions.test.ts
```

- [ ] **Step 5: Mount the route in `server/index.js`**

Near the other `import …Routes from './routes/…'` lines, add:

```js
import createSessionsRouter from './routes/sessions.js';
import { getActiveClaudeSDKSessions } from './claude-sdk.js'; // already imported in upstream — leave that import as-is
import path from 'path';
import os from 'os';
import { recentSessionsService } from './services/recent-sessions.service.js';
```

(Skip imports that already exist.)

Then near where the other routers are mounted with `authenticateToken`, add:

```js
app.use(
  '/api/sessions',
  authenticateToken,
  createSessionsRouter({
    getRunningIds: getActiveClaudeSDKSessions,
    getRecentIds: () =>
      recentSessionsService.list({
        rootDir: path.join(os.homedir(), '.claude', 'projects'),
        windowMin: Number(process.env.RECENT_SESSION_WINDOW_MIN) || 30,
      }),
    windowMin: Number(process.env.RECENT_SESSION_WINDOW_MIN) || 30,
  })
);
```

- [ ] **Step 6: Smoke-check by booting the server**

```bash
npm run server:dev &
sleep 4
curl -s http://127.0.0.1:3001/health   # should respond OK without auth
kill %1
```

Expected: `{"status":"ok",...}` from the health endpoint. The `/api/sessions/active` route is auth-gated, so we don't curl it here — that's covered later in Phase 3 testing.

- [ ] **Step 7: Commit**

```bash
git add server/routes/sessions.js server/routes/sessions.test.ts server/index.js
git commit -m "feat(api): GET /api/sessions/active returning running + recent"
```

### Task 2.4: Frontend `RunningSessionsList` component

This replaces the old all-sessions sidebar list. It polls `/api/sessions/active` every 5 s and renders two groups.

**Files:**
- Create: `src/components/sidebar/RunningSessionsList.tsx`
- Modify: `src/components/sidebar/` parent component that previously rendered the all-sessions list (find it in Step 1).

- [ ] **Step 1: Locate the parent**

```bash
git grep -n -E 'Sessions|sessionList|history' src/components/sidebar | head -30
```

Expected: identifies a single component (commonly `Sidebar.tsx` or `SessionsPanel.tsx`) responsible for rendering session entries. Record its path.

- [ ] **Step 2: Write `RunningSessionsList.tsx`**

```tsx
// src/components/sidebar/RunningSessionsList.tsx
import { useEffect, useState } from 'react';

import { authFetch } from '@/components/auth/utils';

interface ActiveSessionsPayload {
  running: string[];
  recent: string[];
  windowMin: number;
}

const POLL_MS = 5000;

export function RunningSessionsList({
  onSelect,
}: {
  onSelect: (sessionId: string) => void;
}) {
  const [data, setData] = useState<ActiveSessionsPayload | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const tick = async () => {
      try {
        const res = await authFetch('/api/sessions/active');
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const next: ActiveSessionsPayload = await res.json();
        if (!cancelled) {
          setData(next);
          setError(null);
        }
      } catch (e: any) {
        if (!cancelled) setError(e.message ?? String(e));
      }
    };
    void tick();
    const id = setInterval(tick, POLL_MS);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  if (error) return <div className="p-3 text-red-500 text-sm">Error: {error}</div>;
  if (!data) return <div className="p-3 text-zinc-400 text-sm">Loading…</div>;

  const empty = data.running.length === 0 && data.recent.length === 0;
  if (empty) {
    return (
      <div className="p-3 text-zinc-400 text-sm">
        No active Claude sessions. Start one with <code>claude</code> in any project.
      </div>
    );
  }

  return (
    <div className="space-y-3 p-2">
      {data.running.length > 0 && (
        <section>
          <h3 className="text-xs font-semibold uppercase text-emerald-400 mb-1">Running</h3>
          <ul className="space-y-1">
            {data.running.map(id => (
              <li
                key={id}
                onClick={() => onSelect(id)}
                className="cursor-pointer rounded px-2 py-1 hover:bg-zinc-800 flex items-center gap-2"
              >
                <span className="h-2 w-2 rounded-full bg-emerald-400 animate-pulse" />
                <span className="font-mono text-xs truncate">{id}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
      {data.recent.length > 0 && (
        <section>
          <h3 className="text-xs font-semibold uppercase text-zinc-500 mb-1">
            Recent ({data.windowMin}m)
          </h3>
          <ul className="space-y-1">
            {data.recent.map(id => (
              <li
                key={id}
                onClick={() => onSelect(id)}
                className="cursor-pointer rounded px-2 py-1 hover:bg-zinc-800 flex items-center gap-2"
              >
                <span className="h-2 w-2 rounded-full bg-zinc-500" />
                <span className="font-mono text-xs truncate">{id}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}
```

If `authFetch` doesn't exist in `src/components/auth/utils.ts`, peek at how an existing component (e.g. anything in `src/components/main-content/`) reads `/api/projects` — match that pattern. Common name: `apiFetch` from `src/lib/api.ts`. Use whatever the codebase already uses; do not introduce a new HTTP client.

- [ ] **Step 3: Wire into the parent sidebar**

In the parent file located in Step 1, replace the previous all-sessions list element with `<RunningSessionsList onSelect={…} />`, threading through the existing selection handler.

If the parent used to render a "history" toggle, archived sessions tab, or filter pills, delete that UI here as well — spec §8 makes it explicit there is no history view.

- [ ] **Step 4: Typecheck + start dev server + manual check**

```bash
npm run typecheck
npm run dev &
# Open http://127.0.0.1:5173 in a browser, log in, confirm:
#  - sidebar shows "No active Claude sessions" when none exist
#  - start `claude` in a separate terminal in some project; within 5s the
#    session ID appears under "Running" with a green dot.
#  - exit claude; within ~30 min it moves to "Recent" with a gray dot; touch
#    a JSONL with `touch` to verify movement faster.
kill %1
```

- [ ] **Step 5: Commit**

```bash
git add src/components/sidebar
git commit -m "feat(ui): show only running/recent claude sessions"
```

### Task 2.5: Remove the now-dead "all sessions / archive" UI

A grep sweep to catch anything we missed.

- [ ] **Step 1: Find candidates**

```bash
git grep -n -i -E 'archived|all.?sessions|history.?view' src/components
```

- [ ] **Step 2: For each candidate, decide:**

  - Component is a tab/route that lists archived sessions → delete it and its route registration.
  - Component is shared infrastructure used by the running-list — leave it.

- [ ] **Step 3: Run typecheck and build**

```bash
npm run typecheck
npm run build
```

- [ ] **Step 4: Commit (only if changes were made)**

```bash
git status
git add -A
git commit -m "refactor: drop archived/history session views (no longer reachable)"
```

---

## Phase 3 — TOTP 2FA

### Task 3.1: Add `otplib` dependency

- [ ] **Step 1: Install**

```bash
npm install otplib
```

- [ ] **Step 2: Confirm version pinned**

```bash
grep '"otplib"' package.json
```

Expected: line present.

- [ ] **Step 3: Commit**

```bash
git add package.json package-lock.json
git commit -m "chore: add otplib for TOTP generation/verification"
```

### Task 3.2: DB schema — add `totp_*` columns and migrate

**Files:**
- Modify: `server/modules/database/schema.ts` (add columns to `USER_TABLE_SCHEMA_SQL`)
- Modify: `server/modules/database/migrations.ts` (add `ALTER TABLE` for upgrade paths)
- Test: `server/modules/database/migrations.totp.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// server/modules/database/migrations.totp.test.ts
import assert from 'node:assert/strict';
import Database from 'better-sqlite3';
import test from 'node:test';

import { runMigrations } from '@/modules/database/migrations.js';
import { INIT_SCHEMA_SQL } from '@/modules/database/schema.js';

test('users table gains totp_secret/totp_enabled/recovery_hash after migration', () => {
  const db = new Database(':memory:');
  db.exec(INIT_SCHEMA_SQL);
  runMigrations(db);
  const cols = (db.prepare("PRAGMA table_info(users)").all() as { name: string }[]).map(c => c.name);
  assert.ok(cols.includes('totp_secret'), 'expected totp_secret');
  assert.ok(cols.includes('totp_enabled'), 'expected totp_enabled');
  assert.ok(cols.includes('recovery_hash'), 'expected recovery_hash');
});

test('migration is idempotent on a db that already has the columns', () => {
  const db = new Database(':memory:');
  db.exec(INIT_SCHEMA_SQL);
  runMigrations(db);
  // Second run must not throw on duplicate columns.
  runMigrations(db);
  const count = db.prepare("SELECT COUNT(*) AS n FROM pragma_table_info('users') WHERE name='totp_secret'").get() as { n: number };
  assert.equal(count.n, 1);
});
```

- [ ] **Step 2: Run, confirm failure**

```bash
npx tsx --test server/modules/database/migrations.totp.test.ts
```

- [ ] **Step 3: Add columns to fresh schema**

Edit `server/modules/database/schema.ts`. Change the `USER_TABLE_SCHEMA_SQL` constant to:

```ts
const USER_TABLE_SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_login DATETIME,
    is_active BOOLEAN DEFAULT 1,
    git_name TEXT,
    git_email TEXT,
    has_completed_onboarding BOOLEAN DEFAULT 0,
    totp_secret TEXT,
    totp_enabled INTEGER DEFAULT 0,
    recovery_hash TEXT
);
`;
```

- [ ] **Step 4: Add upgrade-path migrations**

In `server/modules/database/migrations.ts`, inside `runMigrations`, immediately after the existing `addColumnToTableIfNotExists` calls for `git_name` / `git_email` / `has_completed_onboarding`, append:

```ts
    addColumnToTableIfNotExists(db, 'users', userColumnNames, 'totp_secret', 'TEXT');
    addColumnToTableIfNotExists(db, 'users', userColumnNames, 'totp_enabled', 'INTEGER DEFAULT 0');
    addColumnToTableIfNotExists(db, 'users', userColumnNames, 'recovery_hash', 'TEXT');
```

Important: `userColumnNames` is fixed at the top of `runMigrations`. If you add the three columns, subsequent code that re-reads `userColumnNames` for new columns must re-query — but nothing currently does, so this is fine.

- [ ] **Step 5: Run tests, confirm pass**

```bash
npx tsx --test server/modules/database/migrations.totp.test.ts
```

- [ ] **Step 6: Commit**

```bash
git add server/modules/database
git commit -m "feat(db): add totp_secret/totp_enabled/recovery_hash to users"
```

### Task 3.3: TOTP service — seal/unseal + verify

**Files:**
- Create: `server/services/totp.service.ts`
- Test: `server/services/totp.service.test.ts`

The secret is AES-256-GCM sealed with a key derived from `process.env.JWT_SECRET` via SHA-256. We never store the secret in plaintext.

- [ ] **Step 1: Write the failing test**

```ts
// server/services/totp.service.test.ts
import assert from 'node:assert/strict';
import { authenticator } from 'otplib';
import test from 'node:test';

import { totpService } from '@/services/totp.service.js';

process.env.JWT_SECRET = 'unit-test-key-do-not-use-in-prod';

test('sealSecret/unsealSecret round-trip yields the original secret', () => {
  const secret = authenticator.generateSecret();
  const sealed = totpService.sealSecret(secret);
  assert.notEqual(sealed, secret);
  assert.equal(totpService.unsealSecret(sealed), secret);
});

test('verifyCode accepts a code generated from the same secret', () => {
  const secret = authenticator.generateSecret();
  const code = authenticator.generate(secret);
  assert.equal(totpService.verifyCode(secret, code), true);
});

test('verifyCode rejects an obviously wrong code', () => {
  const secret = authenticator.generateSecret();
  assert.equal(totpService.verifyCode(secret, '000000'), false);
});

test('provisioningUri encodes label and issuer', () => {
  const uri = totpService.provisioningUri('alice', 'JBSWY3DPEHPK3PXP');
  assert.match(uri, /^otpauth:\/\/totp\/claudecodeui-local:alice\?/);
  assert.match(uri, /secret=JBSWY3DPEHPK3PXP/);
  assert.match(uri, /issuer=claudecodeui-local/);
});
```

- [ ] **Step 2: Run, confirm failure**

```bash
npx tsx --test server/services/totp.service.test.ts
```

- [ ] **Step 3: Implement**

```ts
// server/services/totp.service.ts
import crypto from 'node:crypto';
import { authenticator } from 'otplib';

const ISSUER = 'claudecodeui-local';

function getKey(): Buffer {
  const seed = process.env.JWT_SECRET;
  if (!seed) {
    throw new Error('JWT_SECRET must be set before sealing TOTP secrets');
  }
  return crypto.createHash('sha256').update(seed).digest();
}

export const totpService = {
  generateSecret(): string {
    return authenticator.generateSecret();
  },

  sealSecret(secret: string): string {
    const key = getKey();
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
    const enc = Buffer.concat([cipher.update(secret, 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();
    // iv || tag || ciphertext, base64
    return Buffer.concat([iv, tag, enc]).toString('base64');
  },

  unsealSecret(sealed: string): string {
    const buf = Buffer.from(sealed, 'base64');
    const iv = buf.subarray(0, 12);
    const tag = buf.subarray(12, 28);
    const enc = buf.subarray(28);
    const decipher = crypto.createDecipheriv('aes-256-gcm', getKey(), iv);
    decipher.setAuthTag(tag);
    const dec = Buffer.concat([decipher.update(enc), decipher.final()]);
    return dec.toString('utf8');
  },

  verifyCode(secret: string, code: string): boolean {
    return authenticator.verify({ token: code, secret });
  },

  provisioningUri(username: string, secret: string): string {
    return authenticator.keyuri(username, ISSUER, secret);
  },
};
```

- [ ] **Step 4: Run, confirm pass**

```bash
npx tsx --test server/services/totp.service.test.ts
```

- [ ] **Step 5: Commit**

```bash
git add server/services/totp.service.ts server/services/totp.service.test.ts
git commit -m "feat(auth): TOTP service with AES-GCM sealed secret"
```

### Task 3.4: User-DB helpers for TOTP

**Files:**
- Modify: `server/modules/database/repositories/users.repository.ts` (find by `git grep -n 'userDb\|users\.repository'`); if no repository file exists yet, add the helpers next to where `getUserByUsername`/`createUser` are defined.
- Test: same directory as the helper file (`*.totp.test.ts`).

- [ ] **Step 1: Locate the existing user-DB module**

```bash
git grep -n 'getUserByUsername\|createUser' server/modules/database
```

Open the file that defines them. The plan calls this `users.repository.ts` below; substitute the real path the grep returned.

- [ ] **Step 2: Write the failing test**

```ts
// server/modules/database/repositories/users.totp.test.ts
import assert from 'node:assert/strict';
import Database from 'better-sqlite3';
import test from 'node:test';

import { runMigrations } from '@/modules/database/migrations.js';
import { INIT_SCHEMA_SQL } from '@/modules/database/schema.js';
import { userDb } from '@/modules/database/repositories/users.repository.js';

function makeDb() {
  const db = new Database(':memory:');
  db.exec(INIT_SCHEMA_SQL);
  runMigrations(db);
  return db;
}

test('setTotp/clearTotp + getTotpStatus round-trip', () => {
  const db = makeDb();
  userDb.bindDb(db);            // dependency-injection shim added in Step 3
  userDb.createUser('alice', '$2b$10$hash');
  const u = userDb.getUserByUsername('alice');
  userDb.setTotp(u.id, 'sealed-secret', 'bcrypt-recovery-hash');
  assert.deepEqual(userDb.getTotpStatus(u.id), {
    enabled: true,
    secret: 'sealed-secret',
    recoveryHash: 'bcrypt-recovery-hash',
  });
  userDb.clearTotp(u.id);
  assert.deepEqual(userDb.getTotpStatus(u.id), {
    enabled: false,
    secret: null,
    recoveryHash: null,
  });
});
```

(If `userDb` is exported as a singleton bound to a specific db, you may not need `bindDb`; in that case wire the test to use the actual single instance by setting `DATABASE_PATH` to a temp file — see the existing `sessions.db.integration.test.ts` for the pattern.)

- [ ] **Step 3: Run, confirm failure**

```bash
npx tsx --test server/modules/database/repositories/users.totp.test.ts
```

- [ ] **Step 4: Implement**

In `users.repository.ts`, add three functions next to the existing ones:

```ts
  setTotp(userId: number, sealedSecret: string, recoveryHash: string): void {
    db.prepare(
      'UPDATE users SET totp_secret = ?, recovery_hash = ?, totp_enabled = 1 WHERE id = ?'
    ).run(sealedSecret, recoveryHash, userId);
  },

  clearTotp(userId: number): void {
    db.prepare(
      'UPDATE users SET totp_secret = NULL, recovery_hash = NULL, totp_enabled = 0 WHERE id = ?'
    ).run(userId);
  },

  getTotpStatus(userId: number): {
    enabled: boolean;
    secret: string | null;
    recoveryHash: string | null;
  } {
    const row = db
      .prepare('SELECT totp_secret, recovery_hash, totp_enabled FROM users WHERE id = ?')
      .get(userId) as
      | { totp_secret: string | null; recovery_hash: string | null; totp_enabled: number }
      | undefined;
    return {
      enabled: !!row?.totp_enabled,
      secret: row?.totp_secret ?? null,
      recoveryHash: row?.recovery_hash ?? null,
    };
  },
```

Match the existing module's import style (CommonJS-with-ESM-export or pure ESM — check the top of the file).

- [ ] **Step 5: Run, confirm pass**

```bash
npx tsx --test server/modules/database/repositories/users.totp.test.ts
```

- [ ] **Step 6: Commit**

```bash
git add server/modules/database
git commit -m "feat(db): user-repo helpers for TOTP secret/recovery"
```

### Task 3.5: Login flow — emit `requiresTotp` when enabled

**Files:**
- Modify: `server/routes/auth.js` (`POST /login`)
- Test: extend any existing auth test, or create `server/routes/auth.totp.test.ts`.

- [ ] **Step 1: Write the failing test**

```ts
// server/routes/auth.totp.test.ts
import assert from 'node:assert/strict';
import bcrypt from 'bcrypt';
import express from 'express';
import http from 'node:http';
import test from 'node:test';

import authRoutes from '@/routes/auth.js';
import { userDb } from '@/modules/database/repositories/users.repository.js';

process.env.JWT_SECRET = 'unit-test-key';

async function bootApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/auth', authRoutes);
  return await new Promise<{ url: string; close: () => void }>(resolve => {
    const s = http.createServer(app).listen(0, () => {
      resolve({
        url: `http://127.0.0.1:${(s.address() as any).port}`,
        close: () => s.close(),
      });
    });
  });
}

test('login without TOTP returns final JWT', async () => {
  const pw = await bcrypt.hash('correct horse', 10);
  userDb.createUser('alice', pw);
  const { url, close } = await bootApp();
  try {
    const r = await fetch(`${url}/api/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username: 'alice', password: 'correct horse' }),
    });
    const body = await r.json();
    assert.equal(r.status, 200);
    assert.ok(body.token, 'expected final JWT in response');
    assert.equal(body.requiresTotp, undefined);
  } finally {
    close();
  }
});

test('login with TOTP enabled returns requiresTotp + short-lived token', async () => {
  const pw = await bcrypt.hash('hunter2', 10);
  userDb.createUser('bob', pw);
  const u = userDb.getUserByUsername('bob');
  userDb.setTotp(u.id, 'sealed', 'rec');
  const { url, close } = await bootApp();
  try {
    const r = await fetch(`${url}/api/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username: 'bob', password: 'hunter2' }),
    });
    const body = await r.json();
    assert.equal(r.status, 200);
    assert.equal(body.requiresTotp, true);
    assert.ok(body.totpToken);
    assert.equal(body.token, undefined);
  } finally {
    close();
  }
});
```

(If the existing auth test infrastructure uses a different boot helper, copy that helper rather than writing a new one.)

- [ ] **Step 2: Run, confirm failures**

```bash
npx tsx --test server/routes/auth.totp.test.ts
```

- [ ] **Step 3: Modify `POST /login`**

Open `server/routes/auth.js`. Find the success branch of `/login` (where it currently signs and returns the final JWT). Replace its tail with:

```js
const totp = userDb.getTotpStatus(user.id);
if (totp.enabled) {
  const totpToken = jwt.sign(
    { sub: user.id, purpose: 'totp_pending' },
    JWT_SECRET,
    { expiresIn: '5m' }
  );
  return res.json({ requiresTotp: true, totpToken });
}
const token = jwt.sign({ sub: user.id }, JWT_SECRET, { expiresIn: '7d' });
return res.json({ token });
```

(Constants `JWT_SECRET` and `jwt` are already imported in this file. If the upstream uses an `issueToken` helper, use it; the structure of the conditional is what matters.)

- [ ] **Step 4: Run tests, confirm pass**

```bash
npx tsx --test server/routes/auth.totp.test.ts
```

- [ ] **Step 5: Commit**

```bash
git add server/routes/auth.js server/routes/auth.totp.test.ts
git commit -m "feat(auth): /login returns requiresTotp when TOTP enabled"
```

### Task 3.6: TOTP step-2 login endpoint `POST /login/totp`

**Files:**
- Modify: `server/routes/auth.js`
- Test: extend `server/routes/auth.totp.test.ts`.

- [ ] **Step 1: Append to the existing test file**

```ts
import { authenticator } from 'otplib';
import { totpService } from '@/services/totp.service.js';

test('login/totp exchanges valid code + totpToken for final JWT', async () => {
  const pw = await bcrypt.hash('hunter2', 10);
  userDb.createUser('carol', pw);
  const u = userDb.getUserByUsername('carol');
  const secret = authenticator.generateSecret();
  userDb.setTotp(u.id, totpService.sealSecret(secret), 'rec');
  const { url, close } = await bootApp();
  try {
    const step1 = await (
      await fetch(`${url}/api/auth/login`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ username: 'carol', password: 'hunter2' }),
      })
    ).json();
    const code = authenticator.generate(secret);
    const step2 = await fetch(`${url}/api/auth/login/totp`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ totpToken: step1.totpToken, code }),
    });
    const body = await step2.json();
    assert.equal(step2.status, 200);
    assert.ok(body.token);
  } finally {
    close();
  }
});

test('login/totp rejects a wrong code', async () => {
  const pw = await bcrypt.hash('hunter2', 10);
  userDb.createUser('dan', pw);
  const u = userDb.getUserByUsername('dan');
  const secret = authenticator.generateSecret();
  userDb.setTotp(u.id, totpService.sealSecret(secret), 'rec');
  const { url, close } = await bootApp();
  try {
    const step1 = await (
      await fetch(`${url}/api/auth/login`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ username: 'dan', password: 'hunter2' }),
      })
    ).json();
    const r = await fetch(`${url}/api/auth/login/totp`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ totpToken: step1.totpToken, code: '000000' }),
    });
    assert.equal(r.status, 401);
  } finally {
    close();
  }
});
```

- [ ] **Step 2: Run, confirm failures**

- [ ] **Step 3: Implement**

Append to `server/routes/auth.js`:

```js
router.post('/login/totp', async (req, res) => {
  const { totpToken, code } = req.body ?? {};
  if (!totpToken || !code) {
    return res.status(400).json({ error: 'totpToken and code are required' });
  }
  let payload;
  try {
    payload = jwt.verify(totpToken, JWT_SECRET);
  } catch {
    return res.status(401).json({ error: 'invalid totpToken' });
  }
  if (payload.purpose !== 'totp_pending') {
    return res.status(401).json({ error: 'wrong token purpose' });
  }
  const status = userDb.getTotpStatus(payload.sub);
  if (!status.enabled || !status.secret) {
    return res.status(400).json({ error: 'TOTP not configured' });
  }
  const secret = totpService.unsealSecret(status.secret);
  if (!totpService.verifyCode(secret, String(code))) {
    return res.status(401).json({ error: 'invalid code' });
  }
  const token = jwt.sign({ sub: payload.sub }, JWT_SECRET, { expiresIn: '7d' });
  return res.json({ token });
});
```

Required imports at the top of the file (add only those that are missing):

```js
import { totpService } from '../services/totp.service.js';
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add server/routes/auth.js server/routes/auth.totp.test.ts
git commit -m "feat(auth): POST /login/totp completes the second factor"
```

### Task 3.7: TOTP setup endpoints

Two endpoints, both authenticated with the regular session JWT (you set up TOTP after first login):

- `POST /api/auth/totp/setup` → returns `{ secret, otpauthUri, recoveryCode }`. Stores nothing yet.
- `POST /api/auth/totp/verify-setup` → body `{ secret, code, recoveryCode }`. On success, seals the secret + bcrypts the recovery code + flips `totp_enabled=1`.

**Files:**
- Modify: `server/routes/auth.js`
- Test: extend `server/routes/auth.totp.test.ts`.

- [ ] **Step 1: Append tests**

```ts
test('TOTP setup → verify-setup → login flow end-to-end', async () => {
  const pw = await bcrypt.hash('p', 10);
  userDb.createUser('eve', pw);
  const u = userDb.getUserByUsername('eve');
  const sessionToken = jwt.sign({ sub: u.id }, process.env.JWT_SECRET!, { expiresIn: '1h' });

  const { url, close } = await bootApp();
  try {
    const setupRes = await fetch(`${url}/api/auth/totp/setup`, {
      method: 'POST',
      headers: { authorization: `Bearer ${sessionToken}`, 'content-type': 'application/json' },
    });
    const setup = await setupRes.json();
    assert.ok(setup.secret && setup.otpauthUri && setup.recoveryCode);

    const code = (await import('otplib')).authenticator.generate(setup.secret);
    const verify = await fetch(`${url}/api/auth/totp/verify-setup`, {
      method: 'POST',
      headers: { authorization: `Bearer ${sessionToken}`, 'content-type': 'application/json' },
      body: JSON.stringify({ secret: setup.secret, code, recoveryCode: setup.recoveryCode }),
    });
    assert.equal(verify.status, 200);
    assert.equal(userDb.getTotpStatus(u.id).enabled, true);
  } finally {
    close();
  }
});
```

(The test boot helper above used a router without `authenticateToken` middleware — for these endpoints you need that middleware. If the upstream wires it inside `routes/auth.js`, no change is needed; otherwise update `bootApp` to attach `authenticateToken` to the totp setup endpoints. Mirror what the production router does.)

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement**

Append to `server/routes/auth.js`:

```js
import bcrypt from 'bcrypt';
import crypto from 'node:crypto';
import { authenticateToken } from '../middleware/auth.js';

function makeRecoveryCode() {
  return crypto.randomBytes(10).toString('base64url');
}

router.post('/totp/setup', authenticateToken, (req, res) => {
  const secret = totpService.generateSecret();
  const user = req.user;
  const recoveryCode = makeRecoveryCode();
  const otpauthUri = totpService.provisioningUri(user.username ?? String(user.id), secret);
  res.json({ secret, otpauthUri, recoveryCode });
});

router.post('/totp/verify-setup', authenticateToken, async (req, res) => {
  const { secret, code, recoveryCode } = req.body ?? {};
  if (!secret || !code || !recoveryCode) {
    return res.status(400).json({ error: 'secret, code, recoveryCode required' });
  }
  if (!totpService.verifyCode(secret, String(code))) {
    return res.status(401).json({ error: 'code does not match secret' });
  }
  const sealed = totpService.sealSecret(secret);
  const recoveryHash = await bcrypt.hash(recoveryCode, 10);
  userDb.setTotp(req.user.id, sealed, recoveryHash);
  res.json({ ok: true });
});
```

If `bcrypt` is already imported at the top, do not re-import it; just use the existing binding.

- [ ] **Step 4: Run tests, confirm pass**

```bash
npx tsx --test server/routes/auth.totp.test.ts
```

- [ ] **Step 5: Commit**

```bash
git add server/routes/auth.js server/routes/auth.totp.test.ts
git commit -m "feat(auth): TOTP setup + verify-setup endpoints"
```

### Task 3.8: Recovery-code login path

Treat the recovery code as a one-shot replacement for the TOTP code in `POST /login/totp`. After use, regenerate a fresh recovery code and surface it once.

**Files:**
- Modify: `server/routes/auth.js` (`POST /login/totp` body handling)
- Test: extend `server/routes/auth.totp.test.ts`.

- [ ] **Step 1: Add test**

```ts
test('login/totp accepts a recovery code instead of a TOTP code; rotates it', async () => {
  const pw = await bcrypt.hash('p', 10);
  userDb.createUser('frank', pw);
  const u = userDb.getUserByUsername('frank');
  const secret = (await import('otplib')).authenticator.generateSecret();
  const recovery = 'recovery123';
  userDb.setTotp(u.id, totpService.sealSecret(secret), await bcrypt.hash(recovery, 10));

  const { url, close } = await bootApp();
  try {
    const step1 = await (
      await fetch(`${url}/api/auth/login`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ username: 'frank', password: 'p' }),
      })
    ).json();
    const ok = await fetch(`${url}/api/auth/login/totp`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ totpToken: step1.totpToken, recoveryCode: recovery }),
    });
    const body = await ok.json();
    assert.equal(ok.status, 200);
    assert.ok(body.token);
    assert.ok(body.newRecoveryCode, 'expected a rotated recovery code');
  } finally {
    close();
  }
});
```

- [ ] **Step 2: Run, confirm failure.**

- [ ] **Step 3: Extend `POST /login/totp`**

Inside the handler, after `payload` is verified and `status` loaded, branch on body:

```js
const { code, recoveryCode } = req.body ?? {};
if (recoveryCode) {
  if (!status.recoveryHash || !(await bcrypt.compare(String(recoveryCode), status.recoveryHash))) {
    return res.status(401).json({ error: 'invalid recovery code' });
  }
  const newRecoveryCode = makeRecoveryCode();
  userDb.setTotp(payload.sub, status.secret, await bcrypt.hash(newRecoveryCode, 10));
  const token = jwt.sign({ sub: payload.sub }, JWT_SECRET, { expiresIn: '7d' });
  return res.json({ token, newRecoveryCode });
}
// fall through to the existing TOTP-code path
```

Make sure the original `totpToken && code` validation path still runs when only `code` is provided. The complete handler should accept *either* `code` *or* `recoveryCode` but not require both.

- [ ] **Step 4: Run, confirm pass.**

- [ ] **Step 5: Commit**

```bash
git add server/routes/auth.js server/routes/auth.totp.test.ts
git commit -m "feat(auth): recovery-code login with rotation"
```

### Task 3.9: Emergency reset script

**Files:**
- Create: `scripts/reset-totp.js`
- Modify: `package.json` — add a `"reset-totp"` script entry.

- [ ] **Step 1: Write the script**

```js
// scripts/reset-totp.js
#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { userDb } from '../server/modules/database/repositories/users.repository.js';

const username = process.argv[2];
if (!username) {
  console.error('Usage: npm run reset-totp -- <username>');
  process.exit(2);
}
const user = userDb.getUserByUsername(username);
if (!user) {
  console.error(`No active user named "${username}"`);
  process.exit(1);
}
userDb.clearTotp(user.id);
console.log(`TOTP cleared for ${username}.`);
```

(If `users.repository.ts` is TypeScript and not directly runnable from a `.js` file, change the script to a `.ts` and invoke via `npx tsx scripts/reset-totp.ts` — the npm script wrapper does this regardless. Verify by running it once at the end of this task.)

- [ ] **Step 2: Add the npm script**

In `package.json`, inside `"scripts"`, add:

```json
"reset-totp": "tsx scripts/reset-totp.ts"
```

(Change the file extension above accordingly if you wrote `.js` — they must match.)

- [ ] **Step 3: Smoke test against a fresh DB**

```bash
DATABASE_PATH=/tmp/reset-totp-smoke.db npx tsx -e "
import { runMigrations } from './server/modules/database/migrations.js';
import { INIT_SCHEMA_SQL } from './server/modules/database/schema.js';
import { userDb } from './server/modules/database/repositories/users.repository.js';
import Database from 'better-sqlite3';
const db = new Database('/tmp/reset-totp-smoke.db');
db.exec(INIT_SCHEMA_SQL); runMigrations(db);
userDb.createUser('smoketester','x');
const u = userDb.getUserByUsername('smoketester');
userDb.setTotp(u.id, 'sealed', 'hash');
console.log('before:', userDb.getTotpStatus(u.id).enabled);
"
DATABASE_PATH=/tmp/reset-totp-smoke.db npm run reset-totp -- smoketester
DATABASE_PATH=/tmp/reset-totp-smoke.db npx tsx -e "
import { userDb } from './server/modules/database/repositories/users.repository.js';
const u = userDb.getUserByUsername('smoketester');
console.log('after:', userDb.getTotpStatus(u.id).enabled);
"
rm /tmp/reset-totp-smoke.db
```

Expected: `before: true`, `after: false`.

- [ ] **Step 4: Commit**

```bash
git add scripts/reset-totp.ts package.json
git commit -m "feat(auth): npm run reset-totp -- <username>"
```

### Task 3.10: Login lockout (5 attempts / 15 min)

Single-user app — in-memory map keyed by `username` is sufficient. Keep separate from any existing rate-limit on the underlying password step.

**Files:**
- Modify: `server/routes/auth.js` (`POST /login/totp`)
- Test: extend `server/routes/auth.totp.test.ts`

- [ ] **Step 1: Add test**

```ts
test('TOTP failures lock the account for 15 minutes after 5 attempts', async () => {
  const pw = await bcrypt.hash('p', 10);
  userDb.createUser('locky', pw);
  const u = userDb.getUserByUsername('locky');
  userDb.setTotp(
    u.id,
    totpService.sealSecret((await import('otplib')).authenticator.generateSecret()),
    'r'
  );
  const { url, close } = await bootApp();
  try {
    let lastStatus = 0;
    for (let i = 0; i < 6; i++) {
      const step1 = await (
        await fetch(`${url}/api/auth/login`, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ username: 'locky', password: 'p' }),
        })
      ).json();
      const r = await fetch(`${url}/api/auth/login/totp`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ totpToken: step1.totpToken, code: '000000' }),
      });
      lastStatus = r.status;
    }
    assert.equal(lastStatus, 429, 'should be locked after 5 wrong codes');
  } finally {
    close();
  }
});
```

- [ ] **Step 2: Run, confirm failure.**

- [ ] **Step 3: Implement**

Inside `server/routes/auth.js`, near the top of the file, add:

```js
const TOTP_LOCK_MAX = 5;
const TOTP_LOCK_WINDOW_MS = 15 * 60 * 1000;
const totpFailures = new Map(); // userId -> { count: number, firstAt: number }

function isLocked(userId) {
  const entry = totpFailures.get(userId);
  if (!entry) return false;
  if (Date.now() - entry.firstAt > TOTP_LOCK_WINDOW_MS) {
    totpFailures.delete(userId);
    return false;
  }
  return entry.count >= TOTP_LOCK_MAX;
}
function recordFailure(userId) {
  const entry = totpFailures.get(userId) ?? { count: 0, firstAt: Date.now() };
  entry.count += 1;
  totpFailures.set(userId, entry);
}
function clearFailures(userId) {
  totpFailures.delete(userId);
}
```

Inside `POST /login/totp`, at the start of the handler after JWT verification:

```js
if (isLocked(payload.sub)) {
  return res.status(429).json({ error: 'too many TOTP failures; try again later' });
}
```

On `invalid code` and `invalid recovery code` branches, call `recordFailure(payload.sub)` *before* the response. On success branches, call `clearFailures(payload.sub)` before the token response.

- [ ] **Step 4: Run, confirm pass.**

- [ ] **Step 5: Commit**

```bash
git add server/routes/auth.js server/routes/auth.totp.test.ts
git commit -m "feat(auth): in-memory TOTP lockout (5 attempts / 15m)"
```

### Task 3.11: Frontend — TOTP verify step in login flow

**Files:**
- Create: `src/components/auth/view/TotpVerifyStep.tsx`
- Modify: `src/components/auth/view/LoginForm.tsx` (route to the verify step when `requiresTotp` is true)
- Modify: `src/components/auth/context/` (whichever context holds the token after login) — store the final JWT, not the totpToken.

- [ ] **Step 1: Write `TotpVerifyStep.tsx`**

```tsx
// src/components/auth/view/TotpVerifyStep.tsx
import { useState } from 'react';

export function TotpVerifyStep({
  totpToken,
  onSuccess,
}: {
  totpToken: string;
  onSuccess: (finalJwt: string, newRecoveryCode?: string) => void;
}) {
  const [code, setCode] = useState('');
  const [recovery, setRecovery] = useState('');
  const [useRecovery, setUseRecovery] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    setBusy(true);
    setError(null);
    try {
      const res = await fetch('/api/auth/login/totp', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          totpToken,
          ...(useRecovery ? { recoveryCode: recovery } : { code }),
        }),
      });
      const body = await res.json();
      if (!res.ok) throw new Error(body.error ?? `HTTP ${res.status}`);
      onSuccess(body.token, body.newRecoveryCode);
    } catch (e: any) {
      setError(e.message ?? String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-3">
      <h2 className="text-lg font-semibold">Second factor</h2>
      {useRecovery ? (
        <input
          autoFocus
          value={recovery}
          onChange={e => setRecovery(e.target.value)}
          className="w-full rounded border border-zinc-700 bg-zinc-900 px-2 py-1 font-mono"
          placeholder="Recovery code"
        />
      ) : (
        <input
          autoFocus
          inputMode="numeric"
          pattern="\d{6}"
          value={code}
          onChange={e => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
          className="w-full rounded border border-zinc-700 bg-zinc-900 px-2 py-1 font-mono text-center text-2xl tracking-widest"
          placeholder="000000"
        />
      )}
      {error && <p className="text-sm text-red-500">{error}</p>}
      <button
        onClick={submit}
        disabled={busy || (useRecovery ? recovery.length === 0 : code.length !== 6)}
        className="w-full rounded bg-emerald-500 px-3 py-2 text-white disabled:opacity-40"
      >
        {busy ? 'Verifying…' : 'Verify'}
      </button>
      <button
        onClick={() => setUseRecovery(v => !v)}
        className="w-full text-xs text-zinc-500 underline"
      >
        {useRecovery ? 'Use TOTP code instead' : 'Use recovery code instead'}
      </button>
    </div>
  );
}
```

- [ ] **Step 2: Wire into `LoginForm.tsx`**

Find the existing `LoginForm` submit handler. After it parses the JSON response from `/api/auth/login`, branch:

```tsx
if (body.requiresTotp) {
  setTotpToken(body.totpToken);
  return; // render <TotpVerifyStep totpToken={…} onSuccess={…} /> in this case
}
onAuthenticated(body.token);
```

`setTotpToken` is a new `useState` you add at the top of the component. The render path then switches between `<form>…` and `<TotpVerifyStep />` based on whether `totpToken` is set.

When `TotpVerifyStep`'s `onSuccess(token, newRecoveryCode)` fires:
- Stash the new recovery code in component state and render it once in a dialog the user must explicitly dismiss ("save this somewhere safe").
- Hand `token` to the same `onAuthenticated` callback the password path uses.

- [ ] **Step 3: Manual e2e check**

```bash
npm run dev
# In a browser:
#  1. Log in with a TOTP-enabled user (set up in Task 3.7).
#  2. Confirm step-2 screen appears, asks for 6 digits.
#  3. Enter a correct code -> lands in the app.
#  4. Log out; this time use the recovery code -> lands in the app, screen
#     surfaces a new recovery code.
```

- [ ] **Step 4: Commit**

```bash
git add src/components/auth
git commit -m "feat(auth-ui): two-step login with TOTP / recovery code"
```

### Task 3.12: Frontend — TOTP setup screen

**Files:**
- Create: `src/components/auth/view/TotpSetupScreen.tsx`
- Modify: post-onboarding flow in `src/components/onboarding/` (find with grep) to require TOTP setup if `totp_enabled = 0`.

- [ ] **Step 1: Find where the onboarding completion handler lives**

```bash
git grep -n 'has_completed_onboarding\|completeOnboarding' src
```

- [ ] **Step 2: Write `TotpSetupScreen.tsx`**

```tsx
// src/components/auth/view/TotpSetupScreen.tsx
import { useEffect, useState } from 'react';
// qrcode is a tiny library; install in Step 4 of this task.
import QRCode from 'qrcode';

export function TotpSetupScreen({ onDone }: { onDone: () => void }) {
  const [data, setData] = useState<{
    secret: string;
    otpauthUri: string;
    recoveryCode: string;
  } | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const r = await fetch('/api/auth/totp/setup', { method: 'POST' });
      const body = await r.json();
      setData(body);
      setQr(await QRCode.toDataURL(body.otpauthUri));
    })().catch(e => setErr(String(e)));
  }, []);

  if (err) return <p className="text-red-500 text-sm">{err}</p>;
  if (!data || !qr) return <p>Loading…</p>;

  const submit = async () => {
    const r = await fetch('/api/auth/totp/verify-setup', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ secret: data.secret, code, recoveryCode: data.recoveryCode }),
    });
    if (!r.ok) {
      const b = await r.json().catch(() => ({}));
      setErr(b.error ?? `HTTP ${r.status}`);
      return;
    }
    onDone();
  };

  return (
    <div className="space-y-4 max-w-md mx-auto py-8">
      <h1 className="text-xl font-semibold">Set up two-factor auth</h1>
      <p className="text-sm text-zinc-400">
        Scan this QR with Google Authenticator / 1Password / Authy, then enter the 6-digit code.
      </p>
      <img src={qr} alt="TOTP QR" className="w-48 h-48 mx-auto bg-white p-2" />
      <p className="text-xs font-mono text-zinc-500 break-all">
        Or paste: <code>{data.secret}</code>
      </p>
      <div className="rounded border border-amber-700 bg-amber-950/40 p-3 text-sm">
        <p className="font-semibold text-amber-300">Save this recovery code now</p>
        <p className="font-mono mt-1">{data.recoveryCode}</p>
        <p className="text-xs text-amber-200/70 mt-2">
          Used once if you lose your authenticator. We will not show it again.
        </p>
      </div>
      <input
        value={code}
        onChange={e => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
        inputMode="numeric"
        className="w-full rounded border border-zinc-700 bg-zinc-900 px-2 py-1 font-mono text-center text-2xl tracking-widest"
        placeholder="000000"
      />
      <button
        onClick={submit}
        disabled={code.length !== 6}
        className="w-full rounded bg-emerald-500 px-3 py-2 text-white disabled:opacity-40"
      >
        Confirm and enable
      </button>
    </div>
  );
}
```

- [ ] **Step 3: Render the setup screen when onboarding completes**

In the onboarding component identified in Step 1, after the user finishes the existing onboarding flow, fetch the current user (existing `GET /api/auth/me`-equivalent — find with grep) and if `totp_enabled` is false, render `<TotpSetupScreen onDone={…} />` before letting the app continue.

If the backend `me` endpoint does not currently surface `totp_enabled`, add it (alter the SELECT in `getUserById` or the `/me` handler to include `totp_enabled`). The TDD step for that change is folded here:

  - Add a test in `server/routes/auth.totp.test.ts` that hits `/api/auth/me` and asserts `totp_enabled` is in the response.
  - Watch it fail, edit the handler, watch it pass.

- [ ] **Step 4: Install `qrcode`**

```bash
npm install qrcode
npm install --save-dev @types/qrcode
```

- [ ] **Step 5: Manual e2e**

```bash
npm run dev
# Create a brand-new user via the regular setup flow,
# verify the TOTP setup screen appears before the main app shows up,
# scan the QR with your phone, confirm the code, save the recovery code,
# log out, log back in, confirm TOTP step is required.
```

- [ ] **Step 6: Commit**

```bash
git add src/components/auth src/components/onboarding package.json package-lock.json
git commit -m "feat(auth-ui): TOTP setup screen with QR + recovery code"
```

---

## Phase 4 — Lock down the listening surface

### Task 4.1: Bind Express to 127.0.0.1 by default

**Files:**
- Modify: `server/index.js` (the `server.listen(…)` call near the bottom)
- Test: `server/index.bind.test.ts` (TCP probe)

- [ ] **Step 1: Find the current listen call**

```bash
git grep -n 'server\.listen\|app\.listen' server
```

The upstream usually calls `server.listen(PORT, …)`. We want `server.listen(PORT, HOST, …)`.

- [ ] **Step 2: Write the failing test**

```ts
// server/index.bind.test.ts
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import test from 'node:test';

test('default bind only accepts 127.0.0.1 connections', async () => {
  // Spawn the app in a subprocess so its singleton state doesn't leak.
  const { spawn } = await import('node:child_process');
  const child = spawn('npx', ['tsx', 'server/index.js'], {
    env: { ...process.env, SERVER_PORT: '4321' },
    stdio: 'pipe',
  });
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('server did not start')), 8000);
    child.stdout!.on('data', d => {
      if (String(d).includes('listening') || String(d).includes('4321')) {
        clearTimeout(timer);
        resolve();
      }
    });
    child.on('exit', () => reject(new Error('server crashed before listening')));
  });
  try {
    const ok = await new Promise<boolean>(res => {
      const s = net.createConnection({ host: '127.0.0.1', port: 4321 }, () => {
        s.end(); res(true);
      });
      s.on('error', () => res(false));
    });
    assert.equal(ok, true, 'expected loopback connect to succeed');

    // We can't easily test that non-loopback is rejected on a dev box; the
    // assertion above plus a manual log-line check that the bind address is
    // 127.0.0.1 is the contract we enforce here.
    const logged = (child.stdout as any).read()?.toString() ?? '';
    assert.match(logged + '', /127\.0\.0\.1/);
  } finally {
    child.kill();
  }
});
```

(This test is heavyweight and depends on the server actually booting clean — keep an eye on it across phase 3 changes.)

- [ ] **Step 3: Run, confirm failure**

```bash
npx tsx --test server/index.bind.test.ts
```

- [ ] **Step 4: Change the listen call**

```js
const HOST = process.env.HOST ?? '127.0.0.1';
const PORT = Number(process.env.SERVER_PORT) || 3001;
server.listen(PORT, HOST, () => {
  console.log(`[server] listening on http://${HOST}:${PORT}`);
});
```

- [ ] **Step 5: Run, confirm pass**

```bash
npx tsx --test server/index.bind.test.ts
```

- [ ] **Step 6: Document the override in README**

Add a short note to `README.md`:

> The server binds to `127.0.0.1:3001` by default. Set `HOST=0.0.0.0` to expose it directly on the LAN.

- [ ] **Step 7: Commit**

```bash
git add server/index.js server/index.bind.test.ts README.md
git commit -m "feat(server): bind 127.0.0.1 by default; override via HOST"
```

---

## Phase 5 — Deployment artifacts

This phase produces config files, not running services. Verification is "does it parse / does nginx -t pass / does frpc start"; no unit tests.

### Task 5.1: FRP client (Mac) template

**Files:**
- Create: `deploy/frpc.toml`

- [ ] **Step 1: Write the file**

```toml
# deploy/frpc.toml — copy to ~/.config/frpc/frpc.toml and edit.
# Mac side (this machine). frpc dials out to the server on port 7000.

serverAddr = "<SERVER_IP>"
serverPort = 7000
loginFailExit = false        # keep retrying forever, even on auth errors

# Shared secret with frps. Generate with: openssl rand -hex 32
auth.method = "token"
auth.token  = "REPLACE_WITH_RANDOM_TOKEN"

# Encrypt the frpc<->frps tunnel itself, in addition to nginx TLS at the edge.
transport.tls.enable = true
transport.heartbeatInterval = 30
transport.heartbeatTimeout  = 90

[[proxies]]
name       = "claudecodeui-local"
type       = "tcp"
localIP    = "127.0.0.1"
localPort  = 3001
remotePort = 7080            # frps will expose this on 127.0.0.1:7080 of the server
```

- [ ] **Step 2: Commit**

```bash
git add deploy/frpc.toml
git commit -m "chore(deploy): frpc.toml template for Mac client"
```

### Task 5.2: FRP server template

**Files:**
- Create: `deploy/frps.toml`

- [ ] **Step 1: Write the file**

```toml
# deploy/frps.toml — copy to /etc/frp/frps.toml on the Tencent Cloud server.

bindPort = 7000                # ctrl channel, public-internet-facing — only used by frpc

# Server only exposes tunneled services on loopback. nginx is the public face.
allowPorts = [{ start = 7080, end = 7080 }]

auth.method = "token"
auth.token  = "REPLACE_WITH_RANDOM_TOKEN"   # must match frpc

transport.tls.force = true     # reject non-TLS frpc connections

# Optional admin web UI (loopback only)
webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "REPLACE"
webServer.password = "REPLACE"
```

- [ ] **Step 2: Commit**

```bash
git add deploy/frps.toml
git commit -m "chore(deploy): frps.toml template for tunnel server"
```

### Task 5.3: nginx vhost

**Files:**
- Create: `deploy/nginx-cli.conf`

- [ ] **Step 1: Write the file**

```nginx
# deploy/nginx-cli.conf — drop into /etc/nginx/conf.d/ (Docker volume or host),
# replace cli.example.com with the chosen subdomain, run `nginx -t`, reload.

server {
    listen 80;
    server_name cli.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name cli.example.com;

    # Use existing Let's Encrypt certs already provisioned on this server.
    ssl_certificate     /etc/letsencrypt/live/cli.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/cli.example.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    # Limit body size to something sensible for chat payloads (image uploads use ws).
    client_max_body_size 25m;

    location / {
        proxy_pass http://127.0.0.1:7080;
        proxy_http_version 1.1;

        # WebSocket upgrade
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Long-running streams (claude tool output)
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;

        # Disable buffering for SSE/WS traffic
        proxy_buffering off;
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add deploy/nginx-cli.conf
git commit -m "chore(deploy): nginx vhost for cli subdomain"
```

### Task 5.4: launchd unit (Mac)

**Files:**
- Create: `deploy/launchd/com.user.frpc.plist`

- [ ] **Step 1: Write the file**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>          <string>com.user.frpc</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/frpc</string>
        <string>-c</string>
        <string>/Users/REPLACE_USER/.config/frpc/frpc.toml</string>
    </array>
    <key>RunAtLoad</key>      <true/>
    <key>KeepAlive</key>      <true/>
    <key>StandardOutPath</key><string>/tmp/frpc.out.log</string>
    <key>StandardErrorPath</key><string>/tmp/frpc.err.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Commit**

```bash
git add deploy/launchd
git commit -m "chore(deploy): launchd plist for frpc on Mac"
```

### Task 5.5: systemd unit (server)

**Files:**
- Create: `deploy/systemd/frps.service`

- [ ] **Step 1: Write the file**

```ini
[Unit]
Description=frps tunnel server for claudecodeui-local
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=always
RestartSec=5
User=frp

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Commit**

```bash
git add deploy/systemd
git commit -m "chore(deploy): systemd unit for frps on server"
```

### Task 5.6: Deployment README

**Files:**
- Create: `deploy/README.md`

- [ ] **Step 1: Write the file**

````markdown
# Deploying claudecodeui-local

Two machines:
- **Mac (this checkout)** — runs the app on `127.0.0.1:3001`, runs `frpc` outbound.
- **Tencent Cloud server (<SERVER_IP>)** — runs `frps` on `:7000`, nginx terminates TLS for a chosen subdomain (`cli.<domain>`).

## 0. Pick a subdomain

Choose a hostname (e.g. `cli.example.com`). Point its DNS A record at `<SERVER_IP>`. Wait for propagation.

## 1. Generate a shared FRP token

On either machine:

```bash
openssl rand -hex 32
```

Save the value — paste it into both `frpc.toml` (Mac) and `frps.toml` (server).

## 2. Server side

```bash
# Install frps (Debian/Ubuntu example; adjust for your distro)
wget https://github.com/fatedier/frp/releases/latest/download/frp_*_linux_amd64.tar.gz
tar xf frp_*_linux_amd64.tar.gz
sudo install -m 755 frp_*_linux_amd64/frps /usr/local/bin/frps
sudo useradd -r -s /usr/sbin/nologin frp
sudo mkdir -p /etc/frp
sudo install -m 600 -o frp -g frp deploy/frps.toml /etc/frp/frps.toml
# … edit /etc/frp/frps.toml: paste the auth.token, set webServer credentials …
sudo install -m 644 deploy/systemd/frps.service /etc/systemd/system/frps.service
sudo systemctl daemon-reload
sudo systemctl enable --now frps
sudo systemctl status frps --no-pager
```

Open `7000/tcp` on the server's firewall (Tencent Cloud security group) inbound from any source. Do **not** open `7080` — it must stay loopback-only.

## 3. nginx vhost

```bash
sudo install -m 644 deploy/nginx-cli.conf /etc/nginx/conf.d/cli.conf
# … replace cli.example.com placeholders …
sudo certbot --nginx -d cli.example.com   # if certs don't already exist
sudo nginx -t && sudo systemctl reload nginx
```

Smoke test with `curl -I https://cli.example.com/health` — expect 502 (server up, tunnel not yet up).

## 4. Mac side

```bash
brew install frpc
mkdir -p ~/.config/frpc
install -m 600 deploy/frpc.toml ~/.config/frpc/frpc.toml
# … edit ~/.config/frpc/frpc.toml: paste the auth.token …

# Run once foreground to verify
frpc -c ~/.config/frpc/frpc.toml
# Expect: "[I] [client/control.go] login to server success"  — Ctrl-C.

# Install launchd unit so it autostarts at login
install -m 644 deploy/launchd/com.user.frpc.plist ~/Library/LaunchAgents/com.user.frpc.plist
# … edit the plist: replace REPLACE_USER with your username, frpc binary path …
launchctl load ~/Library/LaunchAgents/com.user.frpc.plist

# Start the app:
npm run build && JWT_SECRET="$(openssl rand -hex 32)" npm run server
```

(Put `JWT_SECRET` in a launchd plist or `~/.zshrc` so the value is stable across restarts — TOTP secrets are encrypted under it, and rotating it locks all existing users out.)

## 5. Verify

```bash
# From any device with internet:
curl -I https://cli.example.com/health
# Expect: HTTP/2 200
```

Open `https://cli.example.com/` in a phone browser, log in, complete TOTP setup.

## 6. Recovery

If you lose your authenticator and recovery code:

```bash
# On the Mac:
cd ~/CODE/claudecodeui-local
npm run reset-totp -- <username>
# Log in once with password only; you'll be prompted to set up TOTP again.
```

## 7. Tear-down

```bash
# Stop the tunnel:
launchctl unload ~/Library/LaunchAgents/com.user.frpc.plist
# Stop the server:
sudo systemctl stop frps
```

When `frpc` is not running, `https://cli.example.com/` returns 502. When `frps` is not running, nothing publicly observable changes except phone-side 502s; the security group on 7000 stays as-is.
````

- [ ] **Step 2: Commit**

```bash
git add deploy/README.md
git commit -m "docs(deploy): step-by-step install guide"
```

---

## Phase 6 — End-to-end validation

These tasks have no code; they confirm the system works. Mark each off as it passes.

### Task 6.1: Local smoke

- [ ] **Step 1: Build and run**

```bash
cd ~/CODE/claudecodeui-local
JWT_SECRET="dev-secret" npm run build
JWT_SECRET="dev-secret" npm run server &
sleep 4
curl -fsS http://127.0.0.1:3001/health
kill %1
```

Expected: `/health` returns JSON with `status: "ok"`.

- [ ] **Step 2: Manual UI walk-through**

```bash
JWT_SECRET="dev-secret" npm run dev
```

Then in a browser at `http://localhost:5173`:

  1. Create the initial user via the setup flow.
  2. Confirm the TOTP setup screen appears, scan with phone, save the recovery code, enter the 6-digit code.
  3. Logout, log in again — confirm two-step login.
  4. In a separate terminal, run `claude` inside `~/some-project`. Within ~5 s the session ID appears under "Running" in the sidebar with a green dot.
  5. Quit the `claude` process. Within `RECENT_SESSION_WINDOW_MIN` minutes (default 30) it appears under "Recent" with a gray dot.
  6. Attach a shell to a running session; confirm bidirectional streaming works.

### Task 6.2: External smoke (after Phase 5 deployment)

- [ ] **Step 1: Verify the tunnel**

```bash
curl -I https://cli.<your-domain>/health
```

Expected: HTTP 200, even when on cellular data away from the LAN.

- [ ] **Step 2: Phone walk-through**

  1. Open `https://cli.<your-domain>/` on the phone.
  2. Log in (password + TOTP).
  3. Confirm the sidebar shows the same running/recent sessions as locally.
  4. Attach a shell, type a prompt, observe streaming output.

- [ ] **Step 3: Failure mode check**

```bash
# On Mac, stop frpc:
launchctl unload ~/Library/LaunchAgents/com.user.frpc.plist
# Phone reload should now show a 502 within a couple of seconds.
launchctl load ~/Library/LaunchAgents/com.user.frpc.plist
# Phone reload recovers within ~10s.
```

---

## Self-review

After writing this plan, I checked:

1. **Spec coverage** — every section of the spec (1 goal, 2 scope, 3 architecture, 4.1–4.5 code changes, 5 deploy, 6 security, 7 open params, 8 non-goals, 9 validation) maps to at least one task. Open parameters (subdomain, frps token) live in the deploy README's "before you start" section. Non-goals do not appear as tasks (correct).
2. **Placeholders** — no "TBD"/"figure out later" content. Every code block contains the actual code. Subdomain placeholder is intentional and documented in deploy README, not in code.
3. **Type/name consistency** — `runningSessionsService.list`, `recentSessionsService.list`, `userDb.setTotp/clearTotp/getTotpStatus`, `totpService.{generateSecret,sealSecret,unsealSecret,verifyCode,provisioningUri}`, `createSessionsRouter` — all referenced consistently across phases.
4. **Ambiguity** — for two cases where the upstream layout is not 100% predictable from the spec (`userDb` file location and `authFetch` helper name), the plan tells the engineer how to discover the right name via `git grep` rather than asserting one. That is intentional.
