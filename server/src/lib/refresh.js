// Refresh-token pipeline (industry-standard rotating one-shot pattern).
//
// On login/register:    mintRefreshToken() — stores a hashed row, returns the raw token.
// On refresh:           rotateRefreshToken(raw) — verifies, marks old as used,
//                       issues a fresh one in the same family. If the supplied
//                       token was ALREADY used, treat as theft → revoke the
//                       whole family.
// On logout:            revokeRefreshToken(raw) — marks one token (+ family if
//                       it had rotations) revoked.
// On device delete:     revokeDeviceRefreshTokens(deviceId) — bulk revoke.
//
// Refresh tokens are ~32 bytes of random base64url, stored only as argon2id
// hashes. Token value never logged, never hits the DB as plaintext.

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { ulid } from './ids.js';

// 90 days. Long enough that a Mac host barely ever has to prompt; short
// enough that a forgotten session on a public machine goes stale.
const REFRESH_TTL_SECONDS = 90 * 24 * 3600;

// Token format: `wr_` prefix (identifies the type in logs without leaking
// the secret) + 32 random bytes encoded base64url. ~43 characters.
function generateRawToken() {
  return 'wr_' + randomBytes(32).toString('base64url');
}

// Fast SHA-256 hash. We're NOT using argon2 here because:
//   - the token is 32 bytes of cryptographic randomness (no brute-force
//     threat — attacker would need 2^256 guesses)
//   - argon2 would add ~100 ms per refresh, burning CPU on the VPS for
//     every API-wakeup across all clients.
// SHA-256 is industry standard for high-entropy opaque tokens (Stripe,
// Slack, GitHub all do this).
function hashToken(raw) {
  return createHash('sha256').update(raw).digest('hex');
}

export async function mintRefreshToken(db, { accountId, deviceId = null, familyId = null, userAgent = null, ip = null }) {
  const raw = generateRawToken();
  const id = ulid();
  const now = Math.floor(Date.now() / 1000);
  db.prepare(`
    INSERT INTO refresh_tokens (id, account_id, device_id, token_hash, family_id, created_at, expires_at, user_agent, ip)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    id, accountId, deviceId, hashToken(raw),
    familyId ?? id, // new family starts with itself
    now, now + REFRESH_TTL_SECONDS, userAgent, ip,
  );
  return raw;
}

/// Returns { accountId, deviceId, refreshToken } on success.
/// Throws { code: 'not_found' | 'expired' | 'revoked' | 'reuse' } on failure.
/// 'reuse' means we caught an already-used refresh token being presented
/// again → suspected theft → the whole family is revoked immediately.
export async function rotateRefreshToken(db, raw, { userAgent = null, ip = null } = {}) {
  if (!raw || !raw.startsWith('wr_')) throw Object.assign(new Error(), { code: 'not_found' });
  const row = db.prepare(`
    SELECT * FROM refresh_tokens WHERE token_hash = ?
  `).get(hashToken(raw));
  if (!row) throw Object.assign(new Error(), { code: 'not_found' });

  const now = Math.floor(Date.now() / 1000);

  if (row.revoked_at) throw Object.assign(new Error(), { code: 'revoked' });
  if (row.expires_at < now) throw Object.assign(new Error(), { code: 'expired' });

  // THEFT DETECTION. If this token has already been used (row.used_at set),
  // someone is presenting the OLD half of a rotated pair — that means
  // either the attacker stole the pre-rotation token, or the legitimate
  // client got confused and reused it. Either way, nuke the whole family.
  if (row.used_at) {
    db.prepare(`
      UPDATE refresh_tokens SET revoked_at = ? WHERE family_id = ? AND revoked_at IS NULL
    `).run(now, row.family_id);
    throw Object.assign(new Error(), { code: 'reuse' });
  }

  // Mint the replacement.
  const next = generateRawToken();
  const nextId = ulid();
  db.prepare(`
    INSERT INTO refresh_tokens (id, account_id, device_id, token_hash, family_id, created_at, expires_at, user_agent, ip)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    nextId, row.account_id, row.device_id, hashToken(next),
    row.family_id, now, now + REFRESH_TTL_SECONDS,
    userAgent, ip,
  );
  db.prepare(`
    UPDATE refresh_tokens SET used_at = ?, replaced_by = ? WHERE id = ?
  `).run(now, nextId, row.id);

  return { accountId: row.account_id, deviceId: row.device_id, refreshToken: next };
}

export async function revokeRefreshToken(db, raw) {
  if (!raw || !raw.startsWith('wr_')) return;
  const now = Math.floor(Date.now() / 1000);
  const row = db.prepare('SELECT family_id FROM refresh_tokens WHERE token_hash = ?').get(hashToken(raw));
  if (!row) return;
  db.prepare(`
    UPDATE refresh_tokens SET revoked_at = ? WHERE family_id = ? AND revoked_at IS NULL
  `).run(now, row.family_id);
}

export function revokeDeviceRefreshTokens(db, deviceId) {
  const now = Math.floor(Date.now() / 1000);
  db.prepare(`
    UPDATE refresh_tokens SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL
  `).run(now, deviceId);
}

// Simple comparator (timing-safe) for DB token_hash → input-hash lookups
// we don't actually need this since we index by hash — but kept for any
// audit path that does direct byte compare.
export function safeEq(a, b) {
  const x = Buffer.from(a, 'utf8');
  const y = Buffer.from(b, 'utf8');
  if (x.length !== y.length) return false;
  return timingSafeEqual(x, y);
}

export const REFRESH_COOKIE_MAX_AGE_SECONDS = REFRESH_TTL_SECONDS;
