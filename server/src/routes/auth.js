import argon2 from 'argon2';
import { getDb } from '../db/index.js';
import { ulid, urlSafeToken } from '../lib/ids.js';
import { signAccessToken } from '../lib/jwt.js';
import {
  mintRefreshToken, rotateRefreshToken, revokeRefreshToken,
  REFRESH_COOKIE_MAX_AGE_SECONDS,
} from '../lib/refresh.js';

export default async function authRoutes(app) {
  app.post('/v1/auth/register', {
    schema: {
      body: {
        type: 'object',
        required: ['email', 'password'],
        properties: {
          email: { type: 'string', format: 'email', maxLength: 254 },
          password: { type: 'string', minLength: 10, maxLength: 200 },
        },
      },
    },
  }, async (req, reply) => {
    const { email, password } = req.body;
    const db = getDb();
    const now = Math.floor(Date.now() / 1000);

    const existing = db.prepare('SELECT id FROM accounts WHERE email = ?').get(email);
    if (existing) return reply.code(409).send({ error: 'email_taken' });

    const hash = await argon2.hash(password, { type: argon2.argon2id });
    const id = ulid();
    db.prepare(`
      INSERT INTO accounts (id, email, password_hash, created_at, trial_started_at)
      VALUES (?, ?, ?, ?, ?)
    `).run(id, email, hash, now, now);

    return { account_id: id };
  });

  app.post('/v1/auth/login', {
    schema: {
      body: {
        type: 'object',
        required: ['email', 'password'],
        properties: {
          email: { type: 'string', format: 'email' },
          password: { type: 'string' },
        },
      },
    },
  }, async (req, reply) => {
    const { email, password } = req.body;
    const db = getDb();
    const account = db.prepare('SELECT * FROM accounts WHERE email = ?').get(email);
    if (!account) return reply.code(401).send({ error: 'invalid_credentials' });

    const ok = await argon2.verify(account.password_hash, password);
    if (!ok) return reply.code(401).send({ error: 'invalid_credentials' });

    // Issue BOTH a short-lived access token AND a long-lived rotating
    // refresh token. Clients store the refresh token; whenever their
    // access token 401s, they POST it to /v1/auth/refresh and get a
    // fresh pair transparently. Industry-standard pattern used by
    // Stripe, Slack, GitHub, Vercel, etc.
    //
    // device_id is NULL at login time — the native client registers
    // its device separately which then mints a device-bound pair.
    // Web sessions never have a device_id; that's fine because
    // revoking a web session just revokes that refresh family.
    const access = await signAccessToken({
      accountId: account.id, deviceId: null, plan: account.plan,
    });
    const refresh = await mintRefreshToken(db, {
      accountId: account.id, deviceId: null,
      userAgent: req.headers['user-agent']?.slice(0, 200) ?? null,
      ip: req.ip ?? null,
    });
    return {
      token: access,          // legacy field — older clients still look for `token`
      access_token: access,
      refresh_token: refresh,
      account_id: account.id,
      plan: account.plan,
      status: account.subscription_status,
    };
  });

  // Refresh endpoint. Swap an old refresh token for a fresh pair.
  // Rotating one-shot: the old refresh token becomes invalid
  // immediately; presenting it again is treated as theft and
  // revokes the whole family.
  app.post('/v1/auth/refresh', {
    schema: {
      body: {
        type: 'object',
        required: ['refresh_token'],
        properties: { refresh_token: { type: 'string', maxLength: 200 } },
      },
    },
  }, async (req, reply) => {
    const db = getDb();
    let rotated;
    try {
      rotated = await rotateRefreshToken(db, req.body.refresh_token, {
        userAgent: req.headers['user-agent']?.slice(0, 200) ?? null,
        ip: req.ip ?? null,
      });
    } catch (e) {
      // 'not_found' | 'expired' | 'revoked' | 'reuse'
      return reply.code(401).send({ error: e.code || 'refresh_rejected' });
    }

    const account = db.prepare('SELECT id, plan FROM accounts WHERE id = ?').get(rotated.accountId);
    if (!account) return reply.code(401).send({ error: 'no_account' });

    const access = await signAccessToken({
      accountId: account.id,
      deviceId: rotated.deviceId,
      plan: account.plan,
    });
    return {
      access_token: access,
      refresh_token: rotated.refreshToken,
      token: access, // legacy
    };
  });

  // Logout. Revokes the supplied refresh token (and its whole family,
  // so any descendants already issued are dead). Idempotent —
  // presenting an already-revoked token is a no-op.
  app.post('/v1/auth/logout', {
    schema: {
      body: {
        type: 'object',
        properties: { refresh_token: { type: 'string', maxLength: 200 } },
      },
    },
  }, async (req, reply) => {
    if (req.body?.refresh_token) {
      await revokeRefreshToken(getDb(), req.body.refresh_token);
    }
    return { ok: true };
  });

  // Pairing: existing host generates a single-use token (shown as QR code).
  // New device exchanges the token for an account-bound JWT.
  app.post('/v1/auth/pairing/create', { preHandler: app.requireAuth }, async (req) => {
    const db = getDb();
    const token = urlSafeToken(24);
    const expiresAt = Math.floor(Date.now() / 1000) + 60;
    db.prepare(`
      INSERT INTO pairing_tokens (token, account_id, expires_at)
      VALUES (?, ?, ?)
    `).run(token, req.auth.accountId, expiresAt);
    return { token, expires_at: expiresAt };
  });

  app.post('/v1/auth/pairing/redeem', {
    schema: {
      body: {
        type: 'object',
        required: ['token'],
        properties: { token: { type: 'string' } },
      },
    },
  }, async (req, reply) => {
    const db = getDb();
    const now = Math.floor(Date.now() / 1000);
    const row = db.prepare(`
      SELECT * FROM pairing_tokens WHERE token = ?
    `).get(req.body.token);

    if (!row || row.consumed_at || row.expires_at < now) {
      return reply.code(400).send({ error: 'invalid_or_expired' });
    }

    db.prepare('UPDATE pairing_tokens SET consumed_at = ? WHERE token = ?').run(now, req.body.token);

    const account = db.prepare('SELECT * FROM accounts WHERE id = ?').get(row.account_id);
    const jwt = await signAccessToken({
      accountId: account.id,
      deviceId: null,
      plan: account.plan,
    });
    // Pairing = a full sign-in. Issue a refresh token too so the new
    // device stays logged in for 90 days like a normal login.
    const refresh = await mintRefreshToken(db, {
      accountId: account.id, deviceId: null,
      userAgent: req.headers['user-agent']?.slice(0, 200) ?? null,
      ip: req.ip ?? null,
    });
    return {
      token: jwt,
      access_token: jwt,
      refresh_token: refresh,
      account_id: account.id,
      plan: account.plan,
    };
  });

}
// (The older "expired-JWT grace" /v1/auth/refresh endpoint was replaced
// above by the proper rotating-refresh-token version. Clients that still
// POST {token: <jwt>} will get a 400 from the schema validator; they're
// expected to update to {refresh_token: <wr_...>} on their next build.)
