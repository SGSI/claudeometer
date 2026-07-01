# Claudeometer Teams — Multi-Account Pooling & Switching

**Status:** Design (approved direction, pending spec review)
**Date:** 2026-07-01
**Author:** brainstormed with the team owner

---

## 1. Problem

A team of ~10 engineers collectively runs ~10 Claude accounts across ~10 laptops.
Think of these as a **shared pool of the team's own accounts**. Usage is uneven:
at any given moment one account is rate-limited (5-hour window exhausted) while
another has plenty of headroom. The team wants to treat the accounts as a pool
and route work to whichever account currently has capacity. Today, doing that is a
manual dance:

1. Engineer A runs `claude` → `/login`, gets an OAuth URL.
2. A sends the URL to colleague B.
3. B authorizes with B's account, sends the resulting code back to A.
4. A pastes the code; A's `Claude Code-credentials` Keychain item now holds B's
   credential blob. A's `claude` CLI burns B's quota until it expires.

This works but is slow, unstructured, has no visibility ("who has headroom right
now?"), no time-boxing, and no record of who used whose account.

**Goal:** turn this into a first-class flow inside Claudeometer — see the whole
team's usage live, request a colleague's quota for a fixed window, have them
approve from their menu bar, and switch automatically, reverting when the window
ends.

---

## 2. Goals / Non-Goals

### Goals
- **Team presence & usage board.** Every enrolled user is visible to all others,
  showing current usage and when their window renews.
- **Request → approve → use.** Request a time-boxed session (default 2h) on one of
  the team's other accounts; the account holder approves/rejects from the menu-bar
  UI; on approve, Claude Code is switched to that account for the window, then
  auto-reverts.
- **Local-first.** Everything runs on each user's Mac. Only usage *numbers* and
  signaling traverse the server; the credential itself only ever moves
  **end-to-end encrypted**.
- **Name-only identity.** No passwords, no email. You type a name; that's you.
- **Safe switching.** Backing up your own credential, time-boxed borrow,
  auto-revert, and clear menu-bar state so you always know whose quota you're on.

### Non-Goals
- Not a zero-trust system. The accounts belong to one trusted team; the tool
  provides convenience, time-boxing, and accountability — not cryptographic
  enforcement against a device that keeps a session token past its window (see §9,
  "session expiry").
- No billing/settlement, no quota accounting beyond display.
- No mobile app, no Windows/Linux client (Claudeometer is macOS-only).
- Not reimplementing Anthropic's OAuth — account acquisition reuses
  `claude /login`.

---

## 3. Identity & Enrollment

- **First launch:** the user types a **display name** (e.g. "Sanket"). That's the
  whole login.
- The app generates a **device keypair** (Curve25519, via CryptoKit) on first
  launch. The private key lives in the Keychain and never leaves the device. The
  public key is registered with the relay alongside the name.
- The relay stores `{ userId (uuid), displayName, publicKey, deviceId, lastSeen }`.
- **Request authentication:** every client→relay call is signed with the device
  private key; the relay verifies the signature against the registered public
  key. This gives password-free integrity — a peer can't trivially impersonate
  another enrolled device over the network.
- **Trust model note:** name-only means anyone who can *reach the relay* and
  enroll could pick any name. This is acceptable for a trusted 10-person team, and
  is mitigated by network-restricting the relay (VPN / IP allowlist / internal
  network). Documented as an accepted limitation (§9).
- Identity persists across app restarts (name + keypair in Keychain). Reinstall =
  re-enroll (new keypair, same or new name); fine at this scale.

---

## 4. Components

### 4.1 Claudeometer client (macOS, Swift — extends the existing app)
- **Credential vault.** Zero or more labeled accounts. Each credential *blob* is
  stored as its own Keychain item (`Claudeometer-account-<id>`); only
  metadata (`id, label, accountEmail, addedAt, isSelf`) lives in an Application
  Support JSON. Never plaintext on disk.
- **Account switcher.** Writes a chosen blob into the `Claude Code-credentials`
  Keychain item after backing up the current one; tracks active-borrow state and
  a `revertAt` timestamp; reverts on timer or on demand.
- **Relay client.** Enrollment, periodic usage POST, board fetch, borrow
  request/approve/reject signaling, encrypted-blob upload/download, request
  signing.
- **Crypto.** CryptoKit sealed-box encrypt/decrypt of credential blobs to a
  peer's public key.
- **UI.** Menu-bar states (own gauge / borrowed badge + countdown), popover team
  board, approve/reject affordance, request sheet.

### 4.2 Relay service (self-hosted, small)
- **Roster:** enrolled users + public keys.
- **Usage board:** latest usage snapshot each user pushes (percentages + reset
  times — **never tokens**).
- **Signaling:** borrow requests / approvals / rejections / revocations,
  delivered to the always-running menu-bar app over a persistent channel
  (WebSocket, long-poll fallback).
- **Encrypted mailbox:** short-TTL store for E2E-encrypted credential blobs
  awaiting pickup. Zero-knowledge — the relay cannot read blob contents.
- **Audit log:** who requested / approved / rejected / revoked, when, and for how
  long.
- **Auth:** verifies request signatures against registered public keys.

### 4.3 Crypto
- Curve25519 device keypairs; CryptoKit `sealedBox` (X25519 + AEAD).
- The lender encrypts their credential blob **to the borrower's public key**; only
  the borrower's private key decrypts. The relay brokers ciphertext it cannot
  open.

---

## 5. Data Model

### Client (per Mac)
```
Account {
  id: UUID
  label: String            // display label, e.g. "Sanket" or "Priya (borrowed)"
  accountEmail: String?    // from Claude profile endpoint, informational only
  isSelf: Bool             // true for the user's own account
  addedAt: Date
  // credential blob stored separately in Keychain item Claudeometer-account-<id>
}

ActiveBorrow {
  lenderUserId: UUID
  lenderName: String
  startedAt: Date
  revertAt: Date
  selfBackupAccountId: UUID   // the Self blob to restore on revert
}

Identity {
  userId: UUID
  displayName: String
  // device private key in Keychain
}
```

### Relay
```
User      { userId, displayName, publicKey, deviceId, lastSeen }
UsagePost { userId, fiveHourPct, sevenDayPct, resetAt, availableToLend: Bool, postedAt }
BorrowRequest {
  id, requesterId, lenderId, hours, status(pending|approved|rejected|expired|revoked),
  createdAt, decidedAt
}
Mailbox   { requestId, recipientId, ciphertext, ttlExpiresAt }   // E2E blob, opaque
AuditEntry{ id, type, requesterId, lenderId, hours, at }
```

---

## 6. Relay API (sketch)

All authenticated via device-key signature.

- `POST /enroll` `{ displayName, publicKey, deviceId }` → `{ userId }`
- `POST /usage` `{ fiveHourPct, sevenDayPct, resetAt, availableToLend }`
- `GET  /board` → `[ { userId, displayName, fiveHourPct, resetAt, availableToLend, lastSeen } ]`
- `WS   /events` → server-push stream of `borrow_request`, `borrow_decision`,
  `borrow_revoked` addressed to this user
- `POST /borrow/request` `{ lenderId, hours }` → `{ requestId }`
- `POST /borrow/decision` `{ requestId, approve: Bool, ciphertext? }`
  (ciphertext present only on approve)
- `GET  /borrow/pickup/{requestId}` → `{ ciphertext }` (borrower fetches, then relay wipes)
- `POST /borrow/revoke` `{ requestId }`
- `GET  /audit` → recent entries (optional; for transparency)

---

## 7. Usage Board (presence)

- Each client reads **its own** live Claude usage (its own token, kept fresh by
  Claude Code) and POSTs `{ fiveHourPct, sevenDayPct, resetAt, availableToLend }`
  every ~30–60s.
- Because each Mac self-reports, the board needs **no cross-account token
  polling or refresh** — a big simplification.
- `availableToLend` is a simple heuristic (e.g. 5-hour usage below a threshold),
  surfaced so requesters know who to ask.
- The popover renders one row per teammate: name, battery, reset countdown, and a
  "lendable" indicator. Rows are tappable to open a borrow request.

---

## 8. Borrow Handshake (the core flow)

Per-request approval, 2h default (presets 30m / 1h / 2h, hard cap 4h).

1. **Request.** Alice taps Priya's row on the board → "Request 2h" → client calls
   `POST /borrow/request`.
2. **Notify.** Relay pushes `borrow_request` to Priya's always-running app. Her
   menu bar shows a badge; the popover shows **"Alice requests 2h — Approve /
   Reject"**. (A local notification also fires.)
3. **Decision.**
   - *Reject:* `POST /borrow/decision {approve:false}`; Alice is told.
   - *Approve:* Priya's app reads her **own** `Claude Code-credentials` blob,
     **seals it to Alice's public key**, and calls
     `POST /borrow/decision {approve:true, ciphertext}`. Relay stores it in the
     mailbox (TTL) and pushes `borrow_decision(approved)` to Alice. Audit entry
     written.
4. **Pickup + switch.** Alice's app fetches the ciphertext (`/borrow/pickup`),
   decrypts with her private key, **backs up her Self blob**, and writes Priya's
   blob into `Claude Code-credentials`. Relay wipes the mailbox entry. Menu bar:
   `⌁ Borrowed · Priya · 1:59 ⏳`.
5. **Use.** Alice's next `claude` launch runs on Priya's quota. (Both Alice and
   Priya now draw from Priya's account — that's the intent; the approve dialog
   makes this explicit to Priya.)
6. **Auto-revert.** At `revertAt` (or on "Switch back"): Alice's app restores her
   Self blob, deletes the borrowed blob from the Keychain, notifies both parties,
   writes audit. **This revert path is the same code used for a purely local
   switch (built first — see §11).**
7. **Revoke.** Priya can `POST /borrow/revoke` any time → pushes to Alice for
   immediate auto-revert, and offers Priya a **"re-login to rotate"** action
   (`claude /login`) for a *hard* invalidation of the shared token.

---

## 9. Security Model & Limitations

- **Tokens are E2E-encrypted.** The relay only ever holds ciphertext addressed to
  a specific public key; it cannot read credentials.
- **Usage numbers only** leave the machine for the board (percentages + reset
  times, not tokens).
- **Credentials never hit disk in plaintext** — Keychain items only.
- **Time-boxed + auto-revert** on the client; menu bar always shows which account
  is active.
- **Session expiry (technical limitation).** These Anthropic endpoints are
  undocumented and offer no server-side token-invalidation call, so a granted
  session ends by the client auto-reverting and wiping the local blob at
  `revertAt`. A *hard* reset of the underlying token (e.g. if a device is lost)
  is done by the account holder re-running `claude /login`, which rotates their
  token. The "revoke" action surfaces this path.
- **Session blob contents.** The transferred blob may include a refresh token, so
  a device that keeps it could refresh beyond the window; auto-revert covers the
  normal path, and re-`/login` is the hard reset. Documented so the behavior is
  explicit.
- **Name-only identity (by design).** No auth beyond a self-chosen name +
  device-key signatures. Network-restrict the relay (VPN / allowlist) so only the
  team's machines can reach it. Right-sized for a trusted 10-person team.

---

## 10. UI / UX

- **Menu bar:**
  - Own account: existing gauge behavior.
  - Borrowed: distinct badge/color + countdown (`Priya · 1:59`).
  - Pending incoming request: attention badge.
- **Popover sections (added):**
  - **Team board:** rows of `name · battery · reset countdown · lendable`.
  - **Incoming request:** "Alice requests 2h" with **Approve / Reject**.
  - **Active borrow:** who you're borrowing from, time left, **Switch back**.
  - **Lent out:** who is currently using your account, time left, **Revoke**.
  - **Accounts / vault:** your saved accounts, switch, re-login.
- **First run:** name-entry sheet (enrollment).
- **Warnings:** switching while a `claude` process is running warns that it takes
  effect on the next launch and won't hijack the running session.

---

## 11. Build Sequencing (milestones within this spec)

Implemented bottom-up so the riskiest local mechanic is proven before any
networking. Each milestone is independently testable; the plan (writing-plans)
will expand these.

- **M1 — Local account switch (foundation, no network).**
  Vault (Keychain slots + metadata JSON); capture the current
  `Claude Code-credentials` as a named account; switch active account with backup
  + 2h auto-revert + "switch back"; menu-bar borrowed badge + countdown; running-
  `claude` warning. **First task is a spike** proving a safe
  read → back-up → write → restore round-trip on the Claude-Code-owned Keychain
  item without corrupting a live session (ACL prompts, exact JSON shape, refresh
  races). *Delivers standalone value: organizes today's manual borrow.*
- **M2 — Relay, enrollment, live board.**
  Name-only enrollment + device keypair; relay service (users, usage board,
  signature auth, WebSocket); client posts own usage on a schedule; popover team
  board with usage + reset + lendable. *No token transfer yet.*
- **M3 — Borrow handshake.**
  Request → push notify → approve/reject in menu bar → E2E seal/upload →
  pickup/decrypt → auto-switch (reuses M1) → auto-revert; lender revoke +
  re-login rotation; audit log.

---

## 12. Testing Strategy

- **M1:** unit tests for vault metadata CRUD, revert logic, and timer/`revertAt`
  math; a **manual integration checklist** for the Keychain round-trip (ACL and
  Claude Code interaction can't be unit-tested); verify a live `claude` session is
  unaffected by a switch until relaunch.
- **M2:** unit tests for enrollment, usage-post serialization, signature
  sign/verify; relay integration tests (enroll → post → board fanout);
  board-rendering checks.
- **M3:** unit tests for seal/open round-trips with real keypairs, request state
  machine (pending→approved→picked-up→reverted / rejected / revoked / expired),
  TTL/mailbox wipe; an end-to-end test across two client instances against a test
  relay (request → approve → decrypt → switch → auto-revert).
- Follow the repo's Swift conventions; target meaningful coverage on the pure
  logic (crypto, state machine, vault, timers) rather than UI/Keychain glue.

---

## 13. Open Questions / Risks / Spikes

1. **Keychain round-trip (M1 spike, highest risk).** Can we reliably back up →
   overwrite → restore the `Claude Code-credentials` item without triggering
   repeated ACL prompts or racing Claude Code's own token refresh? Determines the
   whole switching UX.
2. **Relay hosting & tech stack.** Language/runtime and where it runs (internal
   box? small VM?). Node or Go both fit; decide in the M2 plan. Must be network-
   restricted per §9.
3. **Push channel.** WebSocket vs long-poll for `/events`; the app is always
   running so no APNs needed — confirm in M2.
4. **`availableToLend` heuristic.** Threshold and whether it's user-configurable.
5. **Local multi-gauge in M1.** M1 could show only the active account's gauge
   (self-reported board arrives in M2); confirm we don't need cross-account
   polling/refresh in M1 (current assumption: we don't).
