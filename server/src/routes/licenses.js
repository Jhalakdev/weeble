import { getDb } from '../db/index.js';
import { ulid } from '../lib/ids.js';
import { signReceipt, verifyReceipt, getLicensePublicKeyPem } from '../lib/license_keys.js';
import { checkLicenseAbuse, recordAttempt, flagLicense } from '../lib/abuse.js';
import { isAccountActive } from '../lib/subscription.js';

const RECEIPT_TTL = 7 * 24 * 3600; // 7 days

// One license = one person, unlimited devices. We rely on activity-pattern
// abuse detection (geo spread, impossible simultaneity, burst) to catch
// licenses being shared across many people.

function clientIp(req) {
  // We trust the proxy header because Fastify's trustProxy is on.
  return req.ip || req.headers['x-forwarded-for'] || 'unknown';
}

export default async function licenseRoutes(app) {
  // The Flutter app fetches our public key on first launch (or it's embedded
  // at build time — see app/lib/security/embedded_keys.dart). This endpoint
  // exists for ops + key rotation flows.
  app.get('/v1/licenses/public-key', async () => {
    return { pem: getLicensePublicKeyPem() };
  });

  // Issue a license for an account. Called by the billing webhook handler
  // after a successful Stripe / AppSumo purchase. Internal — protected by
  // bearer auth (the account's own JWT) for now; in production, replace with
  // an internal-API token check.
  app.post('/v1/licenses/issue', {
    preHandler: app.requireAuth,
    schema: {
      body: {
        type: 'object',
        required: ['plan'],
        properties: { plan: { type: 'string', enum: ['monthly', 'yearly', 'lifetime'] } },
      },
    },
  }, async (req) => {
    const db = getDb();
    const id = ulid();
    db.prepare(`
      INSERT INTO licenses (id, account_id, plan, issued_at)
      VALUES (?, ?, ?, ?)
    `).run(id, req.auth.accountId, req.body.plan, Math.floor(Date.now() / 1000));
    return { license_id: id };
  });

  // Activate a device against a license. Called by the Flutter app on first
  // launch (after device registration). Returns a signed receipt that the
  // app stores and presents on every subsequent API call.
  app.post('/v1/licenses/activate', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    schema: {
      body: {
        type: 'object',
        required: ['hardware_fingerprint'],
        properties: {
          hardware_fingerprint: { type: 'string', minLength: 32, maxLength: 128 },
          platform: { type: 'string', maxLength: 32 },
        },
      },
    },
  }, async (req, reply) => {
    if (!req.auth.deviceId) return reply.code(400).send({ error: 'no_device_binding' });
    const db = getDb();
    const ip = clientIp(req);
    const fp = req.body.hardware_fingerprint;

    // Find the most recent un-revoked, un-flagged license on this account.
    const license = db.prepare(`
      SELECT * FROM licenses
      WHERE account_id = ? AND revoked_at IS NULL AND abuse_flagged_at IS NULL
      ORDER BY issued_at DESC LIMIT 1
    `).get(req.auth.accountId);

    if (!license) {
      // No formal license issued (e.g., still in trial). Synthesize a virtual one
      // bound to the trial state. This way trial users get receipts and the
      // verification flow is uniform across plans.
      const account = req.account; // populated by requireActiveSubscription
      if (!isAccountActive(account)) {
        recordAttempt({ accountId: req.auth.accountId, fingerprint: fp, ip, result: 'no_license' });
        return reply.code(402).send({ error: 'no_license' });
      }
      const receipt = await signReceipt({
        accountId: req.auth.accountId,
        deviceId: req.auth.deviceId,
        licenseId: 'trial',
        fingerprint: fp,
        plan: 'trial',
        ttlSeconds: RECEIPT_TTL,
      });
      // Insert a "synthetic" activation row using a sentinel license_id. We use
      // the account id as the license id for trial rows so device-cap counting
      // still works.
      db.prepare(`
        INSERT INTO activations (license_id, device_id, hardware_fingerprint, ip, ua, activated_at, last_heartbeat_at)
        SELECT ?, ?, ?, ?, ?, ?, ?
        WHERE NOT EXISTS (
          SELECT 1 FROM activations WHERE device_id = ? AND revoked_at IS NULL
        )
      `).run('trial', req.auth.deviceId, fp, ip, req.body.platform ?? '', Math.floor(Date.now() / 1000), Math.floor(Date.now() / 1000), req.auth.deviceId);
      recordAttempt({ accountId: req.auth.accountId, fingerprint: fp, ip, result: 'ok' });
      return { receipt, ttl_seconds: RECEIPT_TTL, plan: 'trial' };
    }

    // Real license path.
    // Abuse check before doing anything.
    const abuse = checkLicenseAbuse(license.id, fp, ip);
    if (abuse.flagged) {
      flagLicense(license.id, abuse.reason);
      recordAttempt({ licenseId: license.id, accountId: req.auth.accountId, fingerprint: fp, ip, result: 'abuse_flagged' });
      return reply.code(403).send({ error: 'abuse_detected' });
    }

    // Already activated on this fingerprint? Renew receipt without bumping the cap.
    const existing = db.prepare(`
      SELECT * FROM activations
      WHERE license_id = ? AND hardware_fingerprint = ? AND revoked_at IS NULL
    `).get(license.id, fp);

    if (!existing) {
      // No device cap — but every new fingerprint is fed through the abuse
      // detector above, which flags suspicious patterns.
      db.prepare(`
        INSERT INTO activations (license_id, device_id, hardware_fingerprint, ip, ua, activated_at, last_heartbeat_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      `).run(license.id, req.auth.deviceId, fp, ip, req.body.platform ?? '', Math.floor(Date.now() / 1000), Math.floor(Date.now() / 1000));
    } else {
      db.prepare('UPDATE activations SET last_heartbeat_at = ?, ip = ? WHERE id = ?')
        .run(Math.floor(Date.now() / 1000), ip, existing.id);
    }

    const receipt = await signReceipt({
      accountId: req.auth.accountId,
      deviceId: req.auth.deviceId,
      licenseId: license.id,
      fingerprint: fp,
      plan: license.plan,
      ttlSeconds: RECEIPT_TTL,
    });
    recordAttempt({ licenseId: license.id, accountId: req.auth.accountId, fingerprint: fp, ip, result: 'ok' });
    return { receipt, ttl_seconds: RECEIPT_TTL, plan: license.plan };
  });

  // 7-day heartbeat. Client sends its existing receipt; we verify it still
  // corresponds to a non-revoked activation and re-issue a fresh one.
  app.post('/v1/licenses/heartbeat', {
    preHandler: app.requireAuth,
    schema: {
      body: {
        type: 'object',
        required: ['receipt', 'hardware_fingerprint'],
        properties: {
          receipt: { type: 'string' },
          hardware_fingerprint: { type: 'string' },
        },
      },
    },
  }, async (req, reply) => {
    const ip = clientIp(req);
    let payload;
    try {
      payload = await verifyReceipt(req.body.receipt);
    } catch {
      return reply.code(401).send({ error: 'invalid_receipt' });
    }

    if (payload.fp !== req.body.hardware_fingerprint) {
      return reply.code(403).send({ error: 'fingerprint_mismatch' });
    }

    const db = getDb();
    const activation = db.prepare(`
      SELECT * FROM activations
      WHERE device_id = ? AND hardware_fingerprint = ? AND revoked_at IS NULL
    `).get(payload.did, payload.fp);
    if (!activation) return reply.code(403).send({ error: 'revoked' });

    // Re-check license validity.
    if (payload.lid !== 'trial') {
      const license = db.prepare('SELECT * FROM licenses WHERE id = ?').get(payload.lid);
      if (!license || license.revoked_at || license.abuse_flagged_at) {
        return reply.code(403).send({ error: 'license_revoked' });
      }
    } else {
      // Trial — re-check that the account is still in trial / paid state.
      const account = db.prepare('SELECT * FROM accounts WHERE id = ?').get(payload.sub);
      if (!isAccountActive(account)) return reply.code(402).send({ error: 'subscription_inactive' });
    }

    db.prepare('UPDATE activations SET last_heartbeat_at = ?, ip = ? WHERE id = ?')
      .run(Math.floor(Date.now() / 1000), ip, activation.id);

    const fresh = await signReceipt({
      accountId: payload.sub,
      deviceId: payload.did,
      licenseId: payload.lid,
      fingerprint: payload.fp,
      plan: payload.plan,
      ttlSeconds: RECEIPT_TTL,
    });
    return { receipt: fresh, ttl_seconds: RECEIPT_TTL };
  });

  // Owner can revoke a specific activation (e.g., "I sold this Mac, deactivate it").
  app.delete('/v1/licenses/activations/:id', { preHandler: app.requireAuth }, async (req, reply) => {
    const db = getDb();
    const r = db.prepare(`
      UPDATE activations SET revoked_at = ?
      WHERE id = ? AND device_id IN (SELECT id FROM devices WHERE account_id = ?)
        AND revoked_at IS NULL
    `).run(Math.floor(Date.now() / 1000), req.params.id, req.auth.accountId);
    if (r.changes === 0) return reply.code(404).send({ error: 'not_found' });
    return { ok: true };
  });
}
