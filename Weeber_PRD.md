# Weeber — Product Requirements Document

**Version:** 1.0
**Date:** 2026-04-19
**Owner:** Jhalak (jhalakr@gmail.com)
**Audience:** Engineering team

---

## 1. Product Overview

### 1.1 Concept
Weeber is a **personal cloud storage product** that turns the user's own PC (or any always-on device they own) into a private cloud server. Instead of paying for storage on AWS/Google/iCloud, the user pays only for the **software + connectivity layer** that makes their own hardware behave like a managed cloud.

### 1.2 Value Proposition
- **Own your data.** Files never sit on a third-party server; they live on hardware the user controls.
- **Pay for software, not gigabytes.** Subscription is flat — storage is whatever the user's drive can hold.
- **Works like Google Drive.** Familiar UX (folders, previews, share links) so there is no learning curve.
- **Cross-device.** Phone, tablet, laptop — every screen the user owns can browse and stream files from the home device.

### 1.3 Target Users
- Privacy-conscious individuals
- Photographers / videographers with terabytes of media
- Small teams / families wanting shared private storage
- Users frustrated with recurring cloud-storage bills

---

## 2. System Architecture

### 2.1 High-Level Topology

```
┌──────────────┐                       ┌──────────────┐
│  Host (PC)   │ ◄── WebRTC P2P ────► │  Client App  │
│  Parent      │                       │  (phone/tab) │
└──────┬───────┘                       └──────┬───────┘
       │                                      │
       │      ┌──────────────────────┐        │
       └────► │  Signaling Server    │ ◄──────┘
              │  + Auth + Billing    │
              │  + STUN/TURN         │
              └──────────────────────┘
```

### 2.2 Components

| Component | Purpose | Tech |
|-----------|---------|------|
| **Host App (Parent)** | Runs on the user's always-on device. Indexes files, serves them over WebRTC, registers itself with the signaling server. | Flutter (desktop), native FS access |
| **Client App** | Runs on phones, tablets, secondary laptops. Browses + downloads files from the host. | Flutter (mobile/web/desktop) |
| **Signaling Server** | Brokers WebRTC connections. Holds account/device metadata. Issues short-lived auth tokens. | Node.js / Go + Postgres + Redis |
| **STUN/TURN Server** | NAT traversal for P2P; TURN as fallback relay when direct P2P fails. | coturn (self-hosted) or Twilio/Xirsys |
| **Billing Service** | Stripe + AppSumo fulfillment, subscription lifecycle, license verification. | Stripe API + webhook handler |

### 2.3 Why P2P (WebRTC)
- Files transfer **directly** between host and client → no bandwidth cost on our infra.
- Encrypted by default (DTLS-SRTP).
- TURN relay only kicks in when both peers are behind symmetric NAT (~5–10% of cases) — keeps server costs predictable.

---

## 3. Platform Support

Single Flutter codebase shipping to **6 platforms**:

| Platform | Role | Notes |
|----------|------|-------|
| **Windows** | Host + Client | Primary host target |
| **macOS** | Host + Client | Secondary host target |
| **Linux** | Host + Client | Power users / NAS-style installs |
| **Android** | Client only | Mobile browser / downloader |
| **iOS** | Client only | Mobile browser / downloader |
| **Web** | Client only | Zero-install access from any browser |

**Constraint:** mobile platforms cannot act as host (background limits, no persistent FS access).

---

## 4. Core Features

### 4.1 Onboarding & Pairing

#### 4.1.1 First-time host setup
1. User installs desktop app → signs up with email/password (or Google).
2. App generates a **device keypair** (Ed25519) stored in OS keychain.
3. Device registers with signaling server → receives a stable `device_id`.
4. App scans user-selected folders, builds local index (SQLite).
5. Host enters "online" state — visible to user's other devices.

#### 4.1.2 QR-code login for client devices
- Host displays a **QR code** containing: short-lived pairing token + signaling endpoint + host `device_id`.
- New phone/tablet scans QR → app exchanges token for an account-bound auth token → device is now linked.
- **No password typing on mobile.** Critical for UX.
- QR token expires in 60 seconds and is single-use.

#### 4.1.3 Manual login fallback
- Email + password + 6-digit code (sent to email) — for scenarios where camera scan isn't possible.

### 4.2 File Browsing (Google Drive-like UI)

- **Grid + list views**, toggleable.
- **Thumbnails** for images and videos generated **on the host**, streamed to client on demand.
- **Folder tree** in left sidebar.
- **Search** by name + extension; full-text search out of scope for v1.
- **Sort** by name, date modified, size, type.
- **Breadcrumb** navigation.
- **Right-click / long-press** context menu: Open, Download, Share, Rename, Delete, Move.

### 4.3 File Transfer (P2P)

- All transfers use **WebRTC data channels**.
- **Chunked** (1 MB chunks) with parallel chunks for large files.
- **Resumable** — if connection drops, transfer resumes from last acknowledged chunk.
- **Integrity check** — SHA-256 hash verified on completion.
- **Bandwidth throttling** option on the host (so it doesn't saturate home upload).

### 4.4 File States

Each file on a client device is tracked in one of these states:

| State | Meaning | Storage on client |
|-------|---------|-------------------|
| **Remote** | Listed in index, not downloaded. Thumbnail only. | ~KB (thumbnail cache) |
| **Preview** | Streamed for viewing (image/video/PDF), not persisted. | Temp cache, evicted on LRU |
| **Downloaded** | User explicitly downloaded → kept until user removes. | Full file size |
| **Local-only** | File originated on this client (uploaded), not yet synced to host. | Full file size |

Client UI must clearly indicate state via icon (cloud / cloud-with-arrow / checkmark / phone-icon).

### 4.5 Delete Behavior & Cleanup

- **Delete from host** → file removed from disk on host + removed from index + all clients see it disappear from listing. Downloaded copies on clients are **kept** (user is warned but not forced to delete).
- **Remove from this device** (client-only action) → deletes the local downloaded copy; file remains on host.
- **Auto-cleanup of preview cache** — LRU eviction when cache exceeds user-configured limit (default 2 GB).
- **Trash / recycle bin** — deleted files go to host-side trash for 30 days, then purged. User can empty manually.

### 4.6 Share Links

- User selects file → "Share" → generates a public URL.
- URL format: `https://share.weeber.app/<short-id>`
- Backend resolves short-id → triggers a transfer from host to a temporary share-relay (TURN/CDN) so the recipient (no Weeber account) can download via standard HTTPS.
- **Options per link:** expiry (1h / 1d / 7d / never), password, max download count.
- **Revocable** at any time.
- **Note for v1:** share recipient downloads via a relay — host must be online. (v2: pre-cache to CDN edge.)

### 4.7 Device Management

- Settings screen lists all linked devices: name, OS, last-seen, location (rough geo from IP).
- User can **rename** a device.
- User can **revoke** a device → its auth token is invalidated server-side; device is logged out within 30 seconds.
- **Device limit** tied to subscription tier (see §6).

### 4.8 Auto-Reconnect

- Host's public IP changes (ISP renewed lease, laptop moved networks) → host re-registers with signaling server within 10 seconds.
- Clients holding stale connections get pushed an "endpoint changed" event → silently re-handshake.
- User-visible state: a small "reconnecting..." banner; **no manual action required.**

### 4.9 Host Offline Detection

- Signaling server tracks host heartbeat (every 30s).
- After 90s of missed heartbeats → host marked offline.
- Clients show: "Your storage is offline. Files already downloaded are still available."
- Push notification (opt-in) when host comes back online if user has been waiting.

### 4.10 Upgrades

- App checks signaling server on launch for `min_version` and `latest_version`.
- If installed version < `min_version` → app blocks usage, shows update prompt.
- If installed version < `latest_version` → non-blocking banner "Update available."
- Desktop apps use platform-native update channel (Sparkle on macOS, MSIX on Windows, AppImage update for Linux).
- Mobile updates via App Store / Play Store.

---

## 5. Authentication & Security

### 5.1 Account Auth
- Email/password (bcrypt, cost factor 12).
- Optional: Google sign-in.
- All passwords + tokens transit only over TLS 1.3.

### 5.2 Device Auth
- Each device has a unique keypair generated at install time.
- Public key is registered with the signaling server during pairing.
- Every signaling request signed with device private key → server verifies signature → no bearer-token replay risk.

### 5.3 P2P Encryption
- WebRTC DTLS-SRTP (built-in).
- **Additional layer:** files encrypted with per-session AES-256-GCM key, derived from ECDH between host + client device keys.
- Signaling server **cannot** decrypt file contents even if compromised.

### 5.4 Signaling Server Trust Model
- Server is trusted for: account state, device pairing, billing.
- Server is **not** trusted for: file contents, file metadata (filenames travel encrypted in the P2P payload, not via signaling).

---

## 6. Subscription & Billing

### 6.1 Plans

| Plan | Price | Devices | Features |
|------|-------|---------|----------|
| **Trial** | Free for 7 days | 3 | All features |
| **Monthly** | $X / month | 5 | All features |
| **Yearly** | $Y / year | 5 | All features + 2 mo free |
| **AppSumo Lifetime** | One-time $Z | 10 | All features, lifetime |

(Final pricing to be set before launch.)

### 6.2 Trial Logic (server-side)
- Trial state lives **only on the signaling server**, keyed by account.
- Client cannot extend trial by reinstalling, clock-tampering, or creating fresh local state.
- New email = new trial — handled by email verification + payment-method fingerprint dedup at scale.

### 6.3 License Verification (uncrackable design)

**Threat:** desktop apps are reverse-engineerable; users could patch out license checks.

**Mitigation:**
- **No "is_paid" flag stored on client.** Period.
- Every signaling-server request requires a valid subscription. If the subscription lapses, the server **refuses to issue WebRTC offers/answers**.
- Without server brokerage, peers cannot find each other → app is non-functional.
- Even a fully patched client cannot bypass this because the server simply won't answer.
- **Trade-off:** requires our server to be online for new sessions to start. Existing in-flight transfers continue P2P even if server goes down.

### 6.4 Stripe Integration
- Stripe Checkout for new subscriptions.
- Stripe Customer Portal for cancel / update payment / view invoices.
- Webhooks: `customer.subscription.updated`, `invoice.payment_failed`, `customer.subscription.deleted` → update account state in DB.

### 6.5 AppSumo Integration
- AppSumo sends license codes via their fulfillment API.
- User redeems code in app settings → backend validates with AppSumo → upgrades account to lifetime.
- Code is single-use, tied to one account.

---

## 7. Non-Functional Requirements

### 7.1 Performance
- Cold-start file index for 100k files: < 30 seconds on host.
- Listing a folder of 1k files on client: < 500 ms (cached metadata).
- P2P throughput: should hit 80%+ of the bottleneck link's bandwidth.
- Thumbnail generation: queued, doesn't block UI.

### 7.2 Reliability
- Signaling server SLA: 99.9% uptime target.
- File transfers must be resumable across app restarts.
- No data loss in any single-machine failure scenario (host reboot, client crash mid-transfer).

### 7.3 Privacy
- Filenames, paths, and file contents are **never logged** server-side.
- Server logs limited to: account ID, device ID, connection events, error codes.
- GDPR-compliant data export + account deletion endpoints.

### 7.4 Observability (server-side)
- Structured logs (JSON) → centralized aggregator.
- Metrics: active hosts, active sessions, TURN relay usage %, transfer success rate.
- Error tracking via Sentry.

---

## 8. Out of Scope (v1)

These are explicitly **not** in v1 — listing them so the team doesn't accidentally build them:

- Multi-host federation (one account, multiple host devices acting as a pool)
- Real-time collaborative editing
- Server-side full-text search of file contents
- Mobile-as-host
- E2E encrypted share links to non-Weeber recipients (relay decrypts in v1)
- Versioning / file history beyond the 30-day trash
- Automatic photo/video backup from mobile (planned for v1.1)

---

## 9. Tech Stack Summary

| Layer | Choice | Reason |
|-------|--------|--------|
| App framework | Flutter | Single codebase × 6 platforms |
| Local DB | SQLite (sqflite / drift) | Battle-tested, embedded |
| P2P | WebRTC (`flutter_webrtc`) | Standardized, NAT-friendly |
| Signaling transport | WebSocket (Socket.IO or raw WS) | Bidirectional, low-latency |
| Backend | Node.js (Fastify) or Go | Team familiarity decides |
| DB (server) | PostgreSQL | Relational, transactional billing data |
| Cache (server) | Redis | Pub/sub for signaling, session state |
| TURN | coturn (self-hosted) | Cost control |
| Payments | Stripe + AppSumo | Standard SaaS stack |
| File hashing | SHA-256 (Dart `crypto`) | Integrity checks |

---

## 10. Open Questions

1. **Pricing finalization** — monthly/yearly/lifetime numbers TBD.
2. **TURN bandwidth budget** — need to estimate % of users behind symmetric NAT and provision accordingly.
3. **Mobile background sync** — how aggressive can we be on iOS without the OS killing the app?
4. **Family sharing** — is one account = one host enough for v1, or do we need multi-user-per-account from day one?
5. **Branding** — confirm "Weeber" final name + domain registration.

---

## 11. Milestones (suggested)

| Milestone | Scope | Est. effort |
|-----------|-------|-------------|
| **M1 — Skeleton** | Auth, signaling, host + client pairing, basic file listing | 4 weeks |
| **M2 — Transfer** | WebRTC data channels, chunked transfer, resume, integrity | 4 weeks |
| **M3 — UX polish** | Drive-like UI, thumbnails, search, file states | 3 weeks |
| **M4 — Billing** | Stripe, trial logic, license-via-server-gating | 2 weeks |
| **M5 — Sharing & device mgmt** | Share links, device list, revoke, auto-reconnect | 3 weeks |
| **M6 — Hardening** | Performance, security audit, multi-platform QA, AppSumo integration | 3 weeks |
| **M7 — Beta → Launch** | Closed beta, fix list, store submissions | 3 weeks |

**Total estimate:** ~22 weeks (5–6 months) for full team.

---

## Appendix A — Glossary

- **Host / Parent device** — the always-on machine that stores the files.
- **Client device** — any device used to browse/access files on the host.
- **Signaling server** — our backend service that helps peers find each other.
- **STUN** — protocol to discover a peer's public IP/port.
- **TURN** — relay server used when direct P2P is impossible.
- **Pairing** — the act of linking a new client device to an existing account.
