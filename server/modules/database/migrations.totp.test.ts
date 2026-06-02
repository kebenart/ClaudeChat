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
  assert.ok(cols.includes('totp_secret'));
  assert.ok(cols.includes('totp_enabled'));
  assert.ok(cols.includes('recovery_hash'));
});

test('migration is idempotent on a db that already has the columns', () => {
  const db = new Database(':memory:');
  db.exec(INIT_SCHEMA_SQL);
  runMigrations(db);
  runMigrations(db); // run twice — must not throw
  const count = db.prepare("SELECT COUNT(*) AS n FROM pragma_table_info('users') WHERE name='totp_secret'").get() as { n: number };
  assert.equal(count.n, 1);
});
