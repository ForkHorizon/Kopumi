# Kopumi for Android + cross-network sync

## Context
Kopumi is a macOS-only clipboard manager today (SwiftPM, no deps, SQLite store in `Sources/Kopumi/Store.swift`). `PLAN.md` §5 "Later – Sync" asked for an E2E-encrypted sync with mobile, backend deferred. The ask now: an Android app in the **same ecosystem**, and sync **must work when devices are on different internet connections** (phone on mobile data, Mac on home Wi-Fi, different NATs). That rules out LAN-only/mDNS and plain P2P as the primary transport: both devices are rarely online and reachable at once. So we need a small **store-and-forward relay** that only ever sees ciphertext.

The schema is already sync-ready: UUIDv7 `id`, `deviceId`, `updatedAt`, `deleted` tombstones, embeddings local-only (`Store.swift:101-130`).

## Status (2026-11-24)
S1, S2, A1, A2 and A3 are built and tested (see README → Sync and Android). Simplifications made while building:
- **Server-side last-writer-wins**: the envelope carries `ts`/`dev` in the clear so the relay keeps only the newest version per id; without it, a late push of an old version could overwrite a newer one for devices that join later.
- **Kopumi Keyboard is a clip panel, not a full keyboard**: tap a clip to insert, ⌫, ↵, and ⌨ to switch back to the normal keyboard. No in-keyboard search yet.
- **Android shares the pairing link** (share sheet) instead of drawing a QR code; the Mac shows the QR.
- **Address/date detection stays Mac-only**; Android detects URL, email, phone, color, JSON, table, code.
- Titles written by the Mac's on-device model sync to Android.
- **Relay is a self-hosted Node server** (KopumiWeb `server.mjs`, node:sqlite + `ws`) on our VPS instead of a Cloudflare Worker; `MAX_ACCOUNTS` caps how many accounts strangers can claim.
- **Three repos**: Mac (this one, owns `protocol/`), [KopumiAndroind](https://github.com/ForkHorizon/KopumiAndroind), [KopumiWeb](https://github.com/ForkHorizon/KopumiWeb) (relay).
- Not done yet: release signing for Android, phase 2.

## Architecture
```
 Mac (Swift)                 Relay (Cloudflare Worker + Durable Object)          Android (Kotlin)
 Store ─► Sync.swift ──WSS──► one DO per account: SQLite log of encrypted ◄──WSS── SyncClient ─► Room DB
           AES-GCM            records (seq, recordId, ciphertext)                 AES-GCM
```
- **Relay = encrypted mailbox.** Works over any network (both sides make outbound HTTPS/WSS only, no NAT issues), and devices don't need to be online at the same time. Recommended host: Cloudflare Worker + Durable Object with SQLite storage (free tier covers personal use, WebSockets with hibernation). Self-hostable later because the protocol is tiny.
- **Server never sees plaintext or the key.** It stores `(seq INTEGER PK, recordId TEXT UNIQUE, ciphertext BLOB)`; a newer write for the same `recordId` replaces the row and gets a new `seq` (log compacts itself).
- `ponytail:` no LAN/P2P fast path, no FCM push in v1. Add LAN direct only if relay latency bothers anyone; FCM only if "clip appears on Android with the app closed" is required (see Android limits below).

## Crypto & pairing (no new deps on Mac)
- One random 32-byte **account key** per user, created on the Mac at "Enable sync".
- Derived with HKDF-SHA256: `encKey` (AES-256-GCM, record payloads) and `authToken` (sent to relay as bearer; relay stores only `sha256(authToken)`). Account id = random UUID.
- **Pairing by QR**: Mac shows `kopumi://pair?r=<relayURL>&a=<accountId>&k=<base64url key>`; Android scans it. The key moves over the camera only, never the network.
- Mac: `CryptoKit` (`AES.GCM`, `HKDF`). Android: `javax.crypto` AES/GCM + a 20-line HKDF. Both stdlib.
- "Unpair all devices" = rotate key + re-upload (v1 revocation). Per-device keys deferred.
- Key storage: macOS Keychain; Android Keystore-wrapped key in `EncryptedFile`/DataStore.

## Sync protocol (v1)
Record plaintext (JSON, versioned `v:1`): the `clips` row minus local-only columns — `id, createdAt, updatedAt, lastUsedAt, deviceId, kind, sourceApp, text, title, meta, contentHash, pinned, derivedFrom, deleted`.
- **Push**: rows with `updatedAt > lastPushedAt` → `PUT /a/<acct>/records` batch. **Pull**: `GET ?since=<seq>` → apply, store new cursor. **Live**: WebSocket on the DO; server broadcasts `{seq}` hints, client then pulls.
- **Conflict rule**: last-writer-wins on `(updatedAt, deviceId)`. Tombstones win ties.
- **contentHash collision across devices** (same text copied on both before syncing — `contentHash` is `UNIQUE`): keep the row with the smaller `id`, tombstone the other. Must be a self-check case.
- **Never synced**: `sensitive=1` clips, embeddings, OCR text (recomputed per device), and blobs in v1.
- Images/rich blobs: **phase 2** — encrypted to R2, 5 MB cap, referenced from the record.
- `contentHash` stays `"<kind-prefix>:" + sha256hex` (`Watcher.swift:124`); Android must produce byte-identical hashes. Shared test vectors guard this.

## Android app
**Hard platform limit:** since Android 10 an app can read the clipboard only while it's in the foreground or is the active keyboard. No silent background capture like the Mac `Watcher`. The Android design follows from that:
1. **Kopumi Keyboard (IME)** — the Android equivalent of "hold Cmd+V": a clip strip/panel above a basic keyboard, search, tap to insert. As the active IME it can read the clipboard → captures copies made while typing, and pulls from the relay when shown. This is the core of the "same ecosystem" feel.
2. **Share target + Quick Settings tile** "Send clipboard to Kopumi" — capture from any app without switching keyboards.
3. **App UI** (Compose): history list, FTS search, type filters (`type:url` etc.), pin/delete, pairing screen with QR scanner, settings.
4. Writing the clipboard (a clip arriving from Mac → put it on the Android clipboard) works when the app/IME is in the foreground; optional "auto-copy newest remote clip" toggle.

Stack: Kotlin, Jetpack Compose, Room (same columns as Mac `clips`, FTS4 — Android's SQLite doesn't guarantee FTS5), OkHttp WebSocket, WorkManager for periodic sync, CameraX + ML Kit barcode for QR. **minSdk 33 (Android 13+)**, targetSdk = latest. Modern versions only, no old-device workarounds.

Why 33: it's the floor where the modern APIs we need are all present, so there are no version branches in the code:
- `ClipDescription.EXTRA_IS_SENSITIVE` — we mark synced secrets/passwords as sensitive so the system clipboard preview hides them.
- Runtime notification permission and notification channels behave the same on every supported version.
- Photo picker, per-app language, and the system clipboard-edit overlay are available.
- Quick Settings tile with `requestAddTileService` (prompt to add the tile from inside the app).
- Foreground service types (34+ requirement) only matter if we ever add a service; v1 has none.

Clipboard capture is the Android 10+ model everywhere: keyboard, share sheet, QS tile, app in foreground. No background monitor.

Classifier: port `Classifier.swift` rules (URL/email/phone via `Patterns`/`Linkify`, color/JSON/code/table regexes, secret regexes + Luhn).
AI: v1 none on Android. Phase 2: Gemini Nano via ML Kit GenAI where available; otherwise "run action on Mac" later.

## Repo layout
Monorepo, Mac stays at root (no churn):
```
android/            Gradle project (app module only)
relay/              Worker + Durable Object (TypeScript, wrangler)
protocol/           SYNC.md (wire format) + vectors/*.json (classifier, contentHash, crypto, conflict cases)
Sources/Kopumi/Sync.swift   new: crypto, push/pull, WebSocket, pairing QR
```

## Mac changes
- `Store.swift`: migration v2 — `syncState(key, value)` table (cursor, lastPushedAt); `changedSince(ms)`; `applyRemote(record)` with LWW + contentHash-collision rule; bump `updatedAt` on pin/title/delete (check every mutating query does).
- `Sync.swift` (new, ~250 lines): `URLSessionWebSocketTask`, CryptoKit, push on Store change (debounced 1 s), pull on hint/launch/wake.
- `Settings.swift`: "Sync" section — enable, show pairing QR (`CIFilter.qrCodeGenerator`), relay URL, unpair all.
- `Checks.swift`: encrypt/decrypt round-trip against `protocol/vectors`, conflict cases, hash vectors.

## Build order (each ends usable)
1. **S1 Protocol + relay** — `protocol/SYNC.md`, vectors, Worker+DO with push/pull/WS + auth hash. `wrangler dev` + curl script.
2. **S2 Mac sync** — Store migration, Sync.swift, pairing QR. Two Macs (or Mac + CLI test client) sync through the relay.
3. **A1 Android core** — Room store, classifier port passing shared vectors, history UI, share target, QS tile. CI builds and runs unit tests; manual smoke test on API 33 and newest emulators.
4. **A2 Android sync** — QR pairing, crypto, SyncClient, WorkManager. Copy on Mac → appears on phone over mobile data.
5. **A3 Kopumi Keyboard** — IME with clip panel, search, insert, clipboard capture while active.
6. **Phase 2** — images via R2, Gemini Nano actions, optional LAN fast path, FCM push, iOS.

## Risks
- Android clipboard restriction → mitigated by IME + share/tile; set expectations in onboarding.
- Clock skew breaks LWW → clamp: `updatedAt = max(now, lastSeenRemoteUpdatedAt + 1)`.
- Hash drift between Swift/Kotlin (Unicode normalization, line endings) → hash raw UTF-8 bytes as copied, no normalization; vectors include CRLF and emoji.
- Relay abuse → per-account size cap (e.g. 50 MB) and record size cap (256 KB text).
- Lost Mac with only copy of key → Android can show the pairing QR too (any paired device can pair another).

## Verification
- `relay`: `wrangler dev`, scripted push/pull/conflict via curl; `wrangler deploy` to a personal account.
- Mac: `.build/debug/Kopumi --check` covers crypto vectors, conflict rules, migration (per memory: test via `--check`, no synthetic keys on the live desktop).
- Android: JVM unit test reading `protocol/vectors/*.json` (classifier, hash, crypto) — same files as Mac checks.
- End to end: Mac on Wi-Fi, phone on mobile data with Wi-Fi off → copy on Mac, open Kopumi keyboard on phone, clip is there within seconds; delete on phone → gone on Mac; airplane mode on phone, copy on Mac, reconnect → catches up.
