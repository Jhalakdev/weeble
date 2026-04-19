// VPS relay for browser-side uploads/downloads. The browser can't directly
// connect to a self-signed host cert — Chrome refuses even with cert pinning
// (browsers don't expose pinning APIs). So we relay: browser → VPS → host.
// This costs VPS bandwidth but it's the only way to support "upload from
// website" in v1. Mobile apps upload DIRECTLY to the host (host_client.dart).

import https from 'node:https';
import crypto from 'node:crypto';
import { getDb } from '../db/index.js';
import { urlSafeToken } from '../lib/ids.js';
import { audit, ipOf } from '../lib/audit.js';

const UPLOAD_MAX_BYTES = 2 * 1024 * 1024 * 1024; // 2 GB

export default async function relayRoutes(app) {
  // Website calls this to upload a file from the browser to the user's host.
  // Body: raw file bytes. Required query: name + mime.
  app.post('/v1/relay/upload', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    bodyLimit: UPLOAD_MAX_BYTES,
    schema: {
      querystring: {
        type: 'object',
        required: ['name', 'mime'],
        properties: {
          name: { type: 'string', minLength: 1, maxLength: 400 },
          mime: { type: 'string', maxLength: 100 },
        },
      },
    },
  }, async (req, reply) => {
    if (!req.auth.deviceId) return reply.code(400).send({ error: 'no_device_binding' });
    const db = getDb();
    const now = Math.floor(Date.now() / 1000);

    // Find this account's active host.
    const account = db.prepare('SELECT active_host_device_id FROM accounts WHERE id = ?').get(req.auth.accountId);
    if (!account.active_host_device_id) return reply.code(404).send({ error: 'no_active_host' });

    const endpoint = db.prepare('SELECT * FROM host_endpoints WHERE device_id = ?').get(account.active_host_device_id);
    if (!endpoint || now - endpoint.updated_at > 7200) {
      return reply.code(503).send({ error: 'host_offline' });
    }

    // Issue a short-lived session token the host will accept. Insert directly
    // so we don't need to route through /v1/sessions/issue from the VPS itself.
    const sessionToken = urlSafeToken(32);
    db.prepare(`
      INSERT INTO session_tokens (token, account_id, client_device_id, host_device_id, issued_at, expires_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(sessionToken, req.auth.accountId, account.active_host_device_id, account.active_host_device_id, now, now + 300);

    audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'relay.upload.start', detail: { name: req.query.name } });

    try {
      const result = await streamToHost({
        endpoint,
        sessionToken,
        fileName: req.query.name,
        mime: req.query.mime,
        rawRequest: req.raw,
        contentLength: parseInt(req.headers['content-length'] || '0', 10),
      });
      audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'relay.upload.ok', detail: { name: req.query.name, size: result.size } });
      return result;
    } catch (e) {
      req.log.error({ err: e }, 'relay upload failed');
      audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'relay.upload.fail', detail: { name: req.query.name, err: String(e.message || e) } });
      return reply.code(502).send({ error: 'upload_relay_failed', detail: String(e.message || e) });
    }
  });
}

async function streamToHost({ endpoint, sessionToken, fileName, mime, rawRequest, contentLength }) {
  return new Promise((resolve, reject) => {
    const expected = endpoint.cert_fingerprint.replace('sha256:', '').toLowerCase();
    const req = https.request({
      host: endpoint.public_ip,
      port: endpoint.port,
      method: 'POST',
      path: '/files',
      headers: {
        'x-weeber-session': sessionToken,
        'x-file-name': encodeURIComponent(fileName),
        'x-file-mime': mime,
        'content-type': 'application/octet-stream',
        'content-length': contentLength,
      },
      rejectUnauthorized: false,
      checkServerIdentity: () => undefined,
    }, (hostRes) => {
      const sock = hostRes.socket;
      const cert = sock?.getPeerCertificate?.(true);
      if (cert && cert.raw) {
        const actual = crypto.createHash('sha256').update(cert.raw).digest('hex');
        if (actual !== expected) {
          hostRes.destroy();
          return reject(new Error('cert_pin_mismatch'));
        }
      }
      let body = '';
      hostRes.on('data', (c) => body += c);
      hostRes.on('end', () => {
        if (hostRes.statusCode >= 400) return reject(new Error(`host_status_${hostRes.statusCode}`));
        try { resolve(JSON.parse(body)); }
        catch { resolve({ raw: body, statusCode: hostRes.statusCode }); }
      });
      hostRes.on('error', reject);
    });
    req.setTimeout(300000, () => req.destroy(new Error('host_timeout')));
    req.on('error', reject);
    rawRequest.pipe(req);
  });
}
