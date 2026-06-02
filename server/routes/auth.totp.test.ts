/**
 * Integration tests for TOTP auth flow covering Tasks 3.5, 3.6, and 3.7.
 *
 * Uses an isolated in-memory-backed temp DB per test suite to avoid
 * state leakage, following the pattern in sessions.db.integration.test.ts.
 */

import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import http from 'node:http';
import test from 'node:test';

import bcrypt from 'bcrypt';
import express from 'express';
import jwt from 'jsonwebtoken';
import { generateSync } from 'otplib';

// ---------------------------------------------------------------------------
// Must set env BEFORE importing modules that read JWT_SECRET at module load
// ---------------------------------------------------------------------------
process.env.JWT_SECRET = 'totp-test-jwt-secret-do-not-use-in-prod';

import { closeConnection } from '@/modules/database/connection.js';
import { initializeDatabase } from '@/modules/database/init-db.js';
import { userDb } from '@/modules/database/repositories/users.js';
import { totpService } from '@/services/totp.service.js';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function withIsolatedDatabase(runTest: (cleanup: () => Promise<void>) => Promise<void>): Promise<void> {
  const previousDatabasePath = process.env.DATABASE_PATH;
  const tempDirectory = await mkdtemp(path.join(tmpdir(), 'auth-totp-test-'));
  const databasePath = path.join(tempDirectory, 'auth.db');

  closeConnection();
  process.env.DATABASE_PATH = databasePath;
  await initializeDatabase();

  const cleanup = async () => {
    closeConnection();
    if (previousDatabasePath === undefined) {
      delete process.env.DATABASE_PATH;
    } else {
      process.env.DATABASE_PATH = previousDatabasePath;
    }
    await rm(tempDirectory, { recursive: true, force: true });
  };

  try {
    await runTest(cleanup);
  } catch (err) {
    await cleanup();
    throw err;
  }
}

/** Spin up the auth router in a temporary Express server. Returns base URL + teardown. */
async function withAuthServer(): Promise<{
  baseUrl: string;
  teardown: () => Promise<void>;
  tempDir: string;
  dbPath: string;
}> {
  const previousDatabasePath = process.env.DATABASE_PATH;
  const tempDirectory = await mkdtemp(path.join(tmpdir(), 'auth-totp-srv-'));
  const databasePath = path.join(tempDirectory, 'auth.db');

  closeConnection();
  process.env.DATABASE_PATH = databasePath;
  await initializeDatabase();

  // Dynamic import so the router picks up the freshly-initialised DB
  const { default: authRouter } = await import(`@/routes/auth.js?t=${Date.now()}`);
  const app = express();
  app.use(express.json());
  app.use('/auth', authRouter);

  const server = http.createServer(app);
  await new Promise<void>((resolve) => server.listen(0, resolve));
  const addr = server.address() as { port: number };
  const baseUrl = `http://127.0.0.1:${addr.port}`;

  const teardown = async () => {
    await new Promise<void>((resolve, reject) =>
      server.close((err) => (err ? reject(err) : resolve()))
    );
    closeConnection();
    if (previousDatabasePath === undefined) {
      delete process.env.DATABASE_PATH;
    } else {
      process.env.DATABASE_PATH = previousDatabasePath;
    }
    await rm(tempDirectory, { recursive: true, force: true });
  };

  return { baseUrl, teardown, tempDir: tempDirectory, dbPath: databasePath };
}

async function post(url: string, body: unknown): Promise<{ status: number; data: unknown }> {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const parsed = new URL(url);
    const req = http.request(
      {
        hostname: parsed.hostname,
        port: Number(parsed.port),
        path: parsed.pathname,
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
      },
      (res) => {
        let raw = '';
        res.on('data', (c) => { raw += c; });
        res.on('end', () => resolve({ status: res.statusCode ?? 0, data: JSON.parse(raw) }));
      }
    );
    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}

async function get(url: string, token: string): Promise<{ status: number; data: unknown }> {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const req = http.request(
      {
        hostname: parsed.hostname,
        port: Number(parsed.port),
        path: parsed.pathname,
        method: 'GET',
        headers: { Authorization: `Bearer ${token}` },
      },
      (res) => {
        let raw = '';
        res.on('data', (c) => { raw += c; });
        res.on('end', () => resolve({ status: res.statusCode ?? 0, data: JSON.parse(raw) }));
      }
    );
    req.on('error', reject);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Task 3.5 — /login TOTP branching
// ---------------------------------------------------------------------------

test('POST /login returns final JWT when TOTP is not enabled', async () => {
  const { baseUrl, teardown } = await withAuthServer();
  try {
    // Create user
    const passwordHash = await bcrypt.hash('password123', 10);
    const user = userDb.createUser('noTotp', passwordHash);
    assert.ok(user.id);

    const { status, data } = await post(`${baseUrl}/auth/login`, { username: 'noTotp', password: 'password123' });
    assert.equal(status, 200);
    assert.ok((data as { token: string }).token, 'should have token');
    assert.equal((data as { requiresTotp?: boolean }).requiresTotp, undefined);
  } finally {
    await teardown();
  }
});

test('POST /login returns requiresTotp + totpToken when TOTP is enabled', async () => {
  const { baseUrl, teardown } = await withAuthServer();
  try {
    const passwordHash = await bcrypt.hash('password123', 10);
    const user = userDb.createUser('withTotp', passwordHash);
    const userId = Number(user.id);

    // Enable TOTP
    const secret = totpService.generateSecret();
    const sealed = totpService.sealSecret(secret);
    userDb.setTotp(userId, sealed, 'dummy-hash');

    const { status, data } = await post(`${baseUrl}/auth/login`, { username: 'withTotp', password: 'password123' });
    assert.equal(status, 200);
    assert.equal((data as { requiresTotp: boolean }).requiresTotp, true);
    assert.ok((data as { totpToken: string }).totpToken, 'should have totpToken');
    assert.equal((data as { token?: string }).token, undefined, 'should not have final token yet');
  } finally {
    await teardown();
  }
});

// ---------------------------------------------------------------------------
// Task 3.6 — POST /login/totp
// ---------------------------------------------------------------------------

test('POST /login/totp with valid TOTP code returns final JWT', async () => {
  const { baseUrl, teardown } = await withAuthServer();
  try {
    const passwordHash = await bcrypt.hash('password123', 10);
    const user = userDb.createUser('validCode', passwordHash);
    const userId = Number(user.id);

    const secret = totpService.generateSecret();
    const sealed = totpService.sealSecret(secret);
    userDb.setTotp(userId, sealed, 'dummy-hash');

    // Get totpToken via /login
    const loginRes = await post(`${baseUrl}/auth/login`, { username: 'validCode', password: 'password123' });
    const { totpToken } = loginRes.data as { totpToken: string };

    const code = generateSync({ secret });
    const { status, data } = await post(`${baseUrl}/auth/login/totp`, { totpToken, code });
    assert.equal(status, 200);
    assert.ok((data as { token: string }).token, 'should have final token');
  } finally {
    await teardown();
  }
});

test('POST /login/totp with wrong TOTP code returns 401', async () => {
  const { baseUrl, teardown } = await withAuthServer();
  try {
    const passwordHash = await bcrypt.hash('password123', 10);
    const user = userDb.createUser('wrongCode', passwordHash);
    const userId = Number(user.id);

    const secret = totpService.generateSecret();
    const sealed = totpService.sealSecret(secret);
    userDb.setTotp(userId, sealed, 'dummy-hash');

    const loginRes = await post(`${baseUrl}/auth/login`, { username: 'wrongCode', password: 'password123' });
    const { totpToken } = loginRes.data as { totpToken: string };

    const { status } = await post(`${baseUrl}/auth/login/totp`, { totpToken, code: '000000' });
    assert.equal(status, 401);
  } finally {
    await teardown();
  }
});

test('POST /login/totp with valid recovery code returns 200 + newRecoveryCode', async () => {
  const { baseUrl, teardown } = await withAuthServer();
  try {
    const passwordHash = await bcrypt.hash('password123', 10);
    const user = userDb.createUser('recoveryUser', passwordHash);
    const userId = Number(user.id);

    const secret = totpService.generateSecret();
    const sealed = totpService.sealSecret(secret);
    const recoveryCode = 'my-recovery-code-12345';
    const recoveryHash = await bcrypt.hash(recoveryCode, 10);
    userDb.setTotp(userId, sealed, recoveryHash);

    const loginRes = await post(`${baseUrl}/auth/login`, { username: 'recoveryUser', password: 'password123' });
    const { totpToken } = loginRes.data as { totpToken: string };

    const { status, data } = await post(`${baseUrl}/auth/login/totp`, { totpToken, recoveryCode });
    assert.equal(status, 200);
    assert.ok((data as { token: string }).token, 'should have token');
    assert.ok((data as { newRecoveryCode: string }).newRecoveryCode, 'should have new recovery code');
    // The new recovery code should be different from the old one
    assert.notEqual((data as { newRecoveryCode: string }).newRecoveryCode, recoveryCode);
  } finally {
    await teardown();
  }
});

test('POST /login/totp after 5 wrong attempts returns 429', async () => {
  const { baseUrl, teardown } = await withAuthServer();
  try {
    const passwordHash = await bcrypt.hash('password123', 10);
    const user = userDb.createUser('lockedUser', passwordHash);
    const userId = Number(user.id);

    const secret = totpService.generateSecret();
    const sealed = totpService.sealSecret(secret);
    userDb.setTotp(userId, sealed, 'dummy-hash');

    // Helper to get a fresh totpToken (5 minute lifetime, reuse same secret)
    const JWT_SECRET_VAL = process.env.JWT_SECRET!;
    function makeTotpToken() {
      return jwt.sign({ sub: userId, purpose: 'totp_pending' }, JWT_SECRET_VAL, { expiresIn: '5m' });
    }

    // Make 5 failing attempts
    for (let i = 0; i < 5; i++) {
      const totpToken = makeTotpToken();
      await post(`${baseUrl}/auth/login/totp`, { totpToken, code: '000000' });
    }

    // 6th attempt should be locked
    const totpToken = makeTotpToken();
    const { status } = await post(`${baseUrl}/auth/login/totp`, { totpToken, code: '000000' });
    assert.equal(status, 429);
  } finally {
    await teardown();
  }
});

// ---------------------------------------------------------------------------
// Task 3.7 — TOTP setup endpoints
// ---------------------------------------------------------------------------

test('full TOTP setup flow: setup → verify-setup → login with TOTP', async () => {
  const { baseUrl, teardown } = await withAuthServer();
  try {
    const passwordHash = await bcrypt.hash('password123', 10);
    const user = userDb.createUser('setupUser', passwordHash);
    const userId = Number(user.id);

    // Get auth token (TOTP not enabled yet)
    const loginRes = await post(`${baseUrl}/auth/login`, { username: 'setupUser', password: 'password123' });
    assert.equal(loginRes.status, 200);
    const authToken = (loginRes.data as { token: string }).token;

    // GET /auth/totp/setup — needs auth header (use get helper workaround with POST-based test)
    // We'll call setup directly via node http with auth header
    const setupRes = await new Promise<{ status: number; data: unknown }>((resolve, reject) => {
      const parsed = new URL(`${baseUrl}/auth/totp/setup`);
      const req = http.request(
        {
          hostname: parsed.hostname,
          port: Number(parsed.port),
          path: parsed.pathname,
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Content-Length': '2',
            Authorization: `Bearer ${authToken}`,
          },
        },
        (res) => {
          let raw = '';
          res.on('data', (c) => { raw += c; });
          res.on('end', () => resolve({ status: res.statusCode ?? 0, data: JSON.parse(raw) }));
        }
      );
      req.on('error', reject);
      req.write('{}');
      req.end();
    });

    assert.equal(setupRes.status, 200);
    const { secret, otpauthUri, recoveryCode } = setupRes.data as {
      secret: string;
      otpauthUri: string;
      recoveryCode: string;
    };
    assert.ok(secret, 'should have secret');
    assert.match(otpauthUri, /^otpauth:\/\/totp\//);
    assert.ok(recoveryCode, 'should have recoveryCode');

    // POST /auth/totp/verify-setup with correct code
    const code = generateSync({ secret });
    const verifyRes = await new Promise<{ status: number; data: unknown }>((resolve, reject) => {
      const payload = JSON.stringify({ secret, code, recoveryCode });
      const parsed = new URL(`${baseUrl}/auth/totp/verify-setup`);
      const req = http.request(
        {
          hostname: parsed.hostname,
          port: Number(parsed.port),
          path: parsed.pathname,
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(payload),
            Authorization: `Bearer ${authToken}`,
          },
        },
        (res) => {
          let raw = '';
          res.on('data', (c) => { raw += c; });
          res.on('end', () => resolve({ status: res.statusCode ?? 0, data: JSON.parse(raw) }));
        }
      );
      req.on('error', reject);
      req.write(payload);
      req.end();
    });

    assert.equal(verifyRes.status, 200);
    assert.equal((verifyRes.data as { ok: boolean }).ok, true);

    // Confirm TOTP is enabled in DB
    const totpStatus = userDb.getTotpStatus(userId);
    assert.equal(totpStatus.enabled, true);
    assert.ok(totpStatus.secret, 'sealed secret should be stored');
    assert.ok(totpStatus.recoveryHash, 'recovery hash should be stored');

    // Now login should return requiresTotp
    const login2Res = await post(`${baseUrl}/auth/login`, { username: 'setupUser', password: 'password123' });
    assert.equal(login2Res.status, 200);
    assert.equal((login2Res.data as { requiresTotp: boolean }).requiresTotp, true);
    const { totpToken } = login2Res.data as { totpToken: string };

    // Get unsealed secret to generate a fresh code for login
    const unsealedSecret = totpService.unsealSecret(totpStatus.secret!);
    const loginCode = generateSync({ secret: unsealedSecret });
    const finalRes = await post(`${baseUrl}/auth/login/totp`, { totpToken, code: loginCode });
    assert.equal(finalRes.status, 200);
    assert.ok((finalRes.data as { token: string }).token, 'should have final JWT');
  } finally {
    await teardown();
  }
});

// ---------------------------------------------------------------------------
// Task 3.12 — GET /auth/user includes totpEnabled
// ---------------------------------------------------------------------------

test('GET /auth/user returns totpEnabled: false when TOTP is not set up', async () => {
  const { baseUrl, teardown } = await withAuthServer();
  try {
    const passwordHash = await bcrypt.hash('password123', 10);
    userDb.createUser('meNoTotp', passwordHash);

    const loginRes = await post(`${baseUrl}/auth/login`, { username: 'meNoTotp', password: 'password123' });
    assert.equal(loginRes.status, 200);
    const token = (loginRes.data as { token: string }).token;

    const meRes = await get(`${baseUrl}/auth/user`, token);
    assert.equal(meRes.status, 200);
    const userData = (meRes.data as { user: { totpEnabled: boolean } }).user;
    assert.equal(userData.totpEnabled, false, 'totpEnabled should be false when TOTP is not configured');
  } finally {
    await teardown();
  }
});

test('GET /auth/user returns totpEnabled: true after TOTP is enabled', async () => {
  const { baseUrl, teardown } = await withAuthServer();
  try {
    const passwordHash = await bcrypt.hash('password123', 10);
    const user = userDb.createUser('meWithTotp', passwordHash);
    const userId = Number(user.id);

    const secret = totpService.generateSecret();
    const sealed = totpService.sealSecret(secret);
    userDb.setTotp(userId, sealed, 'dummy-recovery-hash');

    const loginRes = await post(`${baseUrl}/auth/login`, { username: 'meWithTotp', password: 'password123' });
    assert.equal(loginRes.status, 200);
    const { totpToken } = loginRes.data as { totpToken: string };

    const code = generateSync({ secret });
    const totpRes = await post(`${baseUrl}/auth/login/totp`, { totpToken, code });
    assert.equal(totpRes.status, 200);
    const authToken = (totpRes.data as { token: string }).token;
    assert.ok(authToken, 'final JWT should be present');

    const meRes = await get(`${baseUrl}/auth/user`, authToken);
    assert.equal(meRes.status, 200);
    const userData = (meRes.data as { user: { totpEnabled: boolean } }).user;
    assert.equal(userData.totpEnabled, true, 'totpEnabled should be true after TOTP is configured');
  } finally {
    await teardown();
  }
});
