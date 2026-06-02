import { test } from 'node:test';
import assert from 'node:assert/strict';

import { distillJsonl, type RawJsonlEntry } from '@/services/im-distill.service.js';

test('keeps user text and assistant final result, drops tools/thinking', () => {
  const entries: RawJsonlEntry[] = [
    { type: 'user', uuid: 'u1', timestamp: '2026-05-29T00:00:00.000Z', message: { role: 'user', content: '帮我重构 a.ts' } },
    { type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'assistant', content: [{ type: 'thinking', thinking: '...' }, { type: 'tool_use', id: 't1', name: 'Edit' }] } },
    { type: 'user', uuid: 'tr1', timestamp: '2026-05-29T00:00:02.000Z', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'ok' }] } },
    { type: 'assistant', uuid: 'a2', timestamp: '2026-05-29T00:00:03.000Z', message: { role: 'assistant', content: [{ type: 'text', text: '重构完成。' }] } },
  ];

  const out = distillJsonl(entries);

  assert.equal(out.length, 2);
  assert.equal(out[0].role, 'user');
  assert.equal(out[0].kind, 'text');
  assert.equal(out[0].content, '帮我重构 a.ts');

  assert.equal(out[1].role, 'assistant');
  assert.equal(out[1].kind, 'result');
  assert.equal(out[1].content, '重构完成。');
  assert.deepEqual(out[1].toolTrace, { count: 1, rawRefStart: 'a1', rawRefEnd: 'tr1' });
  // Result is keyed on the turn's FIRST assistant entry (stable as the turn streams).
  assert.equal(out[1].sourceId, 'a1');
});

test('drops harness-injected synthetic user turns (no phantom bubbles) but keeps them as turn boundaries', () => {
  const entries: RawJsonlEntry[] = [
    { type: 'user', uuid: 'u1', timestamp: '2026-05-29T00:00:00.000Z', message: { role: 'user', content: '真实问题' } },
    { type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'assistant', content: [{ type: 'text', text: '回答一。' }] } },
    // harness noise — must NOT appear as user bubbles
    { type: 'user', uuid: 'n1', timestamp: '2026-05-29T00:00:02.000Z', message: { role: 'user', content: '[Request interrupted by user]' } },
    { type: 'user', uuid: 'n2', timestamp: '2026-05-29T00:00:03.000Z', message: { role: 'user', content: '<command-name>/compact</command-name>' } },
    { type: 'user', uuid: 'n3', timestamp: '2026-05-29T00:00:04.000Z', message: { role: 'user', content: 'Continue from where you left off.' } },
    { type: 'user', uuid: 'n4', timestamp: '2026-05-29T00:00:05.000Z', message: { role: 'user', content: 'Base directory for this skill: /Users/x/.claude/skills/foo\n\n# Foo' } },
    { type: 'assistant', uuid: 'a2', timestamp: '2026-05-29T00:00:06.000Z', message: { role: 'assistant', content: [{ type: 'text', text: '回答二。' }] } },
    { type: 'user', uuid: 'u2', timestamp: '2026-05-29T00:00:07.000Z', message: { role: 'user', content: '第二个真实问题' } },
  ];

  const out = distillJsonl(entries);
  const users = out.filter((m) => m.role === 'user').map((m) => m.content);
  const assistants = out.filter((m) => m.role === 'assistant').map((m) => m.content);

  // Only the two genuine human messages survive — no phantom bubbles.
  assert.deepEqual(users, ['真实问题', '第二个真实问题']);
  // Both assistant turns flushed separately (synthetic turns still acted as boundaries).
  assert.deepEqual(assistants, ['回答一。', '回答二。']);
});

test('a growing turn keeps the same sourceId across re-distillation (streaming stability)', () => {
  const turnStart: RawJsonlEntry[] = [
    { type: 'user', uuid: 'u1', timestamp: '2026-05-29T00:00:00.000Z', message: { role: 'user', content: 'q' } },
    { type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'Part one.' }] } },
  ];
  const turnGrown: RawJsonlEntry[] = [
    ...turnStart,
    { type: 'assistant', uuid: 'a2', timestamp: '2026-05-29T00:00:02.000Z', message: { role: 'assistant', content: [{ type: 'text', text: ' Part two.' }] } },
  ];

  const first = distillJsonl(turnStart);
  const second = distillJsonl(turnGrown);
  assert.equal(first[1].sourceId, second[1].sourceId); // stable id across growth
  assert.equal(first[1].content, 'Part one.');
  assert.equal(second[1].content, 'Part one. Part two.');
});

test('error entry becomes an error message', () => {
  const entries: RawJsonlEntry[] = [
    { type: 'assistant', uuid: 'e1', timestamp: '2026-05-29T00:00:00.000Z', isError: true, message: { role: 'assistant', content: [{ type: 'text', text: 'API error 500' }] } },
  ];
  const out = distillJsonl(entries);
  assert.equal(out.length, 1);
  assert.equal(out[0].kind, 'error');
  assert.equal(out[0].content, 'API error 500');
});

test('returns empty array for empty input', () => {
  assert.deepEqual(distillJsonl([]), []);
});

test('emits each of multiple consecutive user messages as text', () => {
  const out = distillJsonl([
    { type: 'user', uuid: 'u1', timestamp: '2026-05-29T00:00:00.000Z', message: { role: 'user', content: 'first' } },
    { type: 'user', uuid: 'u2', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'user', content: 'second' } },
  ]);
  assert.equal(out.length, 2);
  assert.deepEqual(out.map((m) => m.content), ['first', 'second']);
  assert.ok(out.every((m) => m.role === 'user' && m.kind === 'text'));
});

test('tools-only turn (no final text) still emits a result with empty content and toolTrace', () => {
  const out = distillJsonl([
    { type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:00.000Z', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't1', name: 'Bash' }] } },
    { type: 'user', uuid: 'tr1', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'done' }] } },
  ]);
  assert.equal(out.length, 1);
  assert.equal(out[0].kind, 'result');
  assert.equal(out[0].content, '');
  assert.deepEqual(out[0].toolTrace, { count: 1, rawRefStart: 'a1', rawRefEnd: 'tr1' });
});
