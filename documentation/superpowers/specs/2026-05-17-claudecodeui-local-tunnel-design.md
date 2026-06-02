# claudecodeui-local — Design Spec

Date: 2026-05-17
Source template: `~/Downloads/TEMP/claudecodeui-main` (read-only, copy from)
Target repo: `~/CODE/claudecodeui-local`

## 1. Goal

A stripped-down, Claude-Code-only fork of claudecodeui that:

1. Lists only **currently active** Claude CLI sessions (with a separate "recent" affordance for sessions touched in the last 30 minutes).
2. Removes all non-Claude provider integrations (Cursor / Codex / Gemini).
3. Can be reached from the user's phone over public HTTPS via the existing Tencent Cloud server (<SERVER_IP>), without exposing the user's Mac to the public internet, protected by password + TOTP.

## 2. Scope

**In scope**

- Remove Cursor / Codex / Gemini code paths (server + UI + i18n + deps).
- Filter session list: only running-or-recent.
- Add TOTP 2FA to existing bcrypt+JWT login.
- Deploy FRP (`frpc` on Mac, `frps` on server) + nginx reverse-proxy + SSL termination.
- Document deployment.

**Out of scope**

- Adding new model providers, new auth backends (SSO, OAuth).
- Building a mobile-native app.
- Multi-user / team features.
- Cluster/HA on the server.
- Migrating the existing data from any prior install — fresh `auth.db`.

## 3. Architecture

### 3.1 Network path (phone → Mac)

```
┌──────┐  wss://cli.<domain>/  ┌──────────────────────┐
│Phone │ ──────────────────────► nginx :443 (TLS)     │  Tencent Cloud
└──────┘                       │       │              │  <SERVER_IP>
                               │       ▼ proxy_pass   │
                               │  frps :7080 (loop)   │
                               │       ▲              │
                               │       │ ctrl :7000   │
                               └───────┼──────────────┘
                                       │ persistent outbound (TCP/TLS)
                               ┌───────┼──────────────┐
                               │       ▼              │
                               │  frpc on Mac         │
                               │       │              │
                               │       ▼ 127.0.0.1    │
                               │  claudecodeui :3001  │
                               └──────────────────────┘
                                  Mac (NAT, no public IP)
```

- TLS terminates at nginx; nginx supports `Upgrade: websocket`.
- `frps` listens on `:7000` (control) and exposes the tunneled service on a localhost-only loopback port (default `:7080`).
- `frpc` on Mac dials out → registers the tunnel `local:127.0.0.1:3001 → server:7080`.
- frps↔frpc gets `tls_enable = true` for an additional encryption layer beyond nginx.
- Mac initiates all connections. Zero inbound ports needed on the LAN.

### 3.2 Subdomain & nginx

A new subdomain (e.g. `cli.<existing-domain>`) is provisioned on the server's nginx with the existing Let's Encrypt setup. The vhost `proxy_pass`es to `http://127.0.0.1:7080`, with `Upgrade`/`Connection` headers and `proxy_read_timeout` raised for long-running WS streams (≥3600s).

The exact subdomain is a deployment parameter, picked at install time.

## 4. Code changes

### 4.1 Files removed wholesale

- `server/cursor-cli.js`
- `server/gemini-cli.js`
- `server/gemini-response-handler.js`
- `server/openai-codex.js`
- `server/sessionManager.js`  *(Gemini-only in-memory store, dead with Gemini)*
- `server/routes/cursor.js`
- `server/routes/gemini.js`
- `server/modules/providers/list/cursor/`
- `server/modules/providers/list/codex/`
- `server/modules/providers/list/gemini/`
- Any provider-tab/selector UI in `src/components/sidebar/` / `src/components/main-content/` that lets the user pick provider.

**Files trimmed (not removed)**

- `src/components/provider-auth/` — handles per-provider API-key entry. Keep only the Claude branch (Anthropic API key / `claude login` CLI delegation). Remove Cursor/Codex/Gemini branches. Note: `src/components/auth/` is the *user* login UI (password + TOTP) and is unrelated — both directories exist independently.
- i18n keys under `cursor.*`, `codex.*`, `gemini.*` across `src/i18n/locales/`.

### 4.2 Files edited

- `server/modules/providers/provider.registry.ts` — keep only `claude`.
- `server/index.js` — drop Cursor/Gemini route imports + `app.use`.
- `package.json` — drop `@openai/codex-sdk` and any provider-specific deps.
- `src/components/sidebar` / `src/components/main-content` — remove provider switcher UI.
- `shared/types.ts` (`LLMProvider`) — narrow to `'claude'` only.

### 4.3 Session filter — "running + recent"

Two signals, displayed as separate UI affordances (e.g. badge "● running" vs subdued "recent"):

1. **Running** — driven by `claude-sdk.js`'s `activeSessions: Map<sessionId, …>`. A new `GET /api/sessions/active` endpoint returns the keys. The sidebar renders these with the live badge.
2. **Recent** — derived from JSONL `mtime` in `~/.claude/projects/<encoded>/*.jsonl`. Threshold default 30 minutes (configurable via env `RECENT_SESSION_WINDOW_MIN`).

The default sidebar view shows the union; legacy "all history" navigation is removed (no toggle, no archive view — keeps UI minimal).

### 4.4 TOTP 2FA

**Schema** — extend `users` table:
- `totp_secret TEXT` (base32, encrypted at rest with `JWT_SECRET`-derived key via `crypto.createCipheriv('aes-256-gcm', …)`).
- `totp_enabled INTEGER DEFAULT 0`.

**Setup flow** — first login after migration:
- `POST /api/auth/totp/setup` returns provisioning URI + QR (server uses `otplib`).
- User scans (Google Authenticator / 1Password / Authy).
- `POST /api/auth/totp/verify-setup` with first code → flips `totp_enabled = 1`, stores secret.

**Login flow**:
- `POST /api/auth/login` with password → if `totp_enabled`, response is `{ requiresTotp: true, totpToken: <short-lived> }` (5 min, signed JWT with `purpose: 'totp_pending'`).
- `POST /api/auth/login/totp` with `{ totpToken, code }` → final JWT.
- TOTP failure: 5 attempts / 15 min lockout per user (in-memory counter, fine for single-user).

**Recovery** — single one-time recovery code generated at setup, shown once, hashed in DB (bcrypt). Used like a TOTP code at login. Plus a server-side script `scripts/reset-totp.js` (`npm run reset-totp -- <username>`) that clears `totp_secret`/`totp_enabled` for emergencies (requires shell access to the Mac, by design).

### 4.5 Listening surface

Bind the Express server to `127.0.0.1:3001` only (not `0.0.0.0`). The tunnel reaches it via loopback; nothing on the Mac's LAN can connect directly. Make this the default in `server/index.js`; override via `HOST=0.0.0.0` env for dev.

## 5. Deployment artifacts (new)

Under `deploy/`:

- `deploy/frpc.toml` — Mac client template.
- `deploy/frps.toml` — server template.
- `deploy/nginx-cli.conf` — vhost snippet.
- `deploy/launchd/com.user.frpc.plist` — macOS launchd unit so `frpc` autostarts on login.
- `deploy/systemd/frps.service` — server unit.
- `deploy/README.md` — step-by-step install: brew install frpc, scp frps to server, nginx site enablement, certbot, smoke test.

**Secrets handled in deploy README, not committed**:
- FRP `auth.token` (shared between frps & frpc) → 32-byte random in `frpc.toml` / `frps.toml`.
- TOTP secrets stored encrypted in `auth.db`.
- nginx uses the existing Let's Encrypt cert.

## 6. Security model

| Layer | Mechanism | What it stops |
|---|---|---|
| Network | Mac is NAT-only; only outbound `frpc` | Direct attack on Mac |
| Edge | nginx 443 with Let's Encrypt | Plaintext eavesdrop |
| Edge → frps | `proxy_pass` to `127.0.0.1:7080` (loopback bind) | Direct frps abuse from public |
| frps ↔ frpc | `tls_enable = true` + shared `auth.token` | Random clients impersonating frpc |
| App | bcrypt password + TOTP | Credential stuffing, leaked-password reuse |
| App | Rate-limited login (existing) + TOTP lockout (new) | Brute force |
| App | Single user, no signup endpoint exposed publicly | Account creation abuse |

**Threat-model gap**: a CSRF on a logged-in browser session could still drive the API. Mitigation: existing JWT-in-Authorization-header pattern means cookies aren't auto-attached, so CSRF is structurally hard. Keep it that way — do not move tokens to cookies.

## 7. Open parameters (decided at install)

- Subdomain — picked at deploy time.
- `frps` `bind_port` — default `7000`, change if conflict.
- `frps` proxied port — default `7080`, must match nginx vhost.
- `RECENT_SESSION_WINDOW_MIN` — default 30.

## 8. Explicit non-goals

- No "history view" / archive list — `running + recent` is the whole UI.
- No mobile-native app.
- No multi-tenant.
- No data migration from prior installs of claudecodeui — starts with fresh `auth.db`.
- No reintroducing other providers via plugin system.

## 9. Validation

- `npm run typecheck` clean after type narrowing.
- `npm run dev` boots Express on 127.0.0.1:3001, Vite on 5173; sidebar shows running + recent for at least one live Claude session.
- TOTP setup → logout → login flow round-trips end-to-end in a real browser (not just curl).
- From an external phone over LTE: hitting the public subdomain serves the login page, after auth a Shell session attaches to a running Claude process and streams output bidirectionally.
- `frpc stop` on Mac → public URL returns 502 within seconds (proves dependency).
