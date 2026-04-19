# Weeber Security & Anti-Piracy Design

## Threat model

We sell **one-time lifetime licenses**. The product runs entirely on the user's hardware; our VPS is purely a permission broker. The threats we care about:

1. **License sharing** — one buyer hands a copy to 50 friends.
2. **Patched binary** — attacker bypasses subscription check locally.
3. **Fake server** — attacker stands up a server that says "everything's paid" and patches the app to point at it.
4. **MITM** — attacker intercepts our real server traffic and lies in the response.
5. **Re-distribution** — cracked builds posted on torrent / GitHub.

We accept upfront that **no defense is 100%** — Adobe, Microsoft, Apple, and Denuvo all get cracked. Our goal: raise the cost of cracking from "any teenager, 2 hours" to "skilled reverse engineer, 2+ weeks." That kills 99% of casual cracking.

## Defenses — what each one actually stops

### 1. Hardware fingerprint + activity-pattern abuse detection

**Product rule:** one license = one person, with **unlimited devices**. A real human runs Weeber on their phone, tablet, work laptop, home desktop — we don't penalize that.

- Every device captures a stable machine ID (combination of system UUID, primary MAC, CPU info).
- Server records the fingerprint + IP for every activation and heartbeat.
- Instead of capping devices, server runs cheap heuristics on the activity pattern:
  - **Too many distinct /16 IP subnets in 7 days (>50)** → license likely shared across many people
  - **Impossible simultaneity** — devices from 3+ different /16s heartbeating in the same 60 second window → not one human
  - **Burst registration** — >20 new fingerprints in 1 hour → mass distribution
  - **One IP serving many licenses** — >15 licenses activating from the same IP in 1 hour → script / VPN exit / cracked-installer hub
- Any rule trip → license `abuse_flagged_at` is set → all current activations revoked → next heartbeat returns 403 → app stops working

**Stops:** "I bought one and gave the cracked install to a torrent site." Within hours of the first 50 distinct activators, the license is dead and so is every cracked copy.

**Doesn't stop:** A user with 2-3 friends quietly using one license at the same home. Acceptable: that's at-most low single-digit revenue lost per legit license.

### 2. Online activation

- First launch → app collects fingerprint → POST /v1/licenses/activate.
- Server records `(license_id, fingerprint, ip, timestamp)`.
- Returns a signed **activation receipt** (7-day JWT bound to fingerprint).
- App stores the receipt; without it, the app is non-functional.

**Stops:** Offline cracking, "buy once, install everywhere with no internet check."

### 3. 7-day heartbeat

- App checks in every 7 days with its receipt.
- Server checks: license still valid, device not revoked, no abuse flags.
- If any check fails, server returns `revoked` and the app stops working within hours.

**Stops:** "Cracked v1.0 keeps working in 2030." Lets us kill abuse remotely.

### 4. License JWT signed with our private key

- The receipt is a JWT signed with **RS256** using a private key that lives only on our VPS.
- The Flutter app embeds the matching **public key** (~270 bytes).
- App verifies every receipt cryptographically before trusting it.

**Stops:** "Stand up a fake server that returns `subscription: active`." A fake server can return anything, but it can't sign a JWT that verifies against our public key. It would need our private key, which never leaves our VPS.

**Defeated by:** patching the verification call out of the binary entirely (raises crack difficulty from "find a string and replace" to "rewrite verification flow").

### 5. TLS certificate pinning

- App ships with the SHA-256 fingerprint of our VPS's TLS cert.
- HTTP client validates that any TLS connection's cert matches the pin.
- A MITM presenting any other cert (even a valid one from a public CA) is rejected.

**Stops:** DNS hijack, rogue CA, MITM attacks on user networks.

### 6. Encrypted strings (API URL + public key)

- The API URL and embedded public key are stored XOR-scrambled across multiple byte arrays.
- Reassembled at runtime in the first call.
- `strings binary | grep http` returns nothing useful.

**Stops:** Casual reverse engineering. Raises bar from minutes to "find the assembly routine."

### 7. Server-side abuse detection

- Track activations per license: count, IPs, fingerprints, time deltas.
- Heuristics: >10 activations in 24h, >3 distinct IP geolocations in 24h, fingerprint that doesn't match any known platform pattern → auto-flag.
- Flagged license → all device receipts immediately revoked, all 7-day heartbeats start failing.

**Stops:** Mass-distribution of a cracked installer. Even if 1000 people install it, the activations spike triggers the flag.

### 8. Dart code obfuscation

- Build with `flutter build --obfuscate --split-debug-info=...`.
- Class names, method names, field names → mangled. Stack traces become unreadable without our debug-info file.

**Stops:** Static analysis being trivial. The disassembly shows `a()`, `b()`, `c()` instead of `verifyLicense()`, `checkFingerprint()`.

### 9. Code-signing + notarization (production builds)

- Mac `.app` signed with an Apple Developer ID, notarized by Apple.
- Modified binaries fail signature verification → macOS Gatekeeper refuses to launch.
- Same idea for Android via Play App Signing.

**Stops:** Distributing a patched `.dmg` because users will hit a Gatekeeper warning that takes effort to bypass.

**Cost:** $99/year Apple Developer Program. Required before public release.

## What we do NOT do (and why)

- **Server-held encryption keys** — would make our server load-bearing for every file open. Breaks the "your data, your hardware" promise. Lifetime buyers would lose access if we ever shut down.
- **Online-only operation** — same reason. Users expect to access files even if their internet is flaky.
- **Hardware DRM (TPM, Secure Enclave attestation)** — possible on macOS/iOS but adds platform-specific complexity for marginal gain.

## Operational practices

- The server's RS256 private key is generated once and stored in the VPS's filesystem with 0600 perms.
- Backups of the private key live in an offline location (1Password / encrypted USB) — losing it means we can't issue new licenses.
- Cert renewal: when our TLS cert rotates, we ship a new app version with the new pin. Old versions stop working until updated → we keep two pins active during rotation windows.
- Abuse detection thresholds are reviewed monthly based on real false-positive rate.

## What a cracked Weeber would still need

After all defenses, a working crack would require:

1. Reverse-engineer obfuscated Dart code to find the verification flow
2. Patch out the JWT verification (or extract our private key, which can't be done)
3. Patch out the cert-pinning check
4. Patch out the periodic heartbeat
5. Stand up a fake server (or skip server entirely by patching every check)
6. Re-sign the patched binary (Mac) or distribute as unsigned (users hit Gatekeeper)
7. Distribute it and stay ahead of our updates that change pin / public key / verification flow

This is several days of work for a skilled reverse engineer. By the time they finish, we ship v1.1 that breaks their crack. Forever-cat-and-mouse, same as every paid software product.
