// In-memory hub of live host WebSocket connections.
//
// The host's Flutter app opens a single persistent outbound WebSocket to
// /v1/tunnel/host. The VPS holds onto it. When ANY relay endpoint needs the
// host (list files / download / upload), it sends a framed request over the
// open socket and awaits a framed response — instead of trying to call into
// the user's home network (which always fails behind NAT without port
// forwarding).
//
// Frame format (JSON over WS text frames, plus binary frames for body bytes):
//
// VPS → host:
//   { type: 'req', id: '<rand>', method: 'GET'|'POST'|'DELETE',
//     path: '/files' | '/files/<id>' | ..., headers: { ... }, hasBody: bool }
//   followed by zero or more binary frames if hasBody=true,
//   followed by { type: 'req-end', id }
//
// host → VPS:
//   { type: 'res', id, status: 200, headers: {...}, hasBody: bool }
//   followed by binary frames,
//   followed by { type: 'res-end', id }
//
// Pings: VPS sends { type: 'ping', t } every 25s; host echoes back.

import { randomBytes } from 'node:crypto';
import { EventEmitter } from 'node:events';

class HostConnection extends EventEmitter {
  constructor({ socket, accountId, deviceId }) {
    super();
    this.socket = socket;
    this.accountId = accountId;
    this.deviceId = deviceId;
    this.openedAt = Date.now();
    this.lastPongAt = Date.now();
    this._pendingByReqId = new Map(); // reqId → { onMessage, onBody, onEnd, onError, timer }
    this._pingInterval = setInterval(() => this._ping(), 25000);

    socket.on('message', (data, isBinary) => this._onFrame(data, isBinary));
    socket.on('close', () => this._teardown('socket_closed'));
    socket.on('error', (e) => this._teardown(`socket_error: ${e.message || e}`));
  }

  _ping() {
    try {
      this.socket.send(JSON.stringify({ type: 'ping', t: Date.now() }));
      // If we don't get a pong/any frame within 60s, declare dead.
      if (Date.now() - this.lastPongAt > 60000) this._teardown('ping_timeout');
    } catch (e) {
      this._teardown(`ping_send_failed: ${e.message}`);
    }
  }

  _teardown(reason) {
    if (this._dead) return;
    this._dead = true;
    clearInterval(this._pingInterval);
    for (const [, p] of this._pendingByReqId) {
      try { p.onError(new Error(`tunnel_closed: ${reason}`)); } catch {}
    }
    this._pendingByReqId.clear();
    this.emit('closed', reason);
    try { this.socket.close(); } catch {}
  }

  _onFrame(data, isBinary) {
    this.lastPongAt = Date.now();
    if (isBinary) {
      // Binary frames are body chunks for the most-recent in-flight response.
      // The msg before this binary frame told us which reqId it belongs to.
      const reqId = this._currentBodyReqId;
      if (!reqId) return;
      const p = this._pendingByReqId.get(reqId);
      if (p) p.onBody(data);
      return;
    }
    let msg;
    try { msg = JSON.parse(data.toString()); } catch { return; }
    if (msg.type === 'pong') return;
    if (msg.type === 'res') {
      const p = this._pendingByReqId.get(msg.id);
      if (!p) return;
      this._currentBodyReqId = msg.hasBody ? msg.id : null;
      p.onMessage(msg);
      if (!msg.hasBody) {
        p.onEnd();
        this._pendingByReqId.delete(msg.id);
        clearTimeout(p.timer);
      }
    } else if (msg.type === 'res-end') {
      const p = this._pendingByReqId.get(msg.id);
      if (!p) return;
      this._currentBodyReqId = null;
      p.onEnd();
      this._pendingByReqId.delete(msg.id);
      clearTimeout(p.timer);
    }
  }

  /// Send a request to the host and stream the response.
  /// Returns a Promise that resolves with { status, headers, bodyStream } where
  /// bodyStream is an async iterable of Buffer chunks.
  async request({ method, path, headers = {}, body = null, timeoutMs = 60000 }) {
    if (this._dead) throw new Error('tunnel_dead');
    const id = randomBytes(8).toString('hex');
    return new Promise((resolve, reject) => {
      let onChunk;
      const chunks = [];
      let resHeader = null;
      let resolved = false;

      const timer = setTimeout(() => {
        if (resolved) return;
        this._pendingByReqId.delete(id);
        reject(new Error('tunnel_request_timeout'));
      }, timeoutMs);

      this._pendingByReqId.set(id, {
        onMessage: (msg) => {
          resHeader = { status: msg.status, headers: msg.headers || {} };
          if (!msg.hasBody) {
            // No body — resolve with empty stream right away
            resolve({ ...resHeader, bodyStream: emptyStream() });
            resolved = true;
          } else {
            // Stream body via async iterator
            const queue = [];
            let resolver = null;
            let ended = false;
            onChunk = (chunk) => {
              if (resolver) { resolver({ value: chunk, done: false }); resolver = null; }
              else queue.push(chunk);
            };
            const stream = (async function* () {
              while (true) {
                if (queue.length) yield queue.shift();
                else if (ended) return;
                else {
                  const r = await new Promise((res) => { resolver = res; });
                  if (r.done) return;
                  yield r.value;
                }
              }
            })();
            const orig = this._pendingByReqId.get(id);
            orig.onBody = (chunk) => onChunk(chunk);
            orig.onEnd = () => {
              ended = true;
              if (resolver) { resolver({ value: null, done: true }); resolver = null; }
            };
            resolve({ ...resHeader, bodyStream: stream });
            resolved = true;
          }
        },
        onBody: () => {},  // populated above when body arrives
        onEnd: () => {},
        onError: (e) => { clearTimeout(timer); if (!resolved) reject(e); },
        timer,
      });

      // Send request envelope
      try {
        this.socket.send(JSON.stringify({
          type: 'req', id, method, path, headers,
          hasBody: body != null,
        }));
        if (body != null) {
          if (Buffer.isBuffer(body)) {
            this.socket.send(body, { binary: true });
          } else {
            this.socket.send(Buffer.from(body), { binary: true });
          }
          this.socket.send(JSON.stringify({ type: 'req-end', id }));
        }
      } catch (e) {
        clearTimeout(timer);
        this._pendingByReqId.delete(id);
        reject(e);
      }
    });
  }
}

async function* emptyStream() { /* empty */ }

class TunnelHub {
  constructor() {
    this._byAccount = new Map(); // accountId → HostConnection
  }

  attach(accountId, deviceId, socket) {
    // Replace any existing connection for this account
    const prior = this._byAccount.get(accountId);
    if (prior) prior._teardown('replaced_by_new_connection');
    const conn = new HostConnection({ socket, accountId, deviceId });
    conn.on('closed', () => {
      // Only clear if this is still the registered conn
      if (this._byAccount.get(accountId) === conn) this._byAccount.delete(accountId);
    });
    this._byAccount.set(accountId, conn);
    return conn;
  }

  get(accountId) {
    return this._byAccount.get(accountId);
  }

  isOnline(accountId) {
    const c = this._byAccount.get(accountId);
    return !!c && !c._dead;
  }

  stats() {
    return { connected: this._byAccount.size };
  }
}

export const tunnelHub = new TunnelHub();
