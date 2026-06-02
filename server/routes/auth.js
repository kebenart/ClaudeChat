import crypto from 'node:crypto';

import express from 'express';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { userDb } from '../modules/database/index.js';
import { getConnection } from '../modules/database/connection.js';
import { generateToken, authenticateToken, JWT_SECRET } from '../middleware/auth.js';
import { totpService } from '../services/totp.service.js';

// ---------------------------------------------------------------------------
// TOTP lockout (in-memory; single-user app)
// ---------------------------------------------------------------------------

const TOTP_LOCK_MAX = 5;
const TOTP_LOCK_WINDOW_MS = 15 * 60 * 1000;
/** @type {Map<number, { count: number; firstAt: number }>} */
const totpFailures = new Map();

function isLocked(userId) {
  const e = totpFailures.get(userId);
  if (!e) return false;
  if (Date.now() - e.firstAt > TOTP_LOCK_WINDOW_MS) { totpFailures.delete(userId); return false; }
  return e.count >= TOTP_LOCK_MAX;
}

function recordFailure(userId) {
  const e = totpFailures.get(userId) ?? { count: 0, firstAt: Date.now() };
  e.count += 1;
  totpFailures.set(userId, e);
}

function clearFailures(userId) { totpFailures.delete(userId); }

function makeRecoveryCode() {
  return crypto.randomBytes(10).toString('base64url');
}

const router = express.Router();
const db = getConnection();

// Check auth status and setup requirements
router.get('/status', async (req, res) => {
  try {
    const hasUsers = await userDb.hasUsers();
    // Surface DEV_AUTH_BYPASS so native clients can skip the login UI entirely.
    // We dynamic-import to avoid a startup-time circular dep with the middleware.
    let devBypass = false;
    try {
      const mod = await import('../middleware/auth.js');
      devBypass = Boolean(mod.DEV_AUTH_BYPASS);
    } catch { /* ignore */ }
    res.json({
      needsSetup: !hasUsers,
      isAuthenticated: devBypass,
      devBypass,
    });
  } catch (error) {
    console.error('Auth status error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// User registration (setup) - only allowed if no users exist
router.post('/register', async (req, res) => {
  try {
    const { username, password } = req.body;
    
    // Validate input
    if (!username || !password) {
      return res.status(400).json({ error: 'Username and password are required' });
    }
    
    if (username.length < 3 || password.length < 6) {
      return res.status(400).json({ error: 'Username must be at least 3 characters, password at least 6 characters' });
    }
    
    // Use a transaction to prevent race conditions
    db.prepare('BEGIN').run();
    try {
      // Check if users already exist (only allow one user)
      const hasUsers = userDb.hasUsers();
      if (hasUsers) {
        db.prepare('ROLLBACK').run();
        return res.status(403).json({ error: 'User already exists. This is a single-user system.' });
      }
      
      // Hash password
      const saltRounds = 12;
      const passwordHash = await bcrypt.hash(password, saltRounds);
      
      // Create user
      const user = userDb.createUser(username, passwordHash);
      
      // Generate token
      const token = generateToken(user);
      
      db.prepare('COMMIT').run();

      // Update last login (non-fatal, outside transaction)
      userDb.updateLastLogin(user.id);

      res.json({
        success: true,
        user: { id: user.id, username: user.username },
        token
      });
    } catch (error) {
      db.prepare('ROLLBACK').run();
      throw error;
    }
    
  } catch (error) {
    console.error('Registration error:', error);
    if (error.code === 'SQLITE_CONSTRAINT_UNIQUE') {
      res.status(409).json({ error: 'Username already exists' });
    } else {
      res.status(500).json({ error: 'Internal server error' });
    }
  }
});

// User login
router.post('/login', async (req, res) => {
  try {
    const { username, password } = req.body;
    
    // Validate input
    if (!username || !password) {
      return res.status(400).json({ error: 'Username and password are required' });
    }
    
    // Get user from database
    const user = userDb.getUserByUsername(username);
    if (!user) {
      return res.status(401).json({ error: 'Invalid username or password' });
    }
    
    // Verify password
    const isValidPassword = await bcrypt.compare(password, user.password_hash);
    if (!isValidPassword) {
      return res.status(401).json({ error: 'Invalid username or password' });
    }
    
    // Check TOTP
    const totp = userDb.getTotpStatus(user.id);
    if (totp.enabled) {
      const totpToken = jwt.sign(
        { sub: user.id, purpose: 'totp_pending' },
        JWT_SECRET,
        { expiresIn: '5m' }
      );
      return res.json({ requiresTotp: true, totpToken });
    }

    // Generate token
    const token = generateToken(user);

    // Update last login
    userDb.updateLastLogin(user.id);

    res.json({
      success: true,
      user: { id: user.id, username: user.username },
      token
    });

  } catch (error) {
    console.error('Login error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Get current user (protected route)
router.get('/user', authenticateToken, (req, res) => {
  const totpStatus = userDb.getTotpStatus(req.user.id);
  res.json({
    user: {
      ...req.user,
      totpEnabled: totpStatus.enabled,
    }
  });
});

// Logout (client-side token removal, but this endpoint can be used for logging)
router.post('/logout', authenticateToken, (req, res) => {
  // In a simple JWT system, logout is mainly client-side
  // This endpoint exists for consistency and potential future logging
  res.json({ success: true, message: 'Logged out successfully' });
});

// ---------------------------------------------------------------------------
// POST /login/totp — second factor: verify TOTP code or one-shot recovery code
// ---------------------------------------------------------------------------

router.post('/login/totp', async (req, res) => {
  try {
    const { totpToken, code } = req.body ?? {};
    if (!totpToken || (!code && !req.body?.recoveryCode)) {
      return res.status(400).json({ error: 'totpToken and (code or recoveryCode) are required' });
    }

    let payload;
    try {
      payload = jwt.verify(totpToken, JWT_SECRET);
    } catch {
      return res.status(401).json({ error: 'invalid totpToken' });
    }

    if (payload.purpose !== 'totp_pending') {
      return res.status(401).json({ error: 'wrong token purpose' });
    }

    if (isLocked(payload.sub)) {
      return res.status(429).json({ error: 'too many TOTP failures; try again later' });
    }

    const status = userDb.getTotpStatus(payload.sub);
    if (!status.enabled || !status.secret) {
      return res.status(400).json({ error: 'TOTP not configured' });
    }

    const authedUser = userDb.getUserById(payload.sub);
    if (!authedUser) {
      return res.status(401).json({ error: 'user not found' });
    }

    // Recovery-code branch (one-shot, rotates the recovery code)
    if (req.body?.recoveryCode) {
      let recoveryOk = false;
      try {
        recoveryOk = !!status.recoveryHash && (await bcrypt.compare(String(req.body.recoveryCode), status.recoveryHash));
      } catch (e) {
        console.error('[auth/login/totp] bcrypt.compare(recovery) failed:', e?.message);
      }
      if (!recoveryOk) {
        recordFailure(payload.sub);
        return res.status(401).json({ error: 'invalid recovery code' });
      }
      const newRecoveryCode = makeRecoveryCode();
      userDb.setTotp(payload.sub, status.secret, await bcrypt.hash(newRecoveryCode, 10));
      clearFailures(payload.sub);
      userDb.updateLastLogin(payload.sub);
      const token = generateToken(authedUser);
      return res.json({ token, newRecoveryCode });
    }

    // Standard TOTP code path. Most likely failure here is AES-GCM unseal
    // when JWT_SECRET has rotated since the secret was stored — the row
    // is unrecoverable; the user must reset via `npm run reset-totp`.
    let secret;
    try {
      secret = totpService.unsealSecret(status.secret);
    } catch (e) {
      console.error('[auth/login/totp] unsealSecret failed (JWT_SECRET rotated?):', e?.message);
      return res.status(500).json({
        error:
          'TOTP secret could not be decrypted. JWT_SECRET likely rotated since setup. ' +
          'Reset via: npm run reset-totp -- ' + (authedUser.username ?? '<username>'),
      });
    }

    if (!totpService.verifyCode(secret, String(code))) {
      recordFailure(payload.sub);
      return res.status(401).json({ error: 'invalid code' });
    }
    clearFailures(payload.sub);
    userDb.updateLastLogin(payload.sub);
    const token = generateToken(authedUser);
    return res.json({ token });
  } catch (err) {
    console.error('[auth/login/totp] unexpected:', err);
    return res.status(500).json({ error: 'internal error' });
  }
});

// ---------------------------------------------------------------------------
// POST /totp/setup — authenticated: generate a new TOTP secret for setup
// ---------------------------------------------------------------------------

router.post('/totp/setup', authenticateToken, (req, res) => {
  const secret = totpService.generateSecret();
  const username = req.user?.username ?? String(req.user?.id ?? 'user');
  const recoveryCode = makeRecoveryCode();
  const otpauthUri = totpService.provisioningUri(username, secret);
  res.json({ secret, otpauthUri, recoveryCode });
});

// ---------------------------------------------------------------------------
// POST /totp/verify-setup — authenticated: verify code and activate TOTP
// ---------------------------------------------------------------------------

router.post('/totp/verify-setup', authenticateToken, async (req, res) => {
  const { secret, code, recoveryCode } = req.body ?? {};
  if (!secret || !code || !recoveryCode) {
    return res.status(400).json({ error: 'secret, code, recoveryCode required' });
  }
  if (!totpService.verifyCode(secret, String(code))) {
    return res.status(401).json({ error: 'code does not match secret' });
  }
  const sealed = totpService.sealSecret(secret);
  const recoveryHash = await bcrypt.hash(recoveryCode, 10);
  userDb.setTotp(req.user.id, sealed, recoveryHash);
  res.json({ ok: true });
});

export default router;
