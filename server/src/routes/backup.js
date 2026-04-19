import { getDb } from '../db/index.js';
import { ulid } from '../lib/ids.js';
import { audit, ipOf } from '../lib/audit.js';

// Cloud backup metadata routes. The actual bytes go directly from the user's
// host to our SFTP/Hetzner Storage Box — never through this server. We only
// record metadata + enforce quota.
//
// The encrypted blob is uploaded by the host using credentials we hand it
// scoped to a single path (so a compromised host can't list/overwrite other
// users' snapshots). For v1, until we wire per-user SFTP credentials, the
// host gets a one-shot signed upload URL we generate here. Implementation
// of the actual SFTP issuance is in `lib/sftp_credentials.js` (TODO).

export default async function backupRoutes(app) {
  // Reserve a snapshot slot. Returns: snapshot_id + remote_path + (eventually)
  // a scoped SFTP credential. Caller uploads bytes, then calls /commit.
  app.post('/v1/backup/snapshots/reserve', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    schema: {
      body: {
        type: 'object',
        required: ['size_bytes', 'sha256'],
        properties: {
          size_bytes: { type: 'integer', minimum: 1, maximum: 5 * 1024 * 1024 * 1024 * 1024 }, // 5 TB cap
          sha256: { type: 'string', minLength: 64, maxLength: 64 },
        },
      },
    },
  }, async (req, reply) => {
    if (!req.auth.deviceId) return reply.code(400).send({ error: 'no_device_binding' });
    const db = getDb();
    const account = db.prepare('SELECT backup_quota_bytes, backup_used_bytes FROM accounts WHERE id = ?')
      .get(req.auth.accountId);

    if (account.backup_quota_bytes === 0) {
      audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'backup.reserve.no_plan' });
      return reply.code(402).send({ error: 'no_backup_plan' });
    }

    if (account.backup_used_bytes + req.body.size_bytes > account.backup_quota_bytes) {
      audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'backup.reserve.over_quota', detail: { requested: req.body.size_bytes, quota: account.backup_quota_bytes, used: account.backup_used_bytes } });
      return reply.code(403).send({ error: 'over_quota', quota: account.backup_quota_bytes, used: account.backup_used_bytes });
    }

    const id = ulid();
    const remotePath = `${req.auth.accountId}/${id}.bin`;
    db.prepare(`
      INSERT INTO cloud_snapshots (id, account_id, device_id, size_bytes, sha256, remote_path, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).run(id, req.auth.accountId, req.auth.deviceId, req.body.size_bytes, req.body.sha256, remotePath, Math.floor(Date.now() / 1000));

    audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'backup.reserve.ok', detail: { snapshot_id: id, size: req.body.size_bytes } });

    // TODO: when Hetzner Storage Box credentials are configured, issue a
    // scoped, time-limited SFTP credential (or a chunk-upload presigned URL).
    return {
      snapshot_id: id,
      remote_path: remotePath,
      upload_protocol: 'sftp',
      upload_host: process.env.BACKUP_SFTP_HOST || null,
      upload_credential_pending: process.env.BACKUP_SFTP_HOST == null,
    };
  });

  // Mark a snapshot as committed. Server bumps backup_used_bytes.
  app.post('/v1/backup/snapshots/:id/commit', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
    schema: {
      body: {
        type: 'object',
        required: ['actual_size_bytes', 'sha256'],
        properties: {
          actual_size_bytes: { type: 'integer', minimum: 1 },
          sha256: { type: 'string', minLength: 64, maxLength: 64 },
        },
      },
    },
  }, async (req, reply) => {
    const db = getDb();
    const snap = db.prepare('SELECT * FROM cloud_snapshots WHERE id = ? AND account_id = ?')
      .get(req.params.id, req.auth.accountId);
    if (!snap) return reply.code(404).send({ error: 'not_found' });
    if (snap.sha256 !== req.body.sha256) return reply.code(400).send({ error: 'hash_mismatch' });

    db.prepare('UPDATE cloud_snapshots SET size_bytes = ? WHERE id = ?').run(req.body.actual_size_bytes, snap.id);
    db.prepare('UPDATE accounts SET backup_used_bytes = backup_used_bytes + ? WHERE id = ?')
      .run(req.body.actual_size_bytes - snap.size_bytes, req.auth.accountId);

    audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'backup.commit', detail: { snapshot_id: snap.id, size: req.body.actual_size_bytes } });
    return { ok: true };
  });

  // List snapshots. Used by the restore flow on a fresh device.
  app.get('/v1/backup/snapshots', {
    preHandler: [app.requireAuth, app.requireActiveSubscription],
  }, async (req) => {
    const db = getDb();
    const rows = db.prepare(`
      SELECT id, size_bytes, sha256, remote_path, created_at FROM cloud_snapshots
      WHERE account_id = ? AND deleted_at IS NULL
      ORDER BY created_at DESC LIMIT 100
    `).all(req.auth.accountId);
    const account = db.prepare('SELECT backup_quota_bytes, backup_used_bytes FROM accounts WHERE id = ?')
      .get(req.auth.accountId);
    return { snapshots: rows, quota_bytes: account.backup_quota_bytes, used_bytes: account.backup_used_bytes };
  });

  // Soft-delete a snapshot. Bytes on the SFTP target are removed by a
  // scheduled cleaner (TODO).
  app.delete('/v1/backup/snapshots/:id', {
    preHandler: app.requireAuth,
  }, async (req, reply) => {
    const db = getDb();
    const now = Math.floor(Date.now() / 1000);
    const snap = db.prepare('SELECT size_bytes FROM cloud_snapshots WHERE id = ? AND account_id = ? AND deleted_at IS NULL')
      .get(req.params.id, req.auth.accountId);
    if (!snap) return reply.code(404).send({ error: 'not_found' });
    db.prepare('UPDATE cloud_snapshots SET deleted_at = ? WHERE id = ?').run(now, req.params.id);
    db.prepare('UPDATE accounts SET backup_used_bytes = MAX(0, backup_used_bytes - ?) WHERE id = ?')
      .run(snap.size_bytes, req.auth.accountId);
    audit({ accountId: req.auth.accountId, deviceId: req.auth.deviceId, ip: ipOf(req), action: 'backup.delete', detail: { snapshot_id: req.params.id } });
    return { ok: true };
  });
}
