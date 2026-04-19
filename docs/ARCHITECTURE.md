# Weeber Architecture

## The 1M-on-1GB constraint

Every design decision below exists to keep the VPS cheap. We sell software, not bandwidth or storage. The VPS must never become the bottleneck or cost center.

### What the VPS does

1. **Auth** — login, account creation, subscription verification.
2. **Registry** — stores `{device_id → public_ip, port, last_seen}` for every host. Updated when a host's IP changes (startup, ISP renewal, network change).
3. **Lookup** — clients ask "where is host X right now?" and get back an IP+port.
4. **Billing webhooks** — Stripe & AppSumo events update subscription state.

### What the VPS does NOT do

- ❌ Relay file transfers
- ❌ Hold persistent WebSocket connections per user
- ❌ Cache file metadata or thumbnails
- ❌ Broker WebRTC signaling for every connection (see "Connection model" below)

### Memory budget

| Item | RAM |
|------|-----|
| Linux base + sshd | ~120 MB |
| Caddy (TLS) | ~30 MB |
| Node.js + Fastify | ~80 MB |
| SQLite (in-process, page cache) | ~50 MB |
| Headroom | ~720 MB |

SQLite holds 1M user rows + 1M device rows on disk (~200 MB), with negligible resident RAM.

## Connection model

```
   ┌─────────────┐   1. announce IP    ┌─────────────┐
   │  Host (PC)  │ ──────────────────► │   VPS       │
   │             │                     │  (registry) │
   └─────────────┘                     └─────────────┘
                                               ▲
                                               │ 2. lookup IP
                                               │
                                       ┌───────┴─────┐
                                       │   Client    │
                                       │  (phone)    │
                                       └─────┬───────┘
                                             │
                                             │ 3. connect DIRECT
                                             ▼
                                       ┌─────────────┐
                                       │  Host (PC)  │
                                       └─────────────┘
```

### NAT traversal

Most home networks put the host behind NAT. We solve this in three tiers:

1. **UPnP / NAT-PMP** (preferred) — host asks the router to open a port on startup. Works on ~80% of consumer routers.
2. **Manual port forward** (fallback) — wizard in the host app guides the user through their router admin. We detect success.
3. **TURN relay** (paid add-on, v2) — for users on symmetric NAT or carrier-grade NAT (e.g. apartment ISPs). Costs us bandwidth, so it's a separate paid tier or per-GB charge.

**v1 ships with tiers 1 + 2 only.** This keeps our bandwidth cost at $0.

## Why not WebRTC signaling on every connect?

WebRTC's standard model needs a persistent signaling channel between every host and the broker. At 1M hosts, that's 1M open WebSockets — impossible on 1GB.

Instead: hosts expose a real TCP port (via UPnP), and clients hit it directly with a TLS connection. The host runs a tiny HTTPS server (self-signed cert, pinned by client at pairing time). This sidesteps WebRTC entirely for v1.

We can add WebRTC later as a fallback for the 20% UPnP-fail case, but it'll be on-demand (host opens a WebSocket only when notified of an incoming request, then closes it).

## Subscription gating (uncrackable)

The desktop app cannot be patched to bypass payment because the **client app refuses to even discover the host's IP** without a valid subscription token from the VPS.

Flow:
1. Client logs in → gets a short-lived (1 hour) JWT signed by VPS, bound to account + subscription state.
2. Client calls `GET /devices/:id/endpoint` → VPS verifies JWT → returns IP+port only if subscription is active.
3. JWT expires hourly → client must refetch → server checks subscription state again.

A patched client cannot forge the JWT (signed with server's private key). A patched **host** can be reached if you already know its IP, but you can't discover that IP without a valid subscription. So the gate holds.

## Failure modes

| Scenario | Behavior |
|----------|----------|
| VPS down | Existing client↔host connections keep working (P2P). New connections fail until VPS recovers. Already-downloaded files on clients still openable. |
| Host offline | Client sees "Storage offline" banner. Already-downloaded files still openable. |
| Host IP changes mid-session | Client connection drops, client re-fetches endpoint, reconnects. <10s typical. |
| Client loses network | Transfer pauses, resumes from last chunk on reconnect. |
| Subscription lapses | Client can no longer fetch new endpoints. Existing in-flight transfers complete. |
