-- Weeber schema. SQLite. Designed to hold ~1M accounts in <250 MB on disk.

CREATE TABLE IF NOT EXISTS accounts (
  id              TEXT PRIMARY KEY,             -- ULID
  email           TEXT UNIQUE NOT NULL,
  password_hash   TEXT NOT NULL,                -- argon2id
  created_at      INTEGER NOT NULL,             -- unix seconds
  trial_started_at INTEGER NOT NULL,
  -- subscription
  plan            TEXT NOT NULL DEFAULT 'trial',  -- 'trial' | 'monthly' | 'yearly' | 'lifetime'
  subscription_status TEXT NOT NULL DEFAULT 'trialing', -- 'trialing' | 'active' | 'past_due' | 'canceled'
  subscription_renews_at INTEGER,               -- unix seconds; null for lifetime
  stripe_customer_id TEXT,
  appsumo_license_id TEXT,
  -- The single device currently allowed to act as the host (server) for this
  -- account. Only one host at a time. NULL = no host configured yet.
  active_host_device_id TEXT,
  -- Cloud backup add-on. 0 = no plan; otherwise the user's purchased quota.
  backup_quota_bytes INTEGER NOT NULL DEFAULT 0,
  backup_used_bytes INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_accounts_stripe ON accounts(stripe_customer_id);

-- Refresh tokens. Rotating one-shot pattern: every use mints a new
-- token and marks the old as replaced_by. Re-use of an already-
-- replaced token triggers a theft alert and revokes the whole family.
--
-- token_hash = argon2id(refresh_token) so a DB dump never exposes
-- usable bearer tokens.
--
-- device_id is nullable: web-browser sessions aren't device-bound,
-- just account-bound. For those, device_id IS NULL. Native clients
-- (Mac / iOS / Android) have a device row and set device_id so
-- revoking a device also revokes all its refresh tokens.
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id              TEXT PRIMARY KEY,
  account_id      TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id       TEXT REFERENCES devices(id) ON DELETE CASCADE,
  token_hash      TEXT NOT NULL,
  family_id       TEXT NOT NULL,
  created_at      INTEGER NOT NULL,
  expires_at      INTEGER NOT NULL,
  used_at         INTEGER,
  replaced_by     TEXT REFERENCES refresh_tokens(id),
  revoked_at      INTEGER,
  user_agent      TEXT,
  ip              TEXT
);
CREATE INDEX IF NOT EXISTS idx_refresh_family ON refresh_tokens(family_id);
CREATE INDEX IF NOT EXISTS idx_refresh_account ON refresh_tokens(account_id, revoked_at);
CREATE INDEX IF NOT EXISTS idx_refresh_device ON refresh_tokens(device_id);

-- Devices: one row per host or client device linked to an account.
CREATE TABLE IF NOT EXISTS devices (
  id              TEXT PRIMARY KEY,             -- ULID
  account_id      TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind            TEXT NOT NULL,                -- 'host' | 'client'
  name            TEXT NOT NULL,                -- "Jhalak's MacBook"
  platform        TEXT NOT NULL,                -- 'macos' | 'windows' | 'linux' | 'ios' | 'android' | 'web'
  pubkey          TEXT NOT NULL,                -- ed25519 public key (base64)
  created_at      INTEGER NOT NULL,
  last_seen_at    INTEGER NOT NULL,
  revoked_at      INTEGER
);

CREATE INDEX IF NOT EXISTS idx_devices_account ON devices(account_id);

-- Host endpoints: only host devices have rows here. Updated on every IP change.
CREATE TABLE IF NOT EXISTS host_endpoints (
  device_id       TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  public_ip       TEXT NOT NULL,
  port            INTEGER NOT NULL,
  reachability    TEXT NOT NULL,                -- 'upnp' | 'manual' | 'unknown'
  cert_fingerprint TEXT NOT NULL,               -- SHA-256 of host's self-signed TLS cert (pinned by clients)
  updated_at      INTEGER NOT NULL
);

-- Pairing tokens for QR-code device login. Single-use, short-lived.
CREATE TABLE IF NOT EXISTS pairing_tokens (
  token           TEXT PRIMARY KEY,             -- random 24-byte url-safe
  account_id      TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  expires_at      INTEGER NOT NULL,
  consumed_at     INTEGER
);

CREATE INDEX IF NOT EXISTS idx_pairing_expires ON pairing_tokens(expires_at);

-- Session tokens: short-lived (5 min) bearer-style tokens that authorize
-- a specific client to talk to a specific host. The host validates these
-- with us before accepting a connection. THIS is the per-connection
-- subscription gate.
CREATE TABLE IF NOT EXISTS session_tokens (
  token           TEXT PRIMARY KEY,             -- random 32-byte url-safe
  account_id      TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  host_device_id  TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  issued_at       INTEGER NOT NULL,
  expires_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_expires ON session_tokens(expires_at);

-- Tombstones: records of deleted files, used to propagate deletes to
-- offline clients when they reconnect. Cleaned up after 30 days.
CREATE TABLE IF NOT EXISTS tombstones (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id      TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  host_device_id  TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  file_id         TEXT NOT NULL,                -- ULID from the host's file index
  deleted_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tombstones_lookup ON tombstones(host_device_id, deleted_at);

-- Licenses: one row per purchase. Lifetime licenses never expire; subscription
-- licenses get their state from the linked account's subscription_status.
CREATE TABLE IF NOT EXISTS licenses (
  id              TEXT PRIMARY KEY,             -- ULID
  account_id      TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  plan            TEXT NOT NULL,                -- 'monthly' | 'yearly' | 'lifetime'
  -- Devices per license are UNLIMITED. Abuse is detected by activity pattern
  -- (geo spread, simultaneous-from-impossible-distance), not by counting.
  issued_at       INTEGER NOT NULL,
  revoked_at      INTEGER,
  abuse_flagged_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_licenses_account ON licenses(account_id);

-- Activations: one row per (license × hardware fingerprint). Caps device count.
CREATE TABLE IF NOT EXISTS activations (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  -- 'trial' for trial users, otherwise a licenses.id. We deliberately don't
  -- enforce FK to licenses so the 'trial' sentinel works without inserting
  -- a synthetic licenses row per account.
  license_id      TEXT NOT NULL,
  device_id       TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  hardware_fingerprint TEXT NOT NULL,           -- SHA-256 hex of platform-specific machine ID
  ip              TEXT NOT NULL,
  ua              TEXT,                         -- platform string for forensics
  activated_at    INTEGER NOT NULL,
  last_heartbeat_at INTEGER NOT NULL,
  revoked_at      INTEGER
);

CREATE INDEX IF NOT EXISTS idx_activations_license ON activations(license_id);
CREATE INDEX IF NOT EXISTS idx_activations_fingerprint ON activations(license_id, hardware_fingerprint);
CREATE INDEX IF NOT EXISTS idx_activations_device ON activations(device_id);

-- Audit log of activation attempts, used by abuse detection.
CREATE TABLE IF NOT EXISTS activation_attempts (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  license_id      TEXT,
  account_id      TEXT,
  hardware_fingerprint TEXT,
  ip              TEXT NOT NULL,
  result          TEXT NOT NULL,                -- 'ok' | 'cap_exceeded' | 'revoked' | 'abuse_flagged' | 'no_license'
  attempted_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_attempts_license_time ON activation_attempts(license_id, attempted_at);
CREATE INDEX IF NOT EXISTS idx_attempts_ip_time ON activation_attempts(ip, attempted_at);

-- Audit log of every security-sensitive event. Append-only by convention.
-- Used for: incident investigation, GDPR/DPDP-Act subject access requests,
-- demonstrating to auditors that security boundaries are enforced.
CREATE TABLE IF NOT EXISTS audit_log (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id      TEXT,                          -- nullable for unauthed events
  device_id       TEXT,
  ip              TEXT NOT NULL,
  action          TEXT NOT NULL,                 -- 'login.ok' | 'login.fail' | 'register' | 'license.activate.ok' | 'license.activate.cap' | 'host.takeover' | 'host.demoted' | 'device.revoke' | 'pairing.create' | 'pairing.redeem' | 'backup.snapshot.created' | etc.
  detail          TEXT,                          -- JSON-encoded extras
  at              INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_account_time ON audit_log(account_id, at);
CREATE INDEX IF NOT EXISTS idx_audit_action_time ON audit_log(action, at);

-- Cloud backup snapshots stored in Hetzner Storage Box (or any SFTP target).
-- We track only metadata; the bytes are encrypted client-side and we never see
-- the plaintext (zero-knowledge). The wrapped key + KDF params live on the
-- backup destination, not here, so even total compromise of this DB doesn't
-- yield user files.
CREATE TABLE IF NOT EXISTS cloud_snapshots (
  id              TEXT PRIMARY KEY,              -- ULID
  account_id      TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id       TEXT NOT NULL REFERENCES devices(id),
  size_bytes      INTEGER NOT NULL,
  sha256          TEXT NOT NULL,                 -- of the encrypted blob
  remote_path     TEXT NOT NULL,                 -- key in the SFTP target
  created_at      INTEGER NOT NULL,
  deleted_at      INTEGER
);
CREATE INDEX IF NOT EXISTS idx_snapshots_account ON cloud_snapshots(account_id, created_at);

-- Public share links. The token IS the URL path segment; the file lives on
-- the host, not on our VPS. When someone opens the share URL, our VPS
-- looks up the (host_device_id, file_id), pulls bytes from the host over
-- its own HTTPS server (cert-pinned, session-token-authed), and streams to
-- the browser. This DOES use our VPS's bandwidth — the only endpoint that
-- does. Users pay for this via their backup plan quota (not implemented
-- yet; today it's free up to SHARE_SIZE_LIMIT_BYTES).
CREATE TABLE IF NOT EXISTS shares (
  token           TEXT PRIMARY KEY,             -- 24-byte url-safe random
  account_id      TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  host_device_id  TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  file_id         TEXT NOT NULL,                -- ULID in the host's index
  file_name       TEXT NOT NULL,
  mime            TEXT NOT NULL,
  size_bytes      INTEGER,
  password_hash   TEXT,                         -- optional; argon2id if set
  max_downloads   INTEGER,                      -- null = unlimited
  downloads       INTEGER NOT NULL DEFAULT 0,
  created_at      INTEGER NOT NULL,
  expires_at      INTEGER,                      -- null = never
  revoked_at      INTEGER
);

CREATE INDEX IF NOT EXISTS idx_shares_account ON shares(account_id);
CREATE INDEX IF NOT EXISTS idx_shares_expires ON shares(expires_at);
