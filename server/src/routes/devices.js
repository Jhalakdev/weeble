import { getDb } from '../db/index.js';
import { ulid } from '../lib/ids.js';
import { signAccessToken } from '../lib/jwt.js';
import { mintRefreshToken, revokeDeviceRefreshTokens } from '../lib/refresh.js';

export default async function deviceRoutes(app) {
  // Register a new device under the authenticated account.
  app.post('/v1/devices', {
    preHandler: app.requireAuth,
    schema: {
      body: {
        type: 'object',
        required: ['kind', 'name', 'platform', 'pubkey'],
        properties: {
          kind: { type: 'string', enum: ['host', 'client'] },
          name: { type: 'string', maxLength: 100 },
          platform: { type: 'string', enum: ['macos', 'windows', 'linux', 'ios', 'android', 'web'] },
          pubkey: { type: 'string', maxLength: 200 },
        },
      },
    },
  }, async (req) => {
    const db = getDb();
    const now = Math.floor(Date.now() / 1000);

    // IDEMPOTENT on (account_id, pubkey, kind): reuse an existing active
    // device row instead of creating a duplicate on every login. Without
    // this, every logout→login creates a ghost row on the VPS.
    const existing = db.prepare(`
      SELECT id FROM devices
      WHERE account_id = ? AND pubkey = ? AND kind = ? AND revoked_at IS NULL
      LIMIT 1
    `).get(req.auth.accountId, req.body.pubkey, req.body.kind);

    let id;
    if (existing) {
      id = existing.id;
      db.prepare('UPDATE devices SET name = ?, last_seen_at = ? WHERE id = ?')
        .run(req.body.name, now, id);
    } else {
      id = ulid();
      db.prepare(`
        INSERT INTO devices (id, account_id, kind, name, platform, pubkey, created_at, last_seen_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      `).run(id, req.auth.accountId, req.body.kind, req.body.name, req.body.platform, req.body.pubkey, now, now);
    }

    const account = db.prepare('SELECT plan FROM accounts WHERE id = ?').get(req.auth.accountId);
    const token = await signAccessToken({
      accountId: req.auth.accountId,
      deviceId: id,
      plan: account.plan,
    });
    // Mint a device-bound refresh token so the native client can
    // refresh its short-lived access token without re-login.
    const refresh = await mintRefreshToken(db, {
      accountId: req.auth.accountId,
      deviceId: id,
      userAgent: req.headers['user-agent']?.slice(0, 200) ?? null,
      ip: req.ip ?? null,
    });
    return {
      device_id: id,
      token,
      access_token: token,
      refresh_token: refresh,
      existing: !!existing,
    };
  });

  // List devices on the account.
  app.get('/v1/devices', { preHandler: app.requireAuth }, async (req) => {
    const db = getDb();
    const rows = db.prepare(`
      SELECT id, kind, name, platform, created_at, last_seen_at, revoked_at
      FROM devices WHERE account_id = ? AND revoked_at IS NULL
      ORDER BY last_seen_at DESC
    `).all(req.auth.accountId);
    return { devices: rows };
  });

  // Rename a device.
  app.patch('/v1/devices/:id', {
    preHandler: app.requireAuth,
    schema: {
      body: {
        type: 'object',
        required: ['name'],
        properties: { name: { type: 'string', minLength: 1, maxLength: 100 } },
      },
    },
  }, async (req, reply) => {
    const db = getDb();
    const r = db.prepare(`
      UPDATE devices SET name = ?
      WHERE id = ? AND account_id = ? AND revoked_at IS NULL
    `).run(req.body.name, req.params.id, req.auth.accountId);
    if (r.changes === 0) return reply.code(404).send({ error: 'not_found' });
    return { ok: true };
  });

  // Revoke a device. Once revoked, its JWT remains valid until expiry (max 1h),
  // but it cannot register new endpoints or look up other devices.
  app.delete('/v1/devices/:id', { preHandler: app.requireAuth }, async (req, reply) => {
    const db = getDb();
    const now = Math.floor(Date.now() / 1000);
    const result = db.prepare(`
      UPDATE devices SET revoked_at = ?
      WHERE id = ? AND account_id = ? AND revoked_at IS NULL
    `).run(now, req.params.id, req.auth.accountId);
    if (result.changes === 0) return reply.code(404).send({ error: 'not_found' });
    // Also revoke every refresh token bound to this device so the
    // client can't mint new access tokens after revocation.
    revokeDeviceRefreshTokens(db, req.params.id);
    return { ok: true };
  });

  // Host announces its public IP+port. Called on startup, on IP change, and as a
  // periodic heartbeat. ALSO carries the single-active-host enforcement:
  //
  //   - First-ever host on this account → becomes active automatically.
  //   - Already the active host → just refreshes endpoint.
  //   - Different host is currently active:
  //       - take_over=false (default for periodic heartbeats): refused with 409
  //         and {status: 'demoted'}. Caller's UI should show the "demoted" screen.
  //       - take_over=true (the explicit "make this machine the server" action):
  //         atomically swaps; previous host will see status=demoted on its next
  //         heartbeat.
  app.post('/v1/devices/me/announce', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    schema: {
      body: {
        type: 'object',
        required: ['port', 'reachability', 'cert_fingerprint'],
        properties: {
          // Optional. If absent or 'auto', server uses the caller's req.ip.
          // This lets hosts re-announce on a timer without doing their own
          // public-IP lookup — every announce naturally captures any IP change.
          public_ip: { type: 'string', maxLength: 45 },
          port: { type: 'integer', minimum: 1, maximum: 65535 },
          reachability: { type: 'string', enum: ['upnp', 'manual', 'unknown'] },
          cert_fingerprint: { type: 'string', maxLength: 100 },
          take_over: { type: 'boolean', default: false },
        },
      },
    },
  }, async (req, reply) => {
    if (!req.auth.deviceId) return reply.code(400).send({ error: 'no_device_binding' });

    const db = getDb();
    const now = Math.floor(Date.now() / 1000);
    const publicIp = (req.body.public_ip && req.body.public_ip !== 'auto')
      ? req.body.public_ip
      : (req.ip || req.headers['x-forwarded-for'] || 'unknown');

    const device = db.prepare(`
      SELECT id FROM devices WHERE id = ? AND account_id = ? AND kind = 'host' AND revoked_at IS NULL
    `).get(req.auth.deviceId, req.auth.accountId);
    if (!device) return reply.code(403).send({ error: 'not_a_host' });

    const account = db.prepare('SELECT active_host_device_id FROM accounts WHERE id = ?').get(req.auth.accountId);
    const currentActive = account.active_host_device_id;
    const takeOver = req.body.take_over === true;

    if (currentActive && currentActive !== req.auth.deviceId && !takeOver) {
      return reply.code(409).send({
        status: 'demoted',
        active_host_device_id: currentActive,
        error: 'not_active_host',
      });
    }

    // Atomic swap: claim active slot, then write endpoint.
    const previousActive = currentActive && currentActive !== req.auth.deviceId ? currentActive : null;
    if (previousActive || !currentActive) {
      db.prepare('UPDATE accounts SET active_host_device_id = ? WHERE id = ?')
        .run(req.auth.deviceId, req.auth.accountId);
    }

    db.prepare(`
      INSERT INTO host_endpoints (device_id, public_ip, port, reachability, cert_fingerprint, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(device_id) DO UPDATE SET
        public_ip = excluded.public_ip,
        port = excluded.port,
        reachability = excluded.reachability,
        cert_fingerprint = excluded.cert_fingerprint,
        updated_at = excluded.updated_at
    `).run(req.auth.deviceId, publicIp, req.body.port, req.body.reachability, req.body.cert_fingerprint, now);

    db.prepare('UPDATE devices SET last_seen_at = ? WHERE id = ?').run(now, req.auth.deviceId);

    return {
      ok: true,
      status: 'active',
      public_ip: publicIp,
      took_over_from: previousActive,
      next_announce_in: 1800,
    };
  });

  // Account-level "where is my host right now?" lookup. THIS is what phones
  // use — they don't store a specific host_device_id anymore. They ask the
  // account, get whatever device is currently the active host, connect to it.
  // Survives the user replacing their server hardware with zero re-pairing.
  app.get('/v1/accounts/me/active-host', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
  }, async (req, reply) => {
    const db = getDb();
    const account = db.prepare(`
      SELECT a.active_host_device_id, d.name AS host_name
      FROM accounts a
      LEFT JOIN devices d ON d.id = a.active_host_device_id
      WHERE a.id = ?
    `).get(req.auth.accountId);

    if (!account.active_host_device_id) {
      return reply.code(404).send({ error: 'no_active_host' });
    }

    const endpoint = db.prepare(`
      SELECT public_ip, port, reachability, cert_fingerprint, updated_at
      FROM host_endpoints WHERE device_id = ?
    `).get(account.active_host_device_id);
    if (!endpoint) return reply.code(404).send({ error: 'host_offline' });

    const now = Math.floor(Date.now() / 1000);
    if (now - endpoint.updated_at > 7200) {
      return reply.code(404).send({ error: 'host_offline' });
    }

    return {
      device_id: account.active_host_device_id,
      name: account.host_name,
      ...endpoint,
    };
  });

  // Client looks up a host's current endpoint. THIS is the subscription gate.
  app.get('/v1/devices/:id/endpoint', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
  }, async (req, reply) => {
    const db = getDb();
    // Host must belong to the same account as the requesting client.
    const host = db.prepare(`
      SELECT d.id FROM devices d
      WHERE d.id = ? AND d.account_id = ? AND d.kind = 'host' AND d.revoked_at IS NULL
    `).get(req.params.id, req.auth.accountId);
    if (!host) return reply.code(404).send({ error: 'host_not_found' });

    const endpoint = db.prepare(`
      SELECT public_ip, port, reachability, cert_fingerprint, updated_at
      FROM host_endpoints WHERE device_id = ?
    `).get(req.params.id);
    if (!endpoint) return reply.code(404).send({ error: 'host_offline' });

    // If endpoint hasn't been refreshed in 2x its expected interval, treat as stale.
    const now = Math.floor(Date.now() / 1000);
    if (now - endpoint.updated_at > 7200) {
      return reply.code(404).send({ error: 'host_offline' });
    }

    return endpoint;
  });
}
