// Abuse detection for one-license-per-person, unlimited-devices model.
//
// We allow a single human to install Weeber on as many devices as they want.
// What we want to catch: one license being SHARED across many people.
//
// A real human's devices cluster geographically (home, office, commute,
// occasional travel). Heuristics:
//
// 1. Geo spread — too many distinct /16 IP subnets active in a 7-day window.
//    A globe-trotter might hit 5–10. A pirate distribution hits hundreds.
//
// 2. Impossible simultaneity — two devices online from very different /16
//    subnets within the same 60-second window. One person can't be in two
//    places at once.
//
// 3. Burst registration — too many fingerprints registered in a short time
//    (e.g., 20 new fingerprints in 1 hour) suggests mass distribution.
//
// 4. Per-IP burst across licenses — one server / VPN endpoint activating
//    many different licenses in a short window.
//
// All thresholds are intentionally permissive. False positives lock out
// real users; we'd rather miss some piracy than block a paying customer.

import { getDb } from '../db/index.js';

const SEVEN_DAYS = 7 * 24 * 3600;
const ONE_HOUR = 3600;
const ONE_MINUTE = 60;

// Returns the /16 prefix of a v4 IP, or the /48 prefix of a v6 IP.
function ipPrefix(ip) {
  if (!ip) return 'unknown';
  if (ip.includes(':')) {
    return ip.split(':').slice(0, 3).join(':');
  }
  return ip.split('.').slice(0, 2).join('.');
}

/**
 * Returns { flagged: bool, reason: string }.
 */
export function checkLicenseAbuse(licenseId, fingerprint, ip) {
  const db = getDb();
  const now = Math.floor(Date.now() / 1000);
  const since7d = now - SEVEN_DAYS;
  const since1h = now - ONE_HOUR;
  const since1m = now - ONE_MINUTE;
  const prefix = ipPrefix(ip);

  // Rule 1: too many distinct /16 prefixes in 7 days. (One person on the move
  // hits maybe 10. A pirate copy spread to a country hits hundreds.)
  const prefixes = db.prepare(`
    SELECT DISTINCT ip FROM activations
    WHERE license_id = ? AND last_heartbeat_at > ? AND revoked_at IS NULL
  `).all(licenseId, since7d).map(r => ipPrefix(r.ip));
  const distinctPrefixes = new Set(prefixes);
  distinctPrefixes.add(prefix);
  if (distinctPrefixes.size > 50) return { flagged: true, reason: 'too_many_geo_subnets' };

  // Rule 2: impossible simultaneity — another activation from a different /16
  // heartbeated within the last minute.
  const recent = db.prepare(`
    SELECT ip FROM activations
    WHERE license_id = ? AND last_heartbeat_at > ? AND revoked_at IS NULL
  `).all(licenseId, since1m);
  const recentPrefixes = new Set(recent.map(r => ipPrefix(r.ip)));
  recentPrefixes.delete(prefix);
  if (recentPrefixes.size >= 3) return { flagged: true, reason: 'impossible_simultaneity' };

  // Rule 3: burst — too many new fingerprints registered in last hour.
  const newFps = db.prepare(`
    SELECT COUNT(DISTINCT hardware_fingerprint) AS c FROM activations
    WHERE license_id = ? AND activated_at > ?
  `).get(licenseId, since1h).c;
  if (newFps > 20) return { flagged: true, reason: 'burst_registration' };

  // Rule 4: this IP is activating many different licenses (a VPN exit shared
  // among pirates, or a script).
  const ipLicenseCount = db.prepare(`
    SELECT COUNT(DISTINCT license_id) AS c FROM activation_attempts
    WHERE ip = ? AND attempted_at > ? AND result = 'ok'
  `).get(ip, since1h).c;
  if (ipLicenseCount > 15) return { flagged: true, reason: 'ip_serves_many_licenses' };

  return { flagged: false };
}

export function recordAttempt({ licenseId, accountId, fingerprint, ip, result }) {
  const db = getDb();
  db.prepare(`
    INSERT INTO activation_attempts (license_id, account_id, hardware_fingerprint, ip, result, attempted_at)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(licenseId ?? null, accountId ?? null, fingerprint ?? null, ip, result, Math.floor(Date.now() / 1000));
}

export function flagLicense(licenseId, reason) {
  const db = getDb();
  const now = Math.floor(Date.now() / 1000);
  db.prepare('UPDATE licenses SET abuse_flagged_at = ? WHERE id = ? AND abuse_flagged_at IS NULL').run(now, licenseId);
  db.prepare('UPDATE activations SET revoked_at = ? WHERE license_id = ? AND revoked_at IS NULL').run(now, licenseId);
  // eslint-disable-next-line no-console
  console.warn(`[abuse] license=${licenseId} flagged reason=${reason} at=${now}`);
}
