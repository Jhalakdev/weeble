import { verifyAccessToken } from '../lib/jwt.js';
import { getDb } from '../db/index.js';
import { isAccountActive } from '../lib/subscription.js';

export async function requireAuth(req, reply) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    return reply.code(401).send({ error: 'missing_token' });
  }
  const token = header.slice(7);
  try {
    const payload = await verifyAccessToken(token);
    req.auth = { accountId: payload.sub, deviceId: payload.did, plan: payload.plan };
  } catch {
    return reply.code(401).send({ error: 'invalid_token' });
  }
}

// Extra check on top of requireAuth — for endpoints that require an active subscription.
export async function requireActiveSubscription(req, reply) {
  const db = getDb();
  const account = db.prepare('SELECT * FROM accounts WHERE id = ?').get(req.auth.accountId);
  if (!isAccountActive(account)) {
    return reply.code(402).send({ error: 'subscription_inactive' });
  }
  req.account = account;
}
