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
  // Query: ?include_deleted=true (trash, flat) | ?parent=<folderId> (folder)
  app.get('/v1/relay/files', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
  }, async (req, reply) => {
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });
    const includeDeleted = req.query.include_deleted === 'true' || req.query.include_deleted === '1';
    const parent = typeof req.query.parent === 'string' ? req.query.parent : '';
    const qs = new URLSearchParams();
    if (includeDeleted) qs.set('include_deleted', 'true');
    if (parent) qs.set('parent', parent);
    const path = qs.toString() ? `/files?${qs.toString()}` : '/files';
    try {
      const res = await conn.request({ method: 'GET', path });
      const body = await readAll(res.bodyStream);
      reply.code(res.status);
      reply.header('content-type', res.headers['content-type'] || 'application/json');
      return reply.send(body);
    } catch (e) {
      req.log.error({ err: e }, 'tunnel list failed');
      return reply.code(502).send({ error: 'list_failed', detail: String(e.message || e) });
    }
  });

  // Create a new folder. Body: { name, parent_id? } (parent_id absent = root)
  app.post('/v1/relay/folders', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    schema: {
      body: { type: 'object', required: ['name'], properties: {
        name: { type: 'string', minLength: 1, maxLength: 200 },
        parent_id: { type: 'string', maxLength: 64 },
      }},
    },
  }, async (req, reply) => {
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });
    try {
      const res = await conn.request({
        method: 'POST', path: '/folders',
        headers: { 'content-type': 'application/json' },
        body: Buffer.from(JSON.stringify(req.body)),
      });
      const body = await readAll(res.bodyStream);
      reply.code(res.status);
      reply.header('content-type', 'application/json');
      return reply.send(body);
    } catch (e) {
      return reply.code(502).send({ error: 'create_folder_failed', detail: String(e.message || e) });
    }
  });

  // Copy a file. Body: { parent_id?: <id|null> } — defaults to source's folder.
  app.post('/v1/relay/files/:id/copy', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
  }, async (req, reply) => {
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });
    try {
      const res = await conn.request({
        method: 'POST',
        path: `/files/${encodeURIComponent(req.params.id)}/copy`,
        headers: { 'content-type': 'application/json' },
        body: Buffer.from(JSON.stringify(req.body || {})),
        timeoutMs: 5 * 60 * 1000,
      });
      const body = await readAll(res.bodyStream);
      reply.code(res.status);
      reply.header('content-type', 'application/json');
      return reply.send(body);
    } catch (e) {
      return reply.code(502).send({ error: 'copy_failed', detail: String(e.message || e) });
    }
  });

  // Bulk action: { action: 'delete'|'move'|'restore', ids: [...], parent_id? }
  app.post('/v1/relay/files/bulk', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    schema: {
      body: { type: 'object', required: ['action', 'ids'], properties: {
        action: { type: 'string', enum: ['delete', 'move', 'restore'] },
        ids: { type: 'array', items: { type: 'string' }, maxItems: 1000 },
        parent_id: { type: 'string', maxLength: 64 },
      }},
    },
  }, async (req, reply) => {
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });
    try {
      const res = await conn.request({
        method: 'POST', path: '/files/bulk',
        headers: { 'content-type': 'application/json' },
        body: Buffer.from(JSON.stringify(req.body)),
      });
      const body = await readAll(res.bodyStream);
      reply.code(res.status);
      reply.header('content-type', 'application/json');
      return reply.send(body);
    } catch (e) {
      return reply.code(502).send({ error: 'bulk_failed', detail: String(e.message || e) });
    }
  });

  // Rename a file (and in the future: move via parent_id). Body: { name }.
  app.patch('/v1/relay/files/:id', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    schema: {
      body: { type: 'object', properties: { name: { type: 'string', minLength: 1, maxLength: 400 } } },
    },
  }, async (req, reply) => {
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });
    try {
      const res = await conn.request({
        method: 'PATCH',
        path: `/files/${encodeURIComponent(req.params.id)}`,
        headers: { 'content-type': 'application/json' },
        body: Buffer.from(JSON.stringify(req.body || {})),
      });
      const body = await readAll(res.bodyStream);
      reply.code(res.status);
      reply.header('content-type', 'application/json');
      return reply.send(body);
    } catch (e) {
      return reply.code(502).send({ error: 'rename_failed', detail: String(e.message || e) });
    }
  });

  // Restore a soft-deleted file (Trash → My Drive).
  app.post('/v1/relay/files/:id/restore', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
  }, async (req, reply) => {
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });
    try {
      const res = await conn.request({
        method: 'POST',
        path: `/files/${encodeURIComponent(req.params.id)}/restore`,
      });
      const body = await readAll(res.bodyStream);
      reply.code(res.status);
      reply.header('content-type', 'application/json');
      return reply.send(body);
    } catch (e) {
      return reply.code(502).send({ error: 'restore_failed', detail: String(e.message || e) });
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
    const hard = req.query.hard === 'true' || req.query.hard === '1';
    audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'relay.delete.start', detail: { id: req.params.id, hard } });
    try {
      const res = await conn.request({
        method: 'DELETE',
        path: `/files/${encodeURIComponent(req.params.id)}${hard ? '?hard=true' : ''}`,
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
          parent: { type: 'string', maxLength: 64 },
        },
      },
    },
  }, async (req, reply) => {
    // Drop the old "must be a registered device" check. JWT + active
    // subscription is sufficient auth for relay uploads — browsers
    // (and other lightweight clients) can't easily self-register as
    // devices, and the audit trail is keyed by accountId anyway.
    // deviceId is still recorded when present, just no longer required.
    const conn = tunnelHub.get(req.auth.accountId);
    if (!conn) return reply.code(503).send({ error: 'host_offline' });

    audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId ?? null, ip: ipOf(req), action: 'relay.upload.start', detail: { name: req.query.name } });

    try {
      const body = req.body;
      const bodyBuf = Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body) || '');
      const res = await conn.request({
        method: 'POST',
        path: '/files',
        headers: {
          'x-file-name': encodeURIComponent(req.query.name),
          'x-file-mime': req.query.mime,
          'x-parent-id': req.query.parent || '',
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
