import https from 'node:https';
import { getDb } from '../db/index.js';
import { urlSafeToken } from '../lib/ids.js';
import { audit, ipOf } from '../lib/audit.js';

const MAX_SHARE_SIZE = 2 * 1024 * 1024 * 1024; // 2 GB cap on free v1 shares

export default async function shareRoutes(app) {
  // Host app generates a share link for a specific file.
  app.post('/v1/shares', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    schema: {
      body: {
        type: 'object',
        required: ['file_id', 'file_name', 'mime'],
        properties: {
          file_id: { type: 'string', minLength: 1, maxLength: 100 },
          file_name: { type: 'string', minLength: 1, maxLength: 400 },
          mime: { type: 'string', maxLength: 100 },
          size_bytes: { type: 'integer', minimum: 0 },
          expires_in_seconds: { type: 'integer', minimum: 60, maximum: 60 * 24 * 3600 },
          max_downloads: { type: 'integer', minimum: 1, maximum: 10000 },
        },
      },
    },
  }, async (req, reply) => {
    if (!req.auth.deviceId) return reply.code(400).send({ error: 'no_device_binding' });
    if (req.body.size_bytes && req.body.size_bytes > MAX_SHARE_SIZE) {
      return reply.code(413).send({ error: 'file_too_large', max_bytes: MAX_SHARE_SIZE });
    }

    const db = getDb();
    const now = Math.floor(Date.now() / 1000);
    const token = urlSafeToken(24);

    // Ensure the device is actually a host on this account.
    const host = db.prepare(`
      SELECT id FROM devices WHERE id = ? AND account_id = ? AND kind = 'host' AND revoked_at IS NULL
    `).get(req.auth.deviceId, req.auth.accountId);
    if (!host) return reply.code(403).send({ error: 'not_a_host' });

    db.prepare(`
      INSERT INTO shares (token, account_id, host_device_id, file_id, file_name, mime, size_bytes, created_at, expires_at, max_downloads)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      token,
      req.auth.accountId,
      req.auth.deviceId,
      req.body.file_id,
      req.body.file_name,
      req.body.mime,
      req.body.size_bytes ?? null,
      now,
      req.body.expires_in_seconds ? now + req.body.expires_in_seconds : null,
      req.body.max_downloads ?? null,
    );

    audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'share.create', detail: { token, file_name: req.body.file_name } });

    const base = process.env.SHARE_PUBLIC_BASE || `http://${req.headers.host}`;
    return {
      token,
      url: `${base}/s/${token}`,
      expires_at: req.body.expires_in_seconds ? now + req.body.expires_in_seconds : null,
    };
  });

  // List this account's active shares.
  app.get('/v1/shares', { preHandler: app.requireAuth }, async (req) => {
    const db = getDb();
    const rows = db.prepare(`
      SELECT token, file_name, mime, size_bytes, created_at, expires_at, max_downloads, downloads
      FROM shares
      WHERE account_id = ? AND revoked_at IS NULL
      ORDER BY created_at DESC LIMIT 200
    `).all(req.auth.accountId);
    const base = process.env.SHARE_PUBLIC_BASE || `http://${req.headers.host}`;
    return { shares: rows.map(r => ({ ...r, url: `${base}/s/${r.token}` })) };
  });

  // Revoke a share.
  app.delete('/v1/shares/:token', { preHandler: app.requireAuth }, async (req, reply) => {
    const db = getDb();
    const r = db.prepare(`
      UPDATE shares SET revoked_at = ?
      WHERE token = ? AND account_id = ? AND revoked_at IS NULL
    `).run(Math.floor(Date.now() / 1000), req.params.token, req.auth.accountId);
    if (r.changes === 0) return reply.code(404).send({ error: 'not_found' });
    audit({ accountId: req.auth.accountId, ip: ipOf(req), action: 'share.revoke', detail: { token: req.params.token } });
    return { ok: true };
  });

  // PUBLIC endpoint — anyone with the link downloads the file here. The VPS
  // acts as a tiny relay: it resolves the share, pulls bytes from the
  // registered host's HTTPS server (cert-pinned), and pipes to the response.
  // This is the ONE place where the VPS is in the bandwidth path.
  app.get('/s/:token', async (req, reply) => {
    const db = getDb();
    const now = Math.floor(Date.now() / 1000);
    const share = db.prepare('SELECT * FROM shares WHERE token = ? AND revoked_at IS NULL').get(req.params.token);

    if (!share) return reply.code(404).type('text/html').send(renderErrorPage('Link not found', 'This share link may have been revoked or never existed.'));
    if (share.expires_at && share.expires_at < now) return reply.code(410).type('text/html').send(renderErrorPage('Link expired', 'This share link has expired.'));
    if (share.max_downloads && share.downloads >= share.max_downloads) {
      return reply.code(410).type('text/html').send(renderErrorPage('Download limit reached', 'This link has been used the maximum number of times.'));
    }

    // HTML preview page on the first hit — "You've been sent a file. Click to download."
    // The download button hits this same URL with ?dl=1.
    if (req.query.dl !== '1') {
      return reply.type('text/html').send(renderSharePage(share));
    }

    // ---- actual download path ----
    const endpoint = db.prepare('SELECT * FROM host_endpoints WHERE device_id = ?').get(share.host_device_id);
    if (!endpoint || now - endpoint.updated_at > 7200) {
      return reply.code(503).type('text/html').send(renderErrorPage('Source is offline', `The device hosting this file appears to be offline. Try again later.`));
    }

    // Issue a session token to talk to the host. We authenticate AS the
    // account, not the person clicking the link — they're anonymous.
    // This is internal-only usage of the sessions table, so skip the normal
    // bearer flow and insert directly.
    const sessionToken = urlSafeToken(32);
    db.prepare(`
      INSERT INTO session_tokens (token, account_id, client_device_id, host_device_id, issued_at, expires_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(sessionToken, share.account_id, share.host_device_id /* loopback */, share.host_device_id, now, now + 300);

    try {
      // Stream from host's HTTPS file server. Self-signed cert is pinned
      // against endpoint.cert_fingerprint.
      await relayFromHost({
        endpoint,
        fileId: share.file_id,
        sessionToken,
        reply,
        fileName: share.file_name,
        mime: share.mime,
      });
      db.prepare('UPDATE shares SET downloads = downloads + 1 WHERE token = ?').run(share.token);
      audit({ accountId: share.account_id, ip: ipOf(req), action: 'share.download', detail: { token: share.token, file_name: share.file_name } });
    } catch (e) {
      req.log.error({ err: e }, 'share relay failed');
      if (!reply.sent) return reply.code(502).type('text/html').send(renderErrorPage('Download failed', 'Could not reach the source device. Please try again.'));
    }
  });
}

async function relayFromHost({ endpoint, fileId, sessionToken, reply, fileName, mime }) {
  return new Promise((resolve, reject) => {
    // We DO NOT verify the host's TLS cert against a public CA — it's
    // self-signed. Pin by SHA-256 fingerprint captured at announce time.
    const expected = endpoint.cert_fingerprint.replace('sha256:', '').toLowerCase();
    const req = https.request({
      host: endpoint.public_ip,
      port: endpoint.port,
      method: 'GET',
      path: `/files/${encodeURIComponent(fileId)}`,
      headers: { 'x-weeber-session': sessionToken },
      rejectUnauthorized: false, // we do our own pinning
      checkServerIdentity: () => undefined,
    }, (hostRes) => {
      const sock = hostRes.socket;
      const cert = sock?.getPeerCertificate?.(true);
      if (cert && cert.raw) {
        const actual = Buffer.from(require('node:crypto').createHash('sha256').update(cert.raw).digest('hex'));
        if (actual.toString() !== expected) {
          hostRes.destroy();
          return reject(new Error('cert_pin_mismatch'));
        }
      }
      if (hostRes.statusCode !== 200) {
        hostRes.destroy();
        return reject(new Error(`host_status_${hostRes.statusCode}`));
      }
      reply.header('content-type', mime || 'application/octet-stream');
      reply.header('content-disposition', `attachment; filename="${fileName.replace(/"/g, '')}"`);
      if (hostRes.headers['content-length']) reply.header('content-length', hostRes.headers['content-length']);
      reply.send(hostRes);
      hostRes.on('end', resolve);
      hostRes.on('error', reject);
    });
    req.setTimeout(15000, () => { req.destroy(new Error('host_timeout')); });
    req.on('error', reject);
    req.end();
  });
}

function renderSharePage(share) {
  const name = esc(share.file_name);
  const size = share.size_bytes ? formatBytes(share.size_bytes) : 'unknown size';
  const expires = share.expires_at ? new Date(share.expires_at * 1000).toUTCString() : 'never';
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>${name} — shared via Weeber</title>
<style>
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; background:#f5f7fb; color:#1e293b; }
  .wrap { max-width:480px; margin:60px auto; padding:40px 24px; background:white; border-radius:12px; box-shadow:0 1px 3px rgba(15,23,42,0.08),0 12px 40px rgba(15,23,42,0.06); text-align:center; }
  .logo { font-weight:700; font-size:14px; letter-spacing:1px; color:#6366f1; margin-bottom:32px; }
  .icon { width:72px; height:72px; background:#eef2ff; border-radius:16px; display:inline-flex; align-items:center; justify-content:center; font-size:32px; margin-bottom:16px; }
  h1 { font-size:20px; font-weight:600; margin:0 0 8px; word-break:break-word; }
  .meta { color:#64748b; font-size:13px; margin-bottom:28px; }
  .btn { display:inline-block; background:#6366f1; color:white; padding:12px 28px; border-radius:10px; text-decoration:none; font-weight:500; font-size:15px; transition:background 0.15s; }
  .btn:hover { background:#4f46e5; }
  footer { margin-top:32px; font-size:12px; color:#94a3b8; }
  footer a { color:#64748b; }
</style>
</head><body>
<div class="wrap">
  <div class="logo">WEEBER</div>
  <div class="icon">📄</div>
  <h1>${name}</h1>
  <div class="meta">${size} · expires ${expires}</div>
  <a class="btn" href="?dl=1">Download</a>
  <footer>Hosted on a private device. <a href="https://weeber.app">What is Weeber?</a></footer>
</div>
</body></html>`;
}

function renderErrorPage(title, message) {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>${esc(title)} — Weeber</title>
<style>
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; background:#f5f7fb; color:#1e293b; }
  .wrap { max-width:480px; margin:60px auto; padding:40px 24px; background:white; border-radius:12px; box-shadow:0 1px 3px rgba(15,23,42,0.08); text-align:center; }
  .logo { font-weight:700; font-size:14px; letter-spacing:1px; color:#6366f1; margin-bottom:32px; }
  .icon { font-size:48px; margin-bottom:16px; }
  h1 { font-size:20px; font-weight:600; margin:0 0 8px; }
  p { color:#64748b; font-size:14px; line-height:1.5; }
</style>
</head><body>
<div class="wrap">
  <div class="logo">WEEBER</div>
  <div class="icon">⚠️</div>
  <h1>${esc(title)}</h1>
  <p>${esc(message)}</p>
</div>
</body></html>`;
}

function esc(s) { return String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c])); }
function formatBytes(b) {
  if (b < 1024) return `${b} B`;
  const u = ['KB','MB','GB','TB']; let v = b/1024, i = 0;
  while (v >= 1024 && i < u.length-1) { v /= 1024; i++; }
  return `${v.toFixed(1)} ${u[i]}`;
}
