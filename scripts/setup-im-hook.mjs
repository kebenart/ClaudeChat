#!/usr/bin/env node
/**
 * setup-im-hook.mjs — one-shot installer for the IM terminal hook (+ usage proxy).
 *
 * Automates the manual steps from documentation/使用指南.md §8/§9 (and deploy/README.md
 * §6/§7):
 *   1. generate or reuse a shared IM_HOOK_TOKEN,
 *   2. set IM_HOOK_TOKEN (and optionally CLAUDE_USAGE_PROXY) in the launchd
 *      plist's EnvironmentVariables,
 *   3. register the UserPromptSubmit + Stop hooks in ~/.claude/settings.json
 *      (merging — never clobbering other hooks; de-duped on re-run),
 *   4. reload the launchd job so the new env is live.
 *
 * Idempotent: re-running reuses the existing token and replaces (not appends)
 * the IM hook entries. The original settings.json is backed up first.
 *
 * Usage:
 *   node scripts/setup-im-hook.mjs                 # hook only
 *   node scripts/setup-im-hook.mjs --proxy         # + CLAUDE_USAGE_PROXY=http://127.0.0.1:7890
 *   node scripts/setup-im-hook.mjs --proxy=http://127.0.0.1:1080
 *   node scripts/setup-im-hook.mjs --no-reload     # skip launchctl bootout/bootstrap
 */

import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, '..');
const HOOK_SCRIPT = path.join(REPO_ROOT, 'scripts', 'im-claude-hook.mjs');
const CHOICE_HOOK_SCRIPT = path.join(REPO_ROOT, 'scripts', 'im-claude-choice-hook.mjs');

const HOME = os.homedir();
const PLIST = path.join(HOME, 'Library', 'LaunchAgents', 'com.user.claudecodeui-local.plist');
const SETTINGS = path.join(HOME, '.claude', 'settings.json');
const LABEL = 'com.user.claudecodeui-local';
const PLIST_BUDDY = '/usr/libexec/PlistBuddy';
const DEFAULT_PROXY = 'http://127.0.0.1:7890';

// --- args ----------------------------------------------------------------
const args = process.argv.slice(2);
const noReload = args.includes('--no-reload');
const proxyArg = args.find((a) => a === '--proxy' || a.startsWith('--proxy='));
const usageProxy = proxyArg ? (proxyArg.includes('=') ? proxyArg.split('=')[1] : DEFAULT_PROXY) : null;

function die(msg) {
  console.error(`\n✗ ${msg}`);
  process.exit(1);
}
function ok(msg) {
  console.log(`✓ ${msg}`);
}

// --- preflight -----------------------------------------------------------
if (!fs.existsSync(HOOK_SCRIPT)) die(`hook script not found: ${HOOK_SCRIPT}`);
if (!fs.existsSync(PLIST)) {
  die(
    `launchd plist not found: ${PLIST}\n` +
      `  Install/start the app via launchd first (see documentation/使用指南.md §1.4), then re-run.`,
  );
}
if (!fs.existsSync(SETTINGS)) die(`~/.claude/settings.json not found: ${SETTINGS}`);

// --- 1 + 2. token + plist env -------------------------------------------
function plistPrint(keyPath) {
  try {
    return execFileSync(PLIST_BUDDY, ['-c', `Print :${keyPath}`, PLIST], { encoding: 'utf8' }).trim();
  } catch {
    return null;
  }
}
function plistSet(keyPath, type, value) {
  try {
    execFileSync(PLIST_BUDDY, ['-c', `Set :${keyPath} ${value}`, PLIST]);
  } catch {
    execFileSync(PLIST_BUDDY, ['-c', `Add :${keyPath} ${type} ${value}`, PLIST]);
  }
}

// Ensure the EnvironmentVariables dict exists (Add is a harmless no-op if it does).
try {
  execFileSync(PLIST_BUDDY, ['-c', 'Add :EnvironmentVariables dict', PLIST], { stdio: 'ignore' });
} catch {
  /* already present */
}

let token = plistPrint('EnvironmentVariables:IM_HOOK_TOKEN');
if (token && token.length > 0) {
  ok(`reusing existing IM_HOOK_TOKEN from plist`);
} else {
  token = randomBytes(24).toString('hex');
  ok(`generated a new IM_HOOK_TOKEN`);
}
plistSet('EnvironmentVariables:IM_HOOK_TOKEN', 'string', token);
ok(`plist: IM_HOOK_TOKEN set`);

if (usageProxy) {
  plistSet('EnvironmentVariables:CLAUDE_USAGE_PROXY', 'string', usageProxy);
  ok(`plist: CLAUDE_USAGE_PROXY=${usageProxy} set`);
}

// --- 3. register hooks in settings.json ----------------------------------
const raw = fs.readFileSync(SETTINGS, 'utf8');
let settings;
try {
  settings = JSON.parse(raw);
} catch (e) {
  die(`~/.claude/settings.json is not valid JSON: ${e.message}`);
}

const backup = `${SETTINGS}.bak-${Date.now()}`;
fs.writeFileSync(backup, raw);
ok(`backed up settings.json → ${path.basename(backup)}`);

const command = `IM_HOOK_TOKEN=${token} node ${HOOK_SCRIPT}`;
const ingestEntry = { hooks: [{ type: 'command', command }] };
settings.hooks = settings.hooks || {};

// Ingest hooks: the turn-boundary user/assistant recorders.
for (const event of ['UserPromptSubmit', 'Stop']) {
  const existing = Array.isArray(settings.hooks[event]) ? settings.hooks[event] : [];
  // Drop any prior IM-hook registration (de-dupe on re-run); keep unrelated hooks.
  const kept = existing.filter(
    (e) => !(e?.hooks ?? []).some((h) => typeof h?.command === 'string' && h.command.includes('im-claude-hook.mjs')),
  );
  kept.push(ingestEntry);
  settings.hooks[event] = kept;
}

// Choice hook: a blocking PreToolUse bridge for AskUserQuestion / ExitPlanMode so
// terminal sessions can be answered from any IM device. Long timeout so a slow
// phone answer isn't cut off. Preserve any OTHER PreToolUse hooks (e.g. rtk).
const choiceEntry = {
  matcher: 'AskUserQuestion|ExitPlanMode',
  hooks: [{ type: 'command', command: `IM_HOOK_TOKEN=${token} node ${CHOICE_HOOK_SCRIPT}`, timeout: 600 }],
};
const pre = Array.isArray(settings.hooks.PreToolUse) ? settings.hooks.PreToolUse : [];
const keptPre = pre.filter(
  (e) => !(e?.hooks ?? []).some((h) => typeof h?.command === 'string' && h.command.includes('im-claude-choice-hook.mjs')),
);
keptPre.push(choiceEntry);
settings.hooks.PreToolUse = keptPre;

fs.writeFileSync(SETTINGS, `${JSON.stringify(settings, null, 2)}\n`);
ok(`settings.json: registered UserPromptSubmit + Stop + PreToolUse(choice) hooks`);

// --- 4. reload launchd ---------------------------------------------------
if (noReload) {
  console.log('• skipped launchd reload (--no-reload) — reload manually to pick up plist env');
} else {
  const domain = `gui/${process.getuid()}`;
  try {
    execFileSync('launchctl', ['bootout', `${domain}/${LABEL}`], { stdio: 'ignore' });
  } catch {
    /* not loaded — fine */
  }
  try {
    execFileSync('launchctl', ['bootstrap', domain, PLIST], { stdio: 'ignore' });
    ok(`launchd: reloaded ${LABEL}`);
  } catch (e) {
    console.log(`• launchd reload failed (${e.message}) — reload manually:`);
    console.log(`    launchctl bootout ${domain}/${LABEL}`);
    console.log(`    launchctl bootstrap ${domain} ${PLIST}`);
  }
}

// --- summary -------------------------------------------------------------
console.log('\n— Done —');
console.log('Terminal Claude sessions now flow into the IM hub. Verify:');
console.log('  open a NEW terminal, run `claude`, send a message → it appears in the IM app.');
if (!usageProxy) {
  console.log('Tip: behind a CN geo-block? add the usage proxy with `--proxy` (Clash on :7890).');
}
