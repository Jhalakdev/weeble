# weeber-server

Registry, auth, and billing API for Weeber. Designed to handle 1M users on a 1GB VPS.

## Run locally

```bash
cd server
cp .env.example .env
# edit .env: set JWT_SECRET to 64 random hex chars
npm install
npm run dev
```

Server listens on `http://localhost:3000` by default.

## API surface

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| POST | `/v1/auth/register` | — | Create account; starts 7-day trial |
| POST | `/v1/auth/login` | — | Email + password login → JWT |
| POST | `/v1/auth/pairing/create` | Bearer | Host generates a 60s QR token |
| POST | `/v1/auth/pairing/redeem` | — | New device exchanges QR token → JWT |
| POST | `/v1/devices` | Bearer | Register a host or client device |
| GET | `/v1/devices` | Bearer | List devices on account |
| DELETE | `/v1/devices/:id` | Bearer | Revoke a device |
| POST | `/v1/devices/me/announce` | Bearer + sub | Host posts current public IP+port |
| GET | `/v1/devices/:id/endpoint` | Bearer + sub | Client looks up host endpoint |
| GET | `/v1/billing/status` | Bearer | Get plan + trial state |
| POST | `/v1/billing/stripe/webhook` | Stripe sig | Stripe → us subscription events |

The two endpoints marked **`+ sub`** require an active subscription. They are the gate that makes the system uncrackable: a patched client can fake auth, but cannot fake the JWT signature, so a server with `subscription_status != 'active'` cannot fetch host endpoints.

## Deploying to a 1GB VPS

```
[ Internet ]
     │
     ▼
   Caddy   ◄── automatic Let's Encrypt TLS
     │
     ▼
  Node.js  ◄── this app, single process
     │
     ▼
  SQLite (WAL mode, on local disk)
```

Caddyfile:
```
api.weeber.app {
    reverse_proxy localhost:3000
}
```

Run as a systemd unit. Back up `weeber.db` + WAL files to S3-compatible storage nightly.

## Capacity reasoning

- 1M accounts × ~200 bytes = ~200 MB on disk.
- 1M host endpoints × ~150 bytes = ~150 MB on disk.
- Hourly heartbeats: 1M / 3600 = ~280 req/s. Fastify handles this comfortably.
- IP-change announces (rare, only on restart): negligible.
- Endpoint lookups (per client open): ~1 per session, scales with active sessions, not user count.

Resident RAM expected: ~200 MB. Leaves 800 MB for OS + Caddy + headroom.
