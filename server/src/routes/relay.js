// VPS relay for browser-side uploads/downloads.
//
// All requests now flow through the persistent WebSocket tunnel that the
// host's Flutter app maintains (see lib/tunnel_hub.js + routes/tunnel.js).
// This means: the user's home router needs ZERO configuration. No port
// forwarding, no UPnP, no Cloudflare account, no extra binary on the user's
// machine. The Mac just opens an outbound connection to our VPS and serves
// requests over it.
//
// Bandwidth flows through us, but that's the only acceptable trade for a
// "next-next-install-login" experience for non-technical users.

import { Buffer } from 'node:buffer';
import { Readable } from 'node:stream';
import { tunnelHub } from '../lib/tunnel_hub.js';
import { audit, ipOf } from '../lib/audit.js';

const UPLOAD_MAX_BYTES = 2 * 1024 * 1024 * 1024; // 2 GB

export default async function relayRoutes(app) {
  // Storage usage on the host (used / allocated bytes + file count).
  // Drives the storage card on phone/web — the host computes this in O(1)
  // via a SUM query in FileIndex.
  app.get('/v1/relay/stats', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
  }, async (req, reply) => {
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });
    try {
      const res = await conn.request({ method: 'GET', path: '/stats' });
      const body = await readAll(res.bodyStream);
      reply.code(res.status);
      reply.header('content-type', 'application/json');
      return reply.send(body);
    } catch (e) {
      return reply.code(502).send({ error: 'stats_failed', detail: String(e.message || e) });
    }
  });

  // Storage history (last 30 daily snapshots) for the chart.
  app.get('/v1/relay/storage-history', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
  }, async (req, reply) => {
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });
    try {
      const res = await conn.request({ method: 'GET', path: '/storage-history' });
      const body = await readAll(res.bodyStream);
      reply.code(res.status);
      reply.header('content-type', 'application/json');
      return reply.send(body);
    } catch (e) {
      return reply.code(502).send({ error: 'history_failed', detail: String(e.message || e) });
    }
  });

  // List files on the user's host.
  app.get('/v1/relay/files', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
  }, async (req, reply) => {
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });
    try {
      const res = await conn.request({ method: 'GET', path: '/files' });
      const body = await readAll(res.bodyStream);
      reply.code(res.status);
      reply.header('content-type', res.headers['content-type'] || 'application/json');
      return reply.send(body);
    } catch (e) {
      req.log.error({ err: e }, 'tunnel list failed');
      return reply.code(502).send({ error: 'list_failed', detail: String(e.message || e) });
    }
  });

  // Download a file from the host.
  app.get('/v1/relay/files/:id', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
  }, async (req, reply) => {
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });
    try {
      const res = await conn.request({ method: 'GET', path: `/files/${encodeURIComponent(req.params.id)}` });
      reply.code(res.status);
      for (const k of ['content-type', 'content-length', 'content-disposition']) {
        if (res.headers[k]) reply.header(k, res.headers[k]);
      }
      return reply.send(Readable.from(res.bodyStream));
    } catch (e) {
      req.log.error({ err: e }, 'tunnel download failed');
      if (!reply.sent) return reply.code(502).send({ error: 'download_failed', detail: String(e.message || e) });
    }
  });

  // Delete a file on the host. Soft-delete (host marks deleted_at; the
  // bytes can be reaped later). Same auth surface as list/download.
  app.delete('/v1/relay/files/:id', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
  }, async (req, reply) => {
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });
    audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'relay.delete.start', detail: { id: req.params.id } });
    try {
      const res = await conn.request({
        method: 'DELETE',
        path: `/files/${encodeURIComponent(req.params.id)}`,
      });
      const body = await readAll(res.bodyStream);
      reply.code(res.status);
      reply.header('content-type', res.headers['content-type'] || 'application/json');
      audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'relay.delete.ok', detail: { id: req.params.id, status: res.status } });
      return reply.send(body);
    } catch (e) {
      req.log.error({ err: e }, 'tunnel delete failed');
      audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'relay.delete.fail', detail: { id: req.params.id, err: String(e.message || e) } });
      return reply.code(502).send({ error: 'delete_failed', detail: String(e.message || e) });
    }
  });

  // Upload a file to the host.
  app.post('/v1/relay/upload', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    bodyLimit: UPLOAD_MAX_BYTES,
    schema: {
      querystring: {
        type: 'object', required: ['name', 'mime'],
        properties: {
          name: { type: 'string', minLength: 1, maxLength: 400 },
          mime: { type: 'string', maxLength: 100 },
        },
      },
    },
  }, async (req, reply) => {
    if (!req.auth.deviceId) return reply.code(400).send({ error: 'no_device_binding' });
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });

    audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'relay.upload.start', detail: { name: req.query.name } });

    try {
      const body = req.body;
      const bodyBuf = Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body) || '');
      const res = await conn.request({
        method: 'POST',
        path: '/files',
        headers: {
          'x-file-name': encodeURIComponent(req.query.name),
          'x-file-mime': req.query.mime,
          'content-type': 'application/octet-stream',
        },
        body: bodyBuf,
        timeoutMs: 5 * 60 * 1000,
      });
      const respBody = await readAll(res.bodyStream);
      reply.code(res.status);
      reply.header('content-type', res.headers['content-type'] || 'application/json');
      audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'relay.upload.ok', detail: { name: req.query.name, size: bodyBuf.length } });
      return reply.send(respBody);
    } catch (e) {
      req.log.error({ err: e }, 'tunnel upload failed');
      audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'relay.upload.fail', detail: { err: String(e.message || e) } });
      return reply.code(502).send({ error: 'upload_failed', detail: String(e.message || e) });
    }
  });
}

async function readAll(asyncIter) {
  const chunks = [];
  for await (const c of asyncIter) chunks.push(c);
  return Buffer.concat(chunks);
}
