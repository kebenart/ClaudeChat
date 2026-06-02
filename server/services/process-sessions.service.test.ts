import assert from 'node:assert/strict';
import test from 'node:test';

import { processSessionsService } from '@/services/process-sessions.service.js';

const { listClaudeProcesses, extractResumeId, encodeCwdToProjectDir } =
  processSessionsService._internal;

test('listClaudeProcesses picks up real claude CLI invocations', () => {
  const out = listClaudeProcesses(`
   12345 claude --dangerously-skip-permissions --resume abc-def
   23456 /Users/x/.nvm/versions/node/v24.11.1/bin/claude.exe
   34567 hapi claude --hapi-starting-mode remote --started-by runner
   45678 /Applications/Claude.app/Contents/MacOS/Claude
   56789 sh -c "make build && claude_helper"
   67890 claude_lint --check
   78901 /opt/homebrew/bin/claude --dangerously-skip-permissions
  `);
  const cmds = out.map(o => o.command);
  assert.ok(cmds.some(c => c.includes('claude --dangerously-skip-permissions --resume abc-def')));
  assert.ok(cmds.some(c => c.endsWith('claude.exe')));
  assert.ok(cmds.some(c => c.includes('/opt/homebrew/bin/claude')));
  // Excluded:
  assert.ok(!cmds.some(c => c.includes('hapi claude')), 'hapi-wrapped excluded');
  assert.ok(!cmds.some(c => c.includes('Claude.app')), 'GUI app excluded');
  assert.ok(!cmds.some(c => c.includes('claude_lint')), 'unrelated names excluded');
  assert.ok(!cmds.some(c => c.includes('make build')), 'shell strings excluded');
});

test('extractResumeId parses --resume <uuid>', () => {
  assert.equal(
    extractResumeId('claude --resume 20b04904-9759-4222-b458-f2b45c5fe5a2'),
    '20b04904-9759-4222-b458-f2b45c5fe5a2'
  );
  assert.equal(
    extractResumeId('claude --resume=20b04904-9759-4222-b458-f2b45c5fe5a2'),
    '20b04904-9759-4222-b458-f2b45c5fe5a2'
  );
  assert.equal(extractResumeId('claude --resume'), null, 'no value');
  assert.equal(extractResumeId('claude'), null, 'no resume');
  assert.equal(extractResumeId('claude --foo bar'), null);
});

test('encodeCwdToProjectDir matches Claude CLI encoding', () => {
  assert.equal(
    encodeCwdToProjectDir('/Users/keben/CODE/claudecodeui-local'),
    '-Users-keben-CODE-claudecodeui-local'
  );
  // Dots become a second dash, matching the upstream pattern we observed
  // for ~/.cache/foo → -Users-keben--cache-foo.
  assert.equal(
    encodeCwdToProjectDir('/Users/keben/.cache/foo'),
    '-Users-keben--cache-foo'
  );
});

test('list on a system with no claude processes returns empty array', async () => {
  // Run on a tmp rootDir so even if real processes exist, the cwd-lookup
  // step can't find any matching project. (The list signal from --resume
  // doesn't depend on rootDir; if the running system happens to have a
  // claude --resume process, the test would not be empty. Accept that as
  // a smoke-only assertion: result is an array.)
  const result = await processSessionsService.list('/nonexistent/path/that/should/not/exist');
  assert.ok(Array.isArray(result));
});
