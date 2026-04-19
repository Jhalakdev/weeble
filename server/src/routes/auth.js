import argon2 from 'argon2';
import { getDb } from '../db/index.js';
import { ulid, urlSafeToken } from '../lib/ids.js';
import { signAccessToken } from '../lib/jwt.js';

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

    // Issue a token without a device binding. The device must register separately
    // (which produces a device_id) before it can announce itself or look up endpoints.
    const token = await signAccessToken({
      accountId: account.id,
      deviceId: null,
      plan: account.plan,
    });
    return { token, account_id: account.id, plan: account.plan, status: account.subscription_status };
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
    return { token: jwt, account_id: account.id, plan: account.plan };
  });
}
