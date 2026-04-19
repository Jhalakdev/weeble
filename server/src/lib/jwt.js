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

// Tokens last 1 hour. Clients refresh on demand. This is the subscription gate:
// every refresh re-checks the account's subscription_status server-side.
export async function signAccessToken({ accountId, deviceId, plan }) {
  return await new SignJWT({ plan, did: deviceId })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(accountId)
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt()
    .setExpirationTime('1h')
    .sign(getKey());
}

export async function verifyAccessToken(token) {
  const { payload } = await jwtVerify(token, getKey(), {
    issuer: ISSUER,
    audience: AUDIENCE,
  });
  return payload;
}
