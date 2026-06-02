# Deploying ClaudeChat

Two machines:
- **Mac (this checkout)** — runs the app on `127.0.0.1:3001`, runs `frpc` outbound.
- **Tencent Cloud server (<SERVER_IP>)** — runs `frps` on `:7000`, nginx terminates TLS for a chosen subdomain (`cli.<domain>`).

## 0. Pick a subdomain

Choose a hostname (e.g. `cli.example.com`). Point its DNS A record at `<SERVER_IP>`. Wait for propagation.

## 1. Generate a shared FRP token

```bash
openssl rand -hex 32
```

Paste the value into both `deploy/frpc.toml` and `deploy/frps.toml` (the `auth.token` field).

## 2. Server side

```bash
# Install frps (Debian/Ubuntu — adjust for your distro)
wget https://github.com/fatedier/frp/releases/latest/download/frp_*_linux_amd64.tar.gz
tar xf frp_*_linux_amd64.tar.gz
sudo install -m 755 frp_*_linux_amd64/frps /usr/local/bin/frps
sudo useradd -r -s /usr/sbin/nologin frp
sudo mkdir -p /etc/frp
sudo install -m 600 -o frp -g frp deploy/frps.toml /etc/frp/frps.toml
# Edit /etc/frp/frps.toml: paste auth.token, set webServer credentials.
sudo install -m 644 deploy/systemd/frps.service /etc/systemd/system/frps.service
sudo systemctl daemon-reload
sudo systemctl enable --now frps
sudo systemctl status frps --no-pager
```

Open **only** `7000/tcp` on the server firewall inbound from any source (the control channel). Do NOT open 7080 — it must stay loopback-only.

## 3. nginx vhost

```bash
sudo install -m 644 deploy/nginx-cli.conf /etc/nginx/conf.d/cli.conf
# Edit the file: replace cli.example.com placeholders.
sudo certbot --nginx -d cli.example.com   # if SSL certs don't already exist
sudo nginx -t && sudo systemctl reload nginx
```

Smoke test with `curl -I https://cli.example.com/health` — expect 502 (nginx OK, tunnel not yet up).

## 4. Mac side

```bash
brew install frpc

mkdir -p ~/.config/frpc
install -m 600 deploy/frpc.toml ~/.config/frpc/frpc.toml
# Edit ~/.config/frpc/frpc.toml: paste the same auth.token.

# Run once foreground to verify
frpc -c ~/.config/frpc/frpc.toml
# Expect: "[I] [client/control.go] login to server success" — Ctrl-C.

# Install launchd unit so it autostarts at login:
install -m 644 deploy/launchd/com.user.frpc.plist ~/Library/LaunchAgents/com.user.frpc.plist
# Edit the plist: replace REPLACE_USER with your username; confirm frpc binary path.
launchctl load ~/Library/LaunchAgents/com.user.frpc.plist

# One-time build:
npm run build
```

Put `JWT_SECRET` in `<REPO>/.env` (chmod 600) so it's stable across restarts. Rotating it invalidates all sealed TOTP secrets — every user has to set up TOTP again.

```bash
# .env content:
#   JWT_SECRET=<32+ random bytes hex>
```

### 4a. Autostart the app server via launchd

```bash
install -m 644 deploy/launchd/com.user.claudecodeui-local.plist \
  ~/Library/LaunchAgents/com.user.claudecodeui-local.plist
# Edit the plist: replace REPLACE_USER, REPLACE_NODE_PATH (output of `which node`
# with your nvm version active), and REPLACE_REPO_PATH (absolute path to this repo).
launchctl load -w ~/Library/LaunchAgents/com.user.claudecodeui-local.plist

# Verify
launchctl list | grep claudecodeui
curl -fsS http://127.0.0.1:3001/health
```

After editing source code, rebuild + restart:

```bash
cd <REPO> && npm run build
launchctl kickstart -k gui/$(id -u)/com.user.claudecodeui-local
```

Logs: `/tmp/cclocal.out.log` and `/tmp/cclocal.err.log`.

## 5. Verify

```bash
# From any device with internet:
curl -I https://cli.example.com/health
# Expect: HTTP/2 200
```

Open `https://cli.example.com/` on a phone browser. Log in (password → TOTP). On first login you'll be required to set up TOTP (scan QR, save the recovery code).

## 6. IM terminal hook (so terminal Claude sessions show up in the IM app)

IM messages are **hook-driven**, not file-watched. Sessions started from the IM
app are recorded by the server in-process. Sessions you start by running `claude`
**in a terminal** (or any external client) only reach the IM hub if you register
the in-repo hook in your global `~/.claude/settings.json`. The hook fires on
`UserPromptSubmit` (your prompt) and `Stop` (the finished reply) and POSTs each
turn to the server's loopback-only `/api/im-hook` endpoint.

**One-shot install (recommended)** — generates/reuses the token, writes the
plist env, merges the hooks into `settings.json`, reloads launchd (idempotent;
backs up `settings.json` first):

```bash
node scripts/setup-im-hook.mjs            # hook only
node scripts/setup-im-hook.mjs --proxy    # also set CLAUDE_USAGE_PROXY (see §7)
```

This registers three hooks: `UserPromptSubmit` + `Stop` (record terminal turns into the IM) and a `PreToolUse` **choice hook** (matcher `AskUserQuestion|ExitPlanMode`) — when a terminal session hits a question / plan confirmation, a 红包-style card pops on every IM client and you answer **from your phone**; the answer is returned to the terminal's Claude (it blocks up to 10 min). Other PreToolUse hooks (e.g. `rtk`) are preserved. App-session questions stay handled in-process by the server.

**Sending images.** With the hook installed, Claude can also push an image (e.g. a test screenshot) into the chat by running `node scripts/im-send-image.mjs <path> [caption]` — it validates + stores the file and broadcasts a `kind:'image'` bubble. To make Claude do this in *any* project (not just this repo), add that command to your global `~/.claude/CLAUDE.md`.

The manual equivalent (do this if you'd rather not run the script):

1. Generate a shared token (any random hex):

   ```bash
   node -e "console.log(require('crypto').randomBytes(24).toString('hex'))"
   ```

2. Put that token in the **server** env. In the app's launchd plist
   (`~/Library/LaunchAgents/com.user.claudecodeui-local.plist`), add to
   `EnvironmentVariables`:

   ```xml
   <key>IM_HOOK_TOKEN</key>
   <string>PASTE_THE_TOKEN</string>
   ```

   Reload the plist so the new env is picked up (a plist env change needs a full
   reload, **not** `kickstart -k`):

   ```bash
   launchctl bootout gui/$(id -u)/com.user.claudecodeui-local
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.claudecodeui-local.plist
   ```

3. Register the hook in `~/.claude/settings.json` (keep any existing hooks; pass
   the **same** token inline so the loopback endpoint is double-gated by
   loopback + token):

   ```jsonc
   "hooks": {
     "UserPromptSubmit": [
       { "hooks": [{ "type": "command",
         "command": "IM_HOOK_TOKEN=PASTE_THE_TOKEN node /ABSOLUTE/PATH/claudecodeui-local/scripts/im-claude-hook.mjs" }] }
     ],
     "Stop": [
       { "hooks": [{ "type": "command",
         "command": "IM_HOOK_TOKEN=PASTE_THE_TOKEN node /ABSOLUTE/PATH/claudecodeui-local/scripts/im-claude-hook.mjs" }] }
     ]
   }
   ```

The hook never blocks Claude (2s timeout, always exits 0). The token lives only
in the plist and `settings.json` — never commit it. Verify: open a **new**
terminal, run `claude`, send a message — it should appear in the IM app.

## 7. Claude usage limits (5h / 7-day) in 个人中心

The personal-center "用量" card reads your real Claude account limits from
`GET https://api.anthropic.com/api/oauth/usage` (OAuth token from
`~/.claude/.credentials.json` or the macOS Keychain). The server caches the
result for 30 minutes; a manual refresh (pull-to-refresh on iOS / the refresh
button on web & macOS) re-asks with `?force=1`, floored to one real upstream
call per 5 minutes.

In mainland China that endpoint is geo-blocked (direct → HTTP 403). Route
**only this call** through a proxy by adding to the launchd plist
`EnvironmentVariables` (reload as in §6.2):

```xml
<key>CLAUDE_USAGE_PROXY</key>
<string>http://127.0.0.1:7890</string>
```

Point it at your local proxy (e.g. Clash on `127.0.0.1:7890`). It's
usage-specific on purpose — the Claude SDK subprocess is **not** bound to the
proxy, so chats keep working even if the proxy is off. Omit the key entirely if
you're not behind a geo-block.

## 8. Recovery

If you lose your authenticator and recovery code:

```bash
# On the Mac:
cd ~/CODE/claudecodeui-local
npm run reset-totp -- <username>
# Log in with password only; you'll be prompted to set up TOTP again.
```

## 9. Tear-down

```bash
# Stop the tunnel:
launchctl unload ~/Library/LaunchAgents/com.user.frpc.plist
# Stop the tunnel server:
sudo systemctl stop frps
```

When `frpc` is not running, `https://cli.example.com/` returns 502. When `frps` is not running, nothing publicly observable changes except phone-side 502s; the security group on 7000 stays as-is.
