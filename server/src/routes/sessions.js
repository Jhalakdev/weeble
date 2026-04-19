import { getDb } from '../db/index.js';
import { urlSafeToken } from '../lib/ids.js';

const TTL_SECONDS = 5 * 60;

export default async function sessionRoutes(app) {
  // Client requests a session token authorizing it to talk to a specific host.
  // The token is presented to the host on every connection. The host then
  // calls /v1/sessions/validate to confirm it (with caching).
  app.post('/v1/sessions/issue', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    schema: {
      body: {
        type: 'object',
        required: ['host_device_id'],
        properties: { host_device_id: { type: 'string' } },
      },
    },
  }, async (req, reply) => {
    if (!req.auth.deviceId) return reply.code(400).send({ error: 'no_device_binding' });

    const db = getDb();
    const host = db.prepare(`
      SELECT id FROM devices
      WHERE id = ? AND account_id = ? AND kind = 'host' AND revoked_at IS NULL
    `).get(req.body.host_device_id, req.auth.accountId);
    if (!host) return reply.code(404).send({ error: 'host_not_found' });

    const now = Math.floor(Date.now() / 1000);
    const token = urlSafeToken(32);
    db.prepare(`
      INSERT INTO session_tokens (token, account_id, client_device_id, host_device_id, issued_at, expires_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(token, req.auth.accountId, req.auth.deviceId, req.body.host_device_id, now, now + TTL_SECONDS);

    return { token, expires_at: now + TTL_SECONDS };
  });

  // Host validates a token presented by a connecting client.
  // Caller must be authenticated AS the host whose ID matches the token's host_device_id.
  app.post('/v1/sessions/validate', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    schema: {
      body: {
        type: 'object',
        required: ['token'],
        properties: { token: { type: 'string' } },
      },
    },
  }, async (req, reply) => {
    if (!req.auth.deviceId) return reply.code(400).send({ error: 'no_device_binding' });

    const db = getDb();
    const now = Math.floor(Date.now() / 1000);
    const session = db.prepare(`
      SELECT s.*, d.name AS client_name FROM session_tokens s
      JOIN devices d ON d.id = s.client_device_id
      WHERE s.token = ? AND s.expires_at > ?
    `).get(req.body.token, now);

    if (!session) return reply.code(404).send({ error: 'invalid_or_expired' });
    if (session.host_device_id !== req.auth.deviceId) {
      return reply.code(403).send({ error: 'wrong_host' });
    }

    return {
      ok: true,
      account_id: session.account_id,
      client_device_id: session.client_device_id,
      client_name: session.client_name,
      expires_at: session.expires_at,
    };
  });

  // Periodic cleanup. Cheap because of the index. Called by a cron, or just
  // call it when a new token is issued (cleanup amortizes).
  app.post('/v1/sessions/cleanup', async () => {
    const db = getDb();
    const now = Math.floor(Date.now() / 1000);
    const r = db.prepare('DELETE FROM session_tokens WHERE expires_at < ?').run(now);
    return { deleted: r.changes };
  });
}
