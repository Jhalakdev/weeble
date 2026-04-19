# Weeber

Personal cloud storage. Turns a user's PC/Mac/Linux box into a private NAS that's reachable from any device, with a Google-Drive-like UI. Files transfer **directly** between devices — never through our servers.

## Repo layout

```
weeber/
├── server/      # Registry + auth + billing API. Runs on a tiny VPS. (Node.js + Fastify)
├── website/     # Marketing + signup + Stripe checkout. (Next.js)
├── app/         # Unified host + client app for all 5 platforms. (Flutter)
└── docs/        # Architecture, ops, runbooks
```

## Run everything locally

```bash
# Terminal 1 — backend
cd server && npm install && npm run dev      # → http://localhost:3030

# Terminal 2 — website
cd website && npm install && PORT=3055 npm run dev  # → http://localhost:3055

# Terminal 3 — Flutter app (desktop)
cd app && flutter run -d macos               # or windows / linux
# Or web preview: flutter run -d chrome
```

## Critical constraint

**1 million users must run on a 1GB VPS.** This shapes every design decision:

- Server is a **stateless HTTP registry**, not a persistent message broker.
- Hosts announce their public IP only when it changes (typically on restart).
- Clients fetch the host's IP, then connect **directly** — no traffic through VPS.
- No per-user persistent connections. No per-user server-side state in RAM.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design.

## Licensing of dependencies

All runtime dependencies are free and open source:

| Component | License |
|-----------|---------|
| Node.js | MIT |
| Fastify | MIT |
| better-sqlite3 / SQLite | MIT / Public Domain |
| Caddy (TLS reverse proxy) | Apache 2.0 |
| Flutter (host + client apps) | BSD-3-Clause |
| coturn (optional TURN relay) | BSD-3-Clause |

The only non-FOSS pieces are external **services** — Stripe (payments) and AppSumo (license fulfillment). Both are optional integrations, not embedded code.

## Status

| Component | State |
|-----------|-------|
| Registry/auth server (account + device + endpoint registry, JWT, sub gating) | ✅ working, end-to-end tested |
| Session tokens (per-connection auth, host re-validates with VPS, 5-min cache) | ✅ implemented |
| Tombstone sync (delete-for-everyone propagation across devices) | ✅ implemented |
| Marketing website (landing, signup, login, dashboard, pricing, download stubs) | ✅ working, signup→trial flow tested |
| Stripe checkout integration | ⚠️ wired but needs test API keys to use |
| Flutter app — login/signup, onboarding (storage allocation + encryption), drive UI | ✅ working, analyzes cleanly |
| Disk-space reservation (fallocate / mkfile / fsutil) | ✅ implemented |
| Encryption-at-rest (AES-256-GCM, per-file key via HKDF, master in OS keychain) | ✅ implemented |
| File pipeline: SQLite index, drag-drop upload, list, encrypted store | ✅ implemented |
| QR pairing (host shows rotating QR, mobile scanner redeems) | ✅ implemented |
| Self-signed cert generation + fingerprint pinning | ✅ implemented |
| Host HTTPS server (shelf-based, session-token authed) | ✅ implemented |
| UPnP port mapping (SSDP discover + AddPortMapping) | ✅ implemented (best-effort, depends on router) |
| Connected devices screen (list, rename, sign-out) | ✅ implemented |
| Delete dialog (delete for me / for everyone, WhatsApp-style) | ✅ implemented |
| Subscription gating on every connect | ✅ designed, server-side enforced |
| Mobile platform configs (camera permission for iOS/Android, etc.) | ⚠️ default scaffold only — need Info.plist/AndroidManifest tweaks |
| AppSumo integration | ❌ not started |
| Google OAuth signup | ❌ not started |
| File preview screen (image/text viewer) | ❌ scaffolded only |
| Folder hierarchy / nested navigation | ❌ flat list only |
| Client-side download from host (the consume side of host_server) | ❌ host serves files but no client UI yet wires to it |
