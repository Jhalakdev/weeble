// Centralized audit logging. Every security-sensitive event flows through here
// so we have a single place to add log shipping, alerting, and retention later.
//
// Calls are intentionally synchronous (better-sqlite-style) — they execute in
// the same transaction as the action they describe, so we either record both
// or neither.

import { getDb } from '../db/index.js';

export function audit({ accountId, deviceId, ip, action, detail }) {
  const db = getDb();
  db.prepare(`
    INSERT INTO audit_log (account_id, device_id, ip, action, detail, at)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(
    accountId ?? null,
    deviceId ?? null,
    ip || 'unknown',
    action,
    detail ? JSON.stringify(detail) : null,
    Math.floor(Date.now() / 1000),
  );
}

// Helper that pulls the IP from the Fastify request the same way our
// other code does.
export function ipOf(req) {
  return req.ip || req.headers?.['x-forwarded-for'] || 'unknown';
}
