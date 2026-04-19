import Fastify from 'fastify';
import cors from '@fastify/cors';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
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

const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '0.0.0.0';
const DB_PATH = process.env.DB_PATH || './data/weeber.db';

mkdirSync(dirname(DB_PATH), { recursive: true });
openDb(DB_PATH);

const app = Fastify({
  logger: { level: process.env.LOG_LEVEL || 'info' },
  trustProxy: true, // we run behind Caddy
  // Default small body limit for JSON APIs. Relay uploads override this per-route.
  bodyLimit: 64 * 1024,
});

await app.register(helmet);
await app.register(cors, { origin: true });
await app.register(rateLimit, {
  max: 60,
  timeWindow: '1 minute',
  // Per-IP. Adjust per route as needed.
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

app.listen({ port: PORT, host: HOST }).then(() => {
  app.log.info(`weeber-server listening on ${HOST}:${PORT}`);
});
