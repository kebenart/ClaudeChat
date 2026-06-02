#!/usr/bin/env tsx
/**
 * Reset TOTP for a user.
 * Usage: npm run reset-totp -- <username>
 */

// MUST come before any imports that touch the DB connection — load-env.js sets
// DATABASE_PATH (default ~/.cloudcli/auth.db). Without this the script falls
// back to the legacy server/database/auth.db, which is a different file from
// the one the running server uses.
import '../server/load-env.js';

import { initializeDatabase } from '../server/modules/database/init-db.js';
import { userDb } from '../server/modules/database/repositories/users.js';
import { getDatabasePath } from '../server/modules/database/connection.js';

await initializeDatabase();
console.log(`Using database: ${getDatabasePath()}`);

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
