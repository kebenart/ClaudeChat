import assert from 'node:assert/strict';
import test from 'node:test';

import Database from 'better-sqlite3';

import { runMigrations } from '@/modules/database/migrations.js';
import { INIT_SCHEMA_SQL } from '@/modules/database/schema.js';

test('runMigrations creates IM tables with expected columns', () => {
  const db = new Database(':memory:');
  db.exec(INIT_SCHEMA_SQL);
  runMigrations(db);

  const tables = db
    .prepare("SELECT name FROM sqlite_master WHERE type='table'")
    .all()
    .map((r: any) => r.name);
  assert.ok(tables.includes('im_conversations'));
  assert.ok(tables.includes('im_messages'));
  assert.ok(tables.includes('im_read_cursors'));

  const msgCols = (db.prepare('PRAGMA table_info(im_messages)').all() as any[]).map((c) => c.name);
  for (const col of ['pk', 'conversation_id', 'source_id', 'seq', 'role', 'kind', 'content', 'tool_trace_count', 'raw_ref_start', 'raw_ref_end', 'created_at']) {
    assert.ok(msgCols.includes(col), `missing column ${col}`);
  }
  db.close();
});
