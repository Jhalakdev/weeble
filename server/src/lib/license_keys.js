// RS256 keypair management for signed license receipts.
//
// Private key stays on the VPS at $LICENSE_KEY_DIR/private.pem (chmod 600).
// Public key is shipped inside the Flutter app binary so clients can verify
// receipts WITHOUT trusting the server. A fake server cannot forge receipts
// without our private key.
//
// Generated automatically on first startup. The same key is used until
// rotated. To rotate: stop the service, move the old private.pem aside,
// restart — but every existing client will reject new receipts until they
// update.

import { generateKeyPairSync, createPrivateKey, createPublicKey } from 'node:crypto';
import { mkdirSync, existsSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { SignJWT, jwtVerify } from 'jose';

const KEY_DIR = process.env.LICENSE_KEY_DIR || '/opt/weeber/data/keys';
const PRIV_PATH = join(KEY_DIR, 'license_private.pem');
const PUB_PATH = join(KEY_DIR, 'license_public.pem');

let _privKey;
let _pubKey;

function ensureKeys() {
  if (_privKey && _pubKey) return;

  if (!existsSync(KEY_DIR)) mkdirSync(KEY_DIR, { recursive: true });

  if (!existsSync(PRIV_PATH)) {
    // First run: generate a fresh keypair.
    const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
    const privPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
    const pubPem = publicKey.export({ type: 'spki', format: 'pem' });
    writeFileSync(PRIV_PATH, privPem);
    chmodSync(PRIV_PATH, 0o600);
    writeFileSync(PUB_PATH, pubPem);
    chmodSync(PUB_PATH, 0o644);
  }

  _privKey = createPrivateKey(readFileSync(PRIV_PATH));
  _pubKey = createPublicKey(readFileSync(PUB_PATH));
}

export function getLicensePublicKeyPem() {
  ensureKeys();
  return readFileSync(PUB_PATH, 'utf8');
}

const ISSUER = 'weeber';
const AUDIENCE = 'weeber-app';

/**
 * Sign an activation receipt. The receipt is what the client stores after
 * activation; it travels with every API call until the next heartbeat.
 *
 * Includes the hardware fingerprint so a stolen receipt can't be replayed
 * on another machine.
 */
export async function signReceipt({ accountId, deviceId, licenseId, fingerprint, plan, ttlSeconds }) {
  ensureKeys();
  return await new SignJWT({
    did: deviceId,
    lid: licenseId,
    fp: fingerprint,
    plan,
  })
    .setProtectedHeader({ alg: 'RS256' })
    .setSubject(accountId)
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(`${ttlSeconds}s`)
    .sign(_privKey);
}

export async function verifyReceipt(receipt) {
  ensureKeys();
  const { payload } = await jwtVerify(receipt, _pubKey, { issuer: ISSUER, audience: AUDIENCE });
  return payload;
}
