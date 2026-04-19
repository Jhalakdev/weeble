import Fastify from 'fastify';
import cors from '@fastify/cors';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import websocket from '@fastify/websocket';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

import { openDb } from './db/index.js';
import { requireAuth, requireActiveSubscription } from './middleware/auth.js';
import authRoutes from './routes/auth.js';
import deviceRoutes from './routes/devices.js';
import billingRoutes from './routes/billing.js';
import sessionRoutes from './routes/sessions.js';
import syncRoutes from './routes/sync.js';
import licenseRoutes from './routes/licenses.js';
import backupRoutes from './routes/backup.js';
import shareRoutes from './routes/shares.js';
import relayRoutes from './routes/relay.js';
import tunnelRoutes from './routes/tunnel.js';

const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '0.0.0.0';
const DB_PATH = process.env.DB_PATH || './data/weeber.db';

mkdirSync(dirname(DB_PATH), { recursive: true });
openDb(DB_PATH);

const app = Fastify({
  logger: { level: process.env.LOG_LEVEL || 'info' },
  trustProxy: true,
  bodyLimit: 64 * 1024,
});

// Accept binary uploads. Without this, Fastify defaults to JSON-only and
// rejects every application/octet-stream POST with 415 immediately —
// which is what was killing iPhone uploads at ~12% (the iPhone buffered
// a chunk before the server slammed the connection shut).
// The route-level bodyLimit on /v1/relay/upload (2 GB) overrides the
// global 64 KB, so this only matters for that route.
app.addContentTypeParser('application/octet-stream', { parseAs: 'buffer' }, (_req, body, done) => done(null, body));

await app.register(helmet, { contentSecurityPolicy: false });
await app.register(cors, { origin: true });
await app.register(rateLimit, {
  // The auth-protected relay endpoints get polled by every connected
  // client (files + stats every ~3-4s). Skip rate-limit there — they're
  // already gated by JWT + active subscription. Rate-limit still applies
  // to /v1/auth/*, /v1/billing/*, etc.
  max: 600,
  timeWindow: '1 minute',
  skip: (req) => req.url?.startsWith('/v1/relay/') === true || req.url?.startsWith('/v1/tunnel/') === true,
});
await app.register(websocket, {
  // 64 MB ceiling per WS frame. We were silently dropping any single
  // frame > 16 MB before — which manifested as "phone-uploaded photo
  // shows in list but won't download". The host now also chunks
  // download responses into ≤4 MB frames (see host_tunnel
  // _sendResponse) so even files much larger than this ceiling
  // still flow correctly. The 64 MB is just headroom for any
  // legacy callers + permessage-deflate inflation.
  options: { maxPayload: 64 * 1024 * 1024 },
});

app.decorate('requireAuth', requireAuth);
app.decorate('requireActiveSubscription', requireActiveSubscription);

app.get('/healthz', async () => ({ ok: true }));

await app.register(authRoutes);
await app.register(deviceRoutes);
await app.register(billingRoutes);
await app.register(sessionRoutes);
await app.register(syncRoutes);
await app.register(licenseRoutes);
await app.register(backupRoutes);
await app.register(shareRoutes);
await app.register(relayRoutes);
await app.register(tunnelRoutes);

app.listen({ port: PORT, host: HOST }).then(() => {
  app.log.info(`weeber-server listening on ${HOST}:${PORT}`);
});
