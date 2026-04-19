import { getDb } from '../db/index.js';

export default async function syncRoutes(app) {
  // Host posts a tombstone when a file is deleted-for-everyone.
  // Other clients pull these to evict their local cache.
  app.post('/v1/sync/tombstones', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    schema: {
      body: {
        type: 'object',
        required: ['file_ids'],
        properties: {
          file_ids: { type: 'array', items: { type: 'string' }, maxItems: 500 },
        },
      },
    },
  }, async (req, reply) => {
    if (!req.auth.deviceId) return reply.code(400).send({ error: 'no_device_binding' });
    const db = getDb();
    const now = Math.floor(Date.now() / 1000);
    const stmt = db.prepare(`
      INSERT INTO tombstones (account_id, host_device_id, file_id, deleted_at)
      VALUES (?, ?, ?, ?)
    `);
    const tx = db.transaction((ids) => {
      for (const id of ids) stmt.run(req.auth.accountId, req.auth.deviceId, id, now);
    });
    tx(req.body.file_ids);
    return { ok: true, deleted_at: now };
  });

  // Client polls for tombstones since last sync.
  app.get('/v1/sync/tombstones', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
  }, async (req) => {
    const since = parseInt(req.query.since || '0', 10);
    const hostId = req.query.host_device_id;
    const db = getDb();
    const params = [req.auth.accountId, since];
    let where = 'account_id = ? AND deleted_at > ?';
    if (hostId) {
      where += ' AND host_device_id = ?';
      params.push(hostId);
    }
    const rows = db.prepare(`
      SELECT file_id, host_device_id, deleted_at FROM tombstones
      WHERE ${where}
      ORDER BY deleted_at ASC
      LIMIT 1000
    `).all(...params);
    const max = rows.length ? rows[rows.length - 1].deleted_at : since;
    return { tombstones: rows, cursor: max };
  });

  // Garbage-collect tombstones older than 30 days.
  app.post('/v1/sync/tombstones/gc', async () => {
    const db = getDb();
    const cutoff = Math.floor(Date.now() / 1000) - 30 * 86400;
    const r = db.prepare('DELETE FROM tombstones WHERE deleted_at < ?').run(cutoff);
    return { deleted: r.changes };
  });
}
