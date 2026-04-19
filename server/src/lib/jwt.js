import { SignJWT, jwtVerify } from 'jose';

const ISSUER = 'weeber';
const AUDIENCE = 'weeber-app';

let secretKey;

function getKey() {
  if (!secretKey) {
    const raw = process.env.JWT_SECRET;
    if (!raw || raw.length < 32) {
      throw new Error('JWT_SECRET must be set to at least 32 chars');
    }
    secretKey = new TextEncoder().encode(raw);
  }
  return secretKey;
}

// Token TTL:
//   - Account-bound (no `did`): 1 hour. This is a short-lived bearer
//     from /v1/auth/login used until the device registers itself.
//   - Device-bound (has `did`): 30 days. Host machines hold a persistent
//     WebSocket tunnel open 24/7; forcing a rehandshake every hour
//     meant the Mac would drop offline and reconnect forever with an
//     expired token. Device revocation (via DELETE /v1/devices/:id)
//     is the real security boundary — we don't need hourly rotation
//     on top of it.
//
// Every request still re-runs requireActiveSubscription + requireAuth,
// so a paused/canceled subscription blocks API calls regardless of
// token age.
export async function signAccessToken({ accountId, deviceId, plan }) {
  const ttl = deviceId ? '30d' : '1h';
  return await new SignJWT({ plan, did: deviceId })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(accountId)
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(ttl)
    .sign(getKey());
}

export async function verifyAccessToken(token) {
  const { payload } = await jwtVerify(token, getKey(), {
    issuer: ISSUER,
    audience: AUDIENCE,
  });
  return payload;
}
