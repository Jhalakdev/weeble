// WebSocket endpoint where the host's Flutter app maintains a persistent
// outbound connection. This is what makes "user behind NAT" reachable —
// the host opens the connection FROM their home network outbound to us
// (every router permits that), and we then send file-list / download /
// upload requests back through that same socket.

import { verifyAccessToken } from '../lib/jwt.js';
import { tunnelHub } from '../lib/tunnel_hub.js';
import { audit } from '../lib/audit.js';

export default async function tunnelRoutes(app) {
  // The Flutter app connects to wss://api.weeber.app/v1/tunnel/host?token=<JWT>
  // (we accept the JWT in a query param because browsers can't set headers on
  // WebSocket handshakes — and even though the host is a desktop app, this
  // keeps the protocol consistent.)
  app.get('/v1/tunnel/host', { websocket: true }, async (socket, req) => {
    const token = req.query.token;
    if (!token) {
      socket.send(JSON.stringify({ type: 'error', error: 'missing_token' }));
      socket.close();
      return;
    }

    let payload;
    try {
      payload = await verifyAccessToken(token);
    } catch {
      socket.send(JSON.stringify({ type: 'error', error: 'invalid_token' }));
      socket.close();
      return;
    }

    if (!payload.did) {
      socket.send(JSON.stringify({ type: 'error', error: 'no_device_binding' }));
      socket.close();
      return;
    }

    const accountId = payload.sub;
    const deviceId = payload.did;

    audit({ accountId, deviceId, ip: req.ip || 'ws', action: 'tunnel.host.attach' });

    const conn = tunnelHub.attach(accountId, deviceId, socket);
    socket.send(JSON.stringify({ type: 'hello', t: Date.now() }));

    conn.on('closed', (reason) => {
      audit({ accountId, deviceId, ip: req.ip || 'ws', action: 'tunnel.host.detach', detail: { reason } });
    });
  });

  // Quick stats endpoint for monitoring
  app.get('/v1/tunnel/_stats', async () => tunnelHub.stats());
}
