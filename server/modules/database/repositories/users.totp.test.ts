import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { closeConnection } from '@/modules/database/connection.js';
import { initializeDatabase } from '@/modules/database/init-db.js';
import { userDb } from '@/modules/database/repositories/users.js';

async function withIsolatedDatabase(runTest: () => void | Promise<void>): Promise<void> {
  const previousDatabasePath = process.env.DATABASE_PATH;
  const tempDirectory = await mkdtemp(path.join(tmpdir(), 'users-totp-db-'));
  const databasePath = path.join(tempDirectory, 'auth.db');

  closeConnection();
  process.env.DATABASE_PATH = databasePath;
  await initializeDatabase();

  try {
    await runTest();
  } finally {
    closeConnection();
    if (previousDatabasePath === undefined) {
      delete process.env.DATABASE_PATH;
    } else {
      process.env.DATABASE_PATH = previousDatabasePath;
    }
    await rm(tempDirectory, { recursive: true, force: true });
  }
}

test('setTotp stores sealed secret and recovery hash, getTotpStatus returns enabled=true', async () => {
  await withIsolatedDatabase(() => {
    const user = userDb.createUser('testuser', 'hash');
    const userId = Number(user.id);

    // Before TOTP is set
    const before = userDb.getTotpStatus(userId);
    assert.equal(before.enabled, false);
    assert.equal(before.secret, null);
    assert.equal(before.recoveryHash, null);

    // Set TOTP
    userDb.setTotp(userId, 'sealed-secret-base64', 'bcrypt-hash-of-recovery');

    const after = userDb.getTotpStatus(userId);
    assert.equal(after.enabled, true);
    assert.equal(after.secret, 'sealed-secret-base64');
    assert.equal(after.recoveryHash, 'bcrypt-hash-of-recovery');
  });
});

test('clearTotp resets all TOTP fields and sets enabled=false', async () => {
  await withIsolatedDatabase(() => {
    const user = userDb.createUser('testuser2', 'hash');
    const userId = Number(user.id);

    userDb.setTotp(userId, 'some-sealed-secret', 'some-recovery-hash');
    assert.equal(userDb.getTotpStatus(userId).enabled, true);

    userDb.clearTotp(userId);

    const cleared = userDb.getTotpStatus(userId);
    assert.equal(cleared.enabled, false);
    assert.equal(cleared.secret, null);
    assert.equal(cleared.recoveryHash, null);
  });
});
