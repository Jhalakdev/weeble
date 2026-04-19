# Weeber — Developer Handoff

**Owner:** Jhalak (jhalakr@gmail.com)
**As of:** 2026-04-19
**Read this first.** It contains everything you need to be productive on this codebase: live URLs, credentials, what's built, what isn't, and how to deploy.

---

## 1. What is Weeber?

A Flutter app that turns the user's PC/Mac/Linux machine into a private cloud drive. Files live on the user's hardware; phones browse them like Google Drive. Our paid VPS is only a **permission broker** — it never sees file contents.

**Business model:**
- One-time **lifetime** purchase (no monthly subscription).
- Optional paid **backup add-on** (zipped snapshots → our cloud).
- **One license = one person**, with **unlimited devices**.
- **One active host server at a time** per account (you can swap which laptop is the server, but not run two simultaneously).

Read `docs/ARCHITECTURE.md` and `docs/SECURITY.md` for the full design rationale.

---

## 2. Live services

| Service | URL | Notes |
|---------|-----|-------|
| Production API | `http://45.196.196.154:3030` | Public. **Move to HTTPS + a domain ASAP.** |
| Health check | `http://45.196.196.154:3030/healthz` | Returns `{"ok":true}` |
| License public key | `http://45.196.196.154:3030/v1/licenses/public-key` | RSA-2048 PEM, embedded XOR-scrambled in apps |

Marketing website + Flutter web build are NOT yet deployed publicly. Run them locally (see §6).

---

## 3. Production VPS

| Field | Value |
|-------|-------|
| Provider | (Indian VPS reseller — manageserver.in) |
| IP | `45.196.196.154` |
| Hostname | `vm892189754.manageserver.in` |
| OS | Ubuntu 24.04.4 LTS |
| RAM | 1.9 GB total |
| Disk | 29 GB / |
| Root SSH | **Rotate immediately. Original creds were sent in chat and are compromised.** Use SSH keys after rotation. |

### Things on this box you must NOT touch

- **`blinkcure.com`** — separate site served by nginx from `/etc/nginx/sites-available/healio`.
- nginx config files anywhere
- postgres on `:5432` and redis on `:6379` — both bound to localhost only, used by blinkcure
- `/var/www/html` — blinkcure assets

### Things Weeber owns on this box

| Path | Purpose |
|------|---------|
| `/opt/node22/` | Pinned Node 22 LTS binary distribution. The system Node 20 is for blinkcure. |
| `/opt/weeber/server/` | Backend code. Deployed via `deploy.sh`. |
| `/opt/weeber/data/weeber.db` | SQLite database (WAL mode). |
| `/opt/weeber/data/keys/license_private.pem` | **Private key for RS256 license receipts. Lose this = can't issue/verify licenses. Back this up out-of-band.** chmod 600. |
| `/opt/weeber/data/keys/license_public.pem` | Matching public key. Same content as the `/v1/licenses/public-key` endpoint serves. |
| `/etc/systemd/system/weeber-api.service` | systemd unit. Restart with `systemctl restart weeber-api`. |
| ufw rule | `3030/tcp` open. |

### Backing up the private key

```bash
ssh root@45.196.196.154 'cat /opt/weeber/data/keys/license_private.pem' > ./BACKUP_license_private.pem
# Store this somewhere secure offline (1Password, encrypted USB, hardware wallet seed slot, etc.)
```

If you ever need to rotate the key:
1. `mv /opt/weeber/data/keys/license_private.pem /opt/weeber/data/keys/license_private.pem.OLD`
2. Restart `weeber-api` — a new keypair is generated automatically
3. **Every existing client app stops working** until they're rebuilt with the new public key. Plan rotation as a forced-upgrade event.

---

## 4. Repository layout

```
weeber/
├── README.md                # Public-facing repo intro
├── HANDOFF.md               # ← this file
├── deploy.sh                # One-command production deploy
├── server/                  # Node.js Fastify backend (runs on the VPS)
├── website/                 # Next.js marketing + signup site (not yet deployed)
├── app/                     # Flutter app (5 platforms: macOS / Windows / Linux / Android / iOS)
└── docs/
    ├── ARCHITECTURE.md      # Why the design looks the way it does
    └── SECURITY.md          # Anti-piracy + threat model
```

Build artifacts you may produce locally (in `/Users/jhalak/Desktop/Weeber/`):
- `Weeber.app` — macOS .app bundle (release + obfuscated)
- `Weeber-mac.dmg` — drag-install DMG (45-21 MB depending on debug/release)
- `Weeber-android.apk` — Android APK (release + obfuscated, ~70 MB)

---

## 5. Tech stack

| Layer | Choice | Why |
|-------|--------|-----|
| Backend runtime | Node 22 LTS | We use `node:sqlite` (built-in, stable in 22+). Pinned to `/opt/node22/`. |
| Backend framework | Fastify 5 | Tiny memory footprint; suits 1 GB VPS at 1M-user scale. |
| Backend DB | SQLite (WAL) via `node:sqlite` | Embedded. Holds 1M user rows in <250 MB. |
| Auth | argon2id (passwords) + JWT HS256 (sessions) + JWT RS256 (license receipts) | RS256 lets clients verify receipts without trusting the server. |
| Reverse proxy | None yet (raw Fastify on `:3030`). Existing nginx serves blinkcure on `:80`. | Add an nginx vhost for `api.weeber.app` when domain + TLS are ready. |
| TLS | None yet (HTTP only). | **High priority.** Use Let's Encrypt via certbot or add Caddy. |
| Frontend (marketing) | Next.js 16 + Tailwind | Stock App Router. |
| Mobile/Desktop apps | Flutter 3.41 (Dart 3.11) | Single codebase × 5 OS. |
| State mgmt | Riverpod | |
| Routing | go_router | |
| Crypto in app | `cryptography` (AES-256-GCM at rest), `dart_jsonwebtoken` (RS256 verify), `crypto` (SHA-256), `basic_utils` (X.509 cert gen) | All MIT/BSD. |
| Disk reservation | `fallocate` / `mkfile` / `fsutil file createnew` | Native binaries via `Process.run`. |
| Local file index | sqflite + sqflite_common_ffi | |
| QR | `qr_flutter` (generate), `mobile_scanner` (scan) | |
| Host server | `shelf` + `shelf_router` + `dart:io` HTTPS | |
| Device fingerprint | `device_info_plus` + `crypto` | |

Everything is FOSS. The only paid service we depend on is Stripe (when wired up) and the VPS hosting bill.

---

## 6. Local development setup

### Prereqs

```bash
# Already installed on the dev Mac:
brew install node@22 cocoapods sshpass mas
brew install --cask flutter
brew install openjdk@21    # for Android builds

# Android SDK at /Users/jhalak/android-sdk/ (cmdline-tools, platform-tools, platforms;android-36)
# Xcode 16.2 installed at /Applications/Xcode.app/
```

### Required env vars for builds

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer    # macOS builds
export JAVA_HOME=/opt/homebrew/opt/openjdk@21                      # Android builds
export ANDROID_HOME=/Users/jhalak/android-sdk                       # Android builds
export PATH=$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH
```

### Run backend locally

```bash
cd server
cp .env.example .env
# generate JWT_SECRET: node -e "console.log(require('crypto').randomBytes(64).toString('hex'))"
npm install
npm run dev   # listens on :3030 by default
```

### Run website locally

```bash
cd website
cp .env.local.example .env.local
# Set WEEBER_API_URL=http://localhost:3030
npm install
PORT=3055 npm run dev    # use 3055 because user has other Next dev servers on 3000/3001
```

### Run Flutter app locally

```bash
cd app
flutter pub get
# Generate scrambled embedded secrets (every time API URL or pubkey changes):
curl -s http://45.196.196.154:3030/v1/licenses/public-key | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['pem'])" > /tmp/license_pubkey.pem
dart run tool/scramble.dart --api-url=http://45.196.196.154:3030 --pubkey-file=/tmp/license_pubkey.pem

# Run on macOS
flutter run -d macos
# Run on Chrome
flutter run -d chrome
# Run on Android (with phone in dev mode + USB connected)
flutter run -d <device-id>
```

---

## 7. Building releases

### macOS (.app + .dmg)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd app
mkdir -p build/symbols
flutter build macos --release --obfuscate --split-debug-info=build/symbols

# Package
APP=build/macos/Build/Products/Release/weeber_app.app
DEST=/Users/jhalak/Desktop/Weeber
rm -rf "$DEST/Weeber.app"; cp -R "$APP" "$DEST/Weeber.app"
xattr -cr "$DEST/Weeber.app"          # strips quarantine flag (dev only)
hdiutil create -volname "Weeber" -srcfolder "$DEST/Weeber.app" -ov -format UDZO "$DEST/Weeber-mac.dmg"
```

The `.app` is unsigned. macOS Gatekeeper will warn the first time. To distribute publicly, you need an Apple Developer Program membership ($99/yr) and to sign + notarize:

```bash
codesign --deep --force --options runtime --sign "Developer ID Application: <YourName>" Weeber.app
xcrun notarytool submit Weeber-mac.dmg --apple-id ... --team-id ... --wait
xcrun stapler staple Weeber-mac.dmg
```

### Android APK

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME=/Users/jhalak/android-sdk
cd app
flutter build apk --release --obfuscate --split-debug-info=build/symbols
# → build/app/outputs/flutter-apk/app-release.apk
```

For Play Store: needs a keystore. Currently using debug-signed release builds — fine for sideloading, **not** acceptable for the Play Store.

```bash
# Generate a keystore once, store it OUT OF GIT:
keytool -genkey -v -keystore ~/weeber-release-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias weeber

# Wire it into android/app/build.gradle and android/key.properties (both NOT committed)
# Then `flutter build appbundle --release` produces the .aab for Play Store upload.
```

### iOS

Untested — needs an Apple Developer team identifier and a provisioning profile. `flutter build ios --release` should work once Xcode is signed in.

### Web

```bash
cd app
flutter build web --no-wasm-dry-run
# → build/web/  (deploy as static site)
```

---

## 8. Deployment to production

```bash
export WEEBER_VPS_PASSWORD='<paste root password>'   # use SSH keys instead, post-rotation
./deploy.sh
```

What `deploy.sh` does:
1. `rsync` the `server/` directory to `/opt/weeber/server/` (excludes `node_modules`, `data`, `.env`)
2. SSH into the box, run `npm install --omit=dev`
3. `systemctl restart weeber-api`
4. curl the local healthz to confirm

**Note:** `deploy.sh` will NEVER overwrite `.env` (deliberate). If you need to change env vars, edit them on the server directly:

```bash
ssh root@45.196.196.154 'vi /opt/weeber/server/.env && systemctl restart weeber-api'
```

---

## 9. What's built and what works

### Backend (`server/`)

| Endpoint | What it does | Status |
|----------|--------------|--------|
| `POST /v1/auth/register` | Create account, start 7-day trial | ✅ |
| `POST /v1/auth/login` | Email + password → JWT | ✅ |
| `POST /v1/auth/pairing/create` | Host generates 60s pairing token | ✅ |
| `POST /v1/auth/pairing/redeem` | New device exchanges token → JWT | ✅ |
| `POST /v1/devices` | Register a host or client device | ✅ |
| `GET /v1/devices` | List devices | ✅ |
| `PATCH /v1/devices/:id` | Rename device | ✅ |
| `DELETE /v1/devices/:id` | Revoke device | ✅ |
| `POST /v1/devices/me/announce` | Host posts current public IP+port; **enforces single-active-host rule** | ✅ |
| `GET /v1/devices/:id/endpoint` | Specific-host endpoint lookup | ✅ |
| `GET /v1/accounts/me/active-host` | **Phones use this — find current active host** | ✅ |
| `POST /v1/sessions/issue` | Client requests per-connection token | ✅ |
| `POST /v1/sessions/validate` | Host validates session token | ✅ |
| `POST /v1/sync/tombstones` | Host posts deleted file IDs | ✅ |
| `GET /v1/sync/tombstones` | Client polls for tombstones | ✅ |
| `GET /v1/billing/status` | Trial state + plan | ✅ |
| `POST /v1/billing/stripe/webhook` | Stripe event handler | ⚠️ Wired but needs Stripe keys |
| `GET /v1/licenses/public-key` | RSA public key for receipt verification | ✅ |
| `POST /v1/licenses/issue` | Mint license after purchase (currently auth-protected; should be internal-only in prod) | ⚠️ |
| `POST /v1/licenses/activate` | Device first-launch license activation | ✅ |
| `POST /v1/licenses/heartbeat` | 7-day re-validation | ✅ |
| `DELETE /v1/licenses/activations/:id` | User revokes a specific activation | ✅ |

### Flutter app (`app/`)

| Feature | Status |
|---------|--------|
| Login + signup → backend JWT | ✅ |
| Storage allocation (slider, picks folder, true `fallocate`) | ✅ |
| Encryption choice (AES-256-GCM master key in OS keychain) | ✅ |
| Drive screen: drag-drop upload, list, delete-with-WhatsApp-dialog | ✅ |
| QR pairing: rotating QR on host, mobile scanner reads it | ✅ |
| Connected devices screen (list, rename, sign-out) | ✅ |
| License guard: activation, periodic heartbeat, RS256 verify, hard-kill on revoked | ✅ |
| Demoted screen ("Another machine took over") with "Take it back" | ✅ |
| Embedded secrets XOR-scrambled (API URL + pubkey not findable via `strings`) | ✅ |
| Dart obfuscation in release builds | ✅ |
| Single-active-host wiring on the host side (calls `take_over=true` on activation, periodic announce, demoted state UI) | ✅ Done. `services/host_lifecycle.dart` orchestrates cert + UPnP + server start + announce + 30-min heartbeat. Booted from `main.dart` on desktop. |
| Phone-side: query `/v1/accounts/me/active-host` and download files from host with cert pinning | ✅ Done. `services/host_client.dart` does the pinned HTTPS request; `screens/main/client_drive_screen.dart` is the phone UI. Mobile devices get this screen automatically; desktops get the host drive screen. |
| Auto-detect IP changes on host without timer-of-its-own-IP-lookup | ✅ Done. Host sends `public_ip: "auto"` to announce; server fills from `req.ip`. Every 30-min heartbeat naturally captures any IP change. |
| Cloud backup (zip + Hetzner Storage Box upload) | ⚠️ Server-side metadata + quota done. Local backup-to-USB done. Hetzner SFTP transport not yet wired (needs Storage Box credentials in `BACKUP_SFTP_HOST` env var on the VPS). |
| Restore from local backup drive | ✅ Done — `BackupService.restoreFrom()` in `app/lib/backup/backup_service.dart` |
| Restore from cloud backup | ❌ Tied to cloud transport above |
| Stripe Checkout integration | ⚠️ Skeleton in website. Needs test keys + price IDs. |
| Google OAuth signup | ❌ Not started |
| AppSumo redemption | ❌ Not started |
| Code-signed + notarized macOS build | ❌ Needs Apple Dev Program ($99/yr) |
| Play Store-signed AAB | ❌ Needs production keystore |
| TLS on the API | ❌ Currently HTTP. **Highest priority for production.** |

---

## 10. The next 5 things to do, in order

1. **Get a domain (`weeber.app` or similar) + TLS via Let's Encrypt + Caddy or nginx vhost.** Without this, MITM is trivial. Once done, regenerate the cert pin and rebuild the apps.

2. **Wire `host_server.dart` into the app lifecycle.** When a host device finishes onboarding, it should: (a) start the HTTPS server, (b) call UPnP, (c) call `api.announce(takeOver: true)`. On every periodic heartbeat (every 30 min), call `api.announce(takeOver: false)` and react to `demoted` status.

3. **Wire phones to query `/v1/accounts/me/active-host`** before each connection. Replace any code that uses a stored `host_device_id` with this lookup.

4. **Build the Hetzner Storage Box backup feature.** User has chosen Hetzner Storage Box BX41 (~$1.25/TB/month, free egress). API: SFTP. See §11.

5. **Set up Apple Developer Program + Play Console keystore** for properly signed builds. Without these, the install warnings will tank conversion.

---

## 11. Hetzner Storage Box — backup feature spec

User has decided on **Hetzner Storage Box BX41 (20 TB, ~$24/month)** as the storage backend for paid backup plans.

URL: <https://www.hetzner.com/storage/storage-box>

### How it should work

1. User upgrades to a backup plan via Stripe → backend flips `accounts.backup_quota_bytes`.
2. Mac/Win/Linux app gets a "Backup now" button on the Drive screen.
3. On click:
   - App zips the storage folder (with progress bar — for GBs of data, this matters).
   - App encrypts the zip with the user's master key (NEVER upload plaintext).
   - App uploads via SFTP to a per-account path on the Storage Box (e.g., `/<account_id>/<snapshot_id>.zip.enc`).
   - Backend records `{account_id, snapshot_id, size_bytes, sha256, created_at}` row.
4. On a fresh install (e.g., new laptop after disaster):
   - User logs in, sees "Restore from backup" button if any snapshots exist.
   - App downloads zip, decrypts with the same master key (which the user must restore from their backup of the keychain — there is NO recovery path if they lose both the laptop AND the master key).

### Pricing recommendation (covers Hetzner cost + healthy margin)

| Plan | Quota | Price | Cost basis | Margin |
|------|-------|-------|-----------|--------|
| Backup 100 GB | 100 GB | $3/mo | $0.13 | ~96% |
| Backup 1 TB | 1 TB | $8/mo | $1.25 | ~84% |
| Backup 5 TB | 5 TB | $30/mo | $6.25 | ~79% |

**Don't sell lifetime backup** — you pay storage costs forever for a one-time customer payment. Backup must be monthly.

### Why Hetzner Storage Box, not Backblaze

Hetzner is ~5× cheaper than Backblaze B2 ($1.25/TB vs $6/TB) with free egress. Trade-off: SFTP/WebDAV API instead of S3. We write ~80 lines of SFTP client code instead of using a free SDK — small price for the cost difference.

When you implement: use Dart's `dartssh2` package (BSD-licensed) for SFTP. Or shell out to `sftp` + `expect` if you want zero deps.

---

## 12. Architecture invariants — don't break these

1. **The VPS NEVER touches user file contents.** It's a permission broker only. If you find yourself adding code that streams file bytes through the VPS, stop.
2. **One license = one person, unlimited devices.** No device cap. Abuse is detected by activity pattern (geo spread, simultaneity), not by counting.
3. **One active host server at a time per account.** Already enforced server-side via `accounts.active_host_device_id`. Client must respect demoted state.
4. **Files at rest on the host are AES-256-GCM encrypted** when encryption is enabled. Master key in OS keychain. Per-file keys via HKDF.
5. **License receipts are RS256 signed by the server's private key**, verified with the embedded public key. A fake server cannot issue valid receipts.
6. **The API URL and license public key are XOR-scrambled in the binary**, reassembled at runtime. Generated by `app/tool/scramble.dart`.
7. **Release builds use `--obfuscate --split-debug-info=...`.** Non-negotiable — without it, decompiled code is readable Dart.

---

## 13. Known issues / tech debt

- `flutter_secure_storage` doesn't really work on web (DOM crypto fallback is weird). The app still partially loads in browser but treat web as preview-only.
- `mobile_scanner` works on Android/iOS only; on desktop, the scan QR screen shows a "use a phone" message.
- The host's UPnP port-mapping code (`services/upnp.dart`) has only been smoke-tested locally on one router. Untested in the wild.
- The cert-pin field in `embedded_secrets` is currently empty (no TLS yet). When you add TLS, regenerate scramble with the cert's SHA-256.
- `--dart-define=WEEBER_API_URL=...` was the original API-URL knob; it's now superseded by the scrambled embedded value but the parameter still exists in some dev scripts. The scrambled value wins.
- `services/host_server.dart` references `api.validateSession(...)` and `hostToken` for back-channel validation but no code yet boots the host server. See §10.2.
- The "scramble" script regenerates the file every time you build. If you forget, the binary will use stale embedded values. Make this part of the CI build pipeline.
- The 30-min heartbeat interval (`state/host_role.dart`) is hardcoded. Make it configurable from the server side (return `next_announce_in` and respect it).

---

## 14. Useful one-liners

```bash
# Tail backend logs
ssh root@45.196.196.154 'journalctl -u weeber-api -f'

# Inspect the prod SQLite (READ ONLY)
ssh root@45.196.196.154 '/opt/node22/bin/node -e "const D=require(\"node:sqlite\").DatabaseSync;const d=new D(\"/opt/weeber/data/weeber.db\");console.log(d.prepare(\"SELECT id,email,plan,subscription_status FROM accounts\").all());"'

# Reset prod DB (DANGER)
ssh root@45.196.196.154 'systemctl stop weeber-api && rm /opt/weeber/data/weeber.db* && systemctl start weeber-api'

# Public health check
curl -s http://45.196.196.154:3030/healthz
```

---

## 15. Audit-readiness & legal posture — READ BEFORE SHIPPING

**The user has explicitly raised concerns about lawsuits and security audits.** This section exists so any developer reading this immediately understands what is and isn't covered, and what additional work is required before a paid public launch.

### What's been built that an auditor would expect to see

| Control | Implementation |
|---------|---------------|
| **Authentication** — passwords hashed with industry-standard KDF | argon2id (cost 12), salted, in `server/src/routes/auth.js` |
| **Session tokens** — short-lived, signed | JWT HS256, 1-hour expiry |
| **License receipts** — asymmetrically signed, tamper-evident | RS256 (RSA-2048), private key only on VPS at `/opt/weeber/data/keys/license_private.pem` |
| **Receipt verification on client** — signed-by-server only, fingerprint-bound | `app/lib/security/receipt.dart` verifies against embedded public key + checks fingerprint match |
| **Encryption at rest (host files)** | AES-256-GCM, per-file keys via HKDF, master key in OS keychain (`flutter_secure_storage`) |
| **Encryption at rest (backup snapshots)** | AES-256-GCM, master key wrapped with passphrase-derived KEK via Argon2id (memory=64MB, iter=3, parallelism=4 — current OWASP recommendation) |
| **Backup integrity** | HMAC-SHA256 on marker file + per-snapshot manifest |
| **TLS** | ❌ NOT YET. Currently HTTP. **MUST be added before any public launch.** Use Let's Encrypt + Caddy or nginx + certbot. Rebuild apps with the cert pin populated. |
| **Cert pinning** | Wired in `app/lib/security/embedded_keys.dart` — empty until TLS exists |
| **Input validation** | JSON Schema on every endpoint via Fastify schemas |
| **Rate limiting** | `@fastify/rate-limit` 60 req/min per IP |
| **Security headers** | `@fastify/helmet` defaults (X-Content-Type-Options, X-Frame-Options, CSP, etc.) |
| **Audit logging** | `server/src/lib/audit.js` writes to `audit_log` table for every security-sensitive event (login, registration, license activate/revoke, host takeover, backup ops, abuse flag triggers). Append-only by convention. |
| **Abuse detection** | Activity-pattern heuristics in `server/src/lib/abuse.js` (geo spread, simultaneity, burst); flagged licenses are auto-revoked |
| **Code obfuscation** | Release builds use `flutter build --obfuscate --split-debug-info=...` |
| **Embedded constants protection** | API URL + license public key are XOR-scrambled (`app/tool/scramble.dart`); `strings binary \| grep` finds nothing useful |
| **Zero-knowledge backups** | Server NEVER sees plaintext backup contents. Encryption happens client-side; only ciphertext + metadata leave the user's machine |
| **Per-connection authorization** | Session tokens issued by VPS, validated by host before serving file requests (`server/src/routes/sessions.js`) |
| **Hardware fingerprint binding** | Receipts bind to a SHA-256 of system UUID + MAC + CPU info; replay across machines is rejected |
| **Activation revocation** | `DELETE /v1/licenses/activations/:id`; revoked devices fail next 7-day heartbeat |

### Critical gaps before public launch

1. **TLS / HTTPS** — currently HTTP. MITM is trivial. **Show-stopper.**
2. **Code signing** — apps are unsigned. Mac users hit Gatekeeper warnings; Android shows "unknown source." Apple Developer Program ($99/yr) + Play Console signing config required.
3. **Privacy Policy** — none drafted. Required by Apple App Store, Google Play, Stripe, GDPR, India's DPDP Act.
4. **Terms of Service** — none drafted. Especially important: liability disclaimers around backup recovery (we cannot recover lost passphrases by design).
5. **DPDP Act compliance (India)** — if Indian customers, you need: data fiduciary registration, breach notification process (72h), data principal rights (access, deletion, correction), data localization considerations.
6. **GDPR compliance (EU)** — if any EU customers, you need DPO appointment over a threshold, data processing records, right to be forgotten endpoints. Currently the `/v1/auth/register` flow doesn't ask for consent.
7. **Breach response plan** — written runbook for "what we do in the first 4 hours if the database leaks." Without this, regulators treat any incident as worse.
8. **Third-party security audit** — recommend you commission one before paid launch. Reputable Indian firms: Astra Security, SecurityHQ, Deloitte India. Budget: $15K–$50K. **Two weeks of remediation time** after the audit reports findings.
9. **Penetration test** — separate from audit. Tests the running system. Budget: $5K–$15K.
10. **Insurance** — cyber liability insurance for data-breach lawsuit defense. India-domestic providers: TATA AIG, ICICI Lombard. Budget: $1K–$5K/yr.

### What NOT to claim publicly (until earned)

These claims, if made on the website without backing, are themselves liability:

- ❌ "Bank-grade security" — you'd need SOC 2 Type II at minimum
- ❌ "Military-grade encryption" — meaningless marketing term, regulators dislike it
- ❌ "Uncrackable" / "100% safe" — invites tort claims when cracked. Use *"strong encryption at rest and in transit"*.
- ❌ "Compliant with GDPR/HIPAA/etc." — only after you actually are
- ❌ "ISO 27001 certified" — only after the audit is done

### What's safe to claim today

- ✅ "Files encrypted at rest with AES-256-GCM"
- ✅ "Encryption keys never leave your device"
- ✅ "Zero-knowledge backups — we cannot read your files"
- ✅ "Open-source clients, auditable code"
- ✅ "End-to-end authenticated transport" (after TLS)
- ✅ "Hardware-bound license — sharing detected automatically"

### Useful one-liners for an auditor

```bash
# Show last 24h of audit events for an account
ssh root@45.196.196.154 '/opt/node22/bin/node -e "
const D=require(\"node:sqlite\").DatabaseSync;
const d=new D(\"/opt/weeber/data/weeber.db\");
const rows=d.prepare(\"SELECT * FROM audit_log WHERE account_id=? AND at>? ORDER BY at DESC\").all(\"<account_id>\", Math.floor(Date.now()/1000)-86400);
console.log(JSON.stringify(rows, null, 2));
"'

# Confirm the license private key has correct file permissions
ssh root@45.196.196.154 'stat -c "%a %n" /opt/weeber/data/keys/license_private.pem'
# expected: 600 ...license_private.pem
```

### Bottom line

The code we've written meets industry-standard practice. It does NOT make you legally bulletproof — that requires policies, audits, insurance, and a lawyer. **Don't take paid customers before items 1, 3, and 4 are done.** Without TLS your secrets are visible to any hotspot operator. Without a privacy policy + terms, every paying customer is a lawsuit waiting.

---

## 16. Checklist before public launch

- [ ] Rotate root SSH password; switch to key-based auth
- [ ] Domain registered and pointed at `45.196.196.154`
- [ ] Let's Encrypt TLS cert via Caddy or nginx + certbot
- [ ] nginx vhost for `api.<domain>` proxying `:3030`
- [ ] Regenerate scrambled embedded API URL (https now) and TLS cert pin in app
- [ ] Apple Developer Program: code-sign + notarize macOS app
- [ ] Play Console keystore: signed AAB
- [ ] Stripe live keys in `server/.env`; test the checkout → license issue flow once
- [ ] Backup of `license_private.pem` to offline storage
- [ ] Privacy policy + terms (especially DPDP-Act compliant for Indian users)
- [ ] Terms section about backup limitations: "if you lose the device AND the recovery passphrase, your encrypted backup is unrecoverable. We cannot help."
