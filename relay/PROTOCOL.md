# Claudeometer Teams — Relay Wire Protocol (M2)

The single source of truth for the client (Swift) ↔ relay (Go) contract. Both
sides MUST implement the signing scheme byte-for-byte identically.

## Keys
- **Signing keypair:** Ed25519 (Swift: `Curve25519.Signing`, Go: `crypto/ed25519`).
- **Encryption keypair:** X25519 (Swift: `Curve25519.KeyAgreement`, Go: n/a in M2 — stored opaque for M3).
- Public keys on the wire: **standard base64 (with padding)** of the raw 32-byte key.
- Private keys never leave the device (stored in the macOS Keychain).

## Request signing (canonical scheme)
Every authenticated request carries these headers:
- `X-User-Id`: the enrolled user's UUID (omitted only on `POST /enroll`).
- `X-Timestamp`: request time, unix **seconds**, decimal string.
- `X-Signature`: standard base64 of the 64-byte Ed25519 signature.

The signed message is the UTF-8 bytes of exactly this string (`\n` = U+000A):
```
<METHOD>\n<PATH>\n<TIMESTAMP>\n<BODY_SHA256_HEX>
```
- `METHOD`: uppercase HTTP method, e.g. `POST`, `GET`.
- `PATH`: request path only, no query string, e.g. `/usage`.
- `TIMESTAMP`: the exact `X-Timestamp` value sent.
- `BODY_SHA256_HEX`: lowercase hex SHA-256 of the raw request body bytes
  (for an empty body, the SHA-256 of the empty string:
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`).

### Verification (relay)
1. Reject if `|now - X-Timestamp| > 300` seconds (replay window).
2. Resolve the signing public key:
   - `POST /enroll`: use `signingPubKey` from the request body (proof of key possession).
   - all others: look up the user by `X-User-Id`; 401 if unknown.
3. Recompute the canonical message and verify `X-Signature` with the public key; 401 on mismatch.

## Endpoints

### `POST /enroll`  (unauthenticated, self-signed)
Body:
```json
{ "displayName": "Sanket", "signingPubKey": "<b64>", "encryptionPubKey": "<b64>", "deviceId": "<uuid>" }
```
Signature is over the canonical message using the private key matching `signingPubKey`.
→ `200 { "userId": "<uuid>" }`. If a user with the same `deviceId` + `signingPubKey`
already exists, return the existing `userId` (idempotent re-enroll).

### `POST /usage`  (authed)
Body:
```json
{ "fiveHourPct": 62.0, "sevenDayPct": 20.0, "resetAt": 1893456000, "availableToLend": true }
```
`resetAt` is unix seconds or null. Upserts the caller's usage, bumps `last_seen`. → `204`.

### `GET /board`  (authed)
→ `200` array, one row per enrolled user:
```json
[ { "userId": "<uuid>", "displayName": "Sanket", "fiveHourPct": 62.0, "sevenDayPct": 20.0,
    "resetAt": 1893456000, "availableToLend": true, "lastSeen": 1893450000, "postedAt": 1893450000 } ]
```
Users with no usage post yet appear with null usage fields.

### `GET /health`  (unauthenticated)
→ `200 { "status": "ok", "service": "claudeometer-relay", "version": "<v>" }`

## Errors
JSON `{ "error": "<message>" }` with status 400 (bad request), 401 (auth), 404, 500.

## Persistence (SQLite, WAL)
```sql
CREATE TABLE users (
  user_id TEXT PRIMARY KEY, display_name TEXT NOT NULL,
  signing_pubkey TEXT NOT NULL, encryption_pubkey TEXT,
  device_id TEXT NOT NULL, created_at INTEGER NOT NULL, last_seen INTEGER NOT NULL
);
CREATE TABLE usage_posts (
  user_id TEXT PRIMARY KEY REFERENCES users(user_id),
  five_hour_pct REAL NOT NULL, seven_day_pct REAL NOT NULL,
  reset_at INTEGER, available_to_lend INTEGER NOT NULL, posted_at INTEGER NOT NULL
);
```
DB path from `DB_PATH` env (default `./relay.db`).

---

# M3 — Borrow Handshake (additions)

The relay stays zero-knowledge: it stores/relays an opaque E2E `ciphertext` it
cannot read. The E2E crypto is Swift↔Swift (lender seals to borrower's X25519
key); the relay only does signaling + a TTL mailbox. All endpoints below are
authed (same signing scheme).

## New tables
```sql
CREATE TABLE borrow_requests (
  id TEXT PRIMARY KEY,
  requester_id TEXT NOT NULL REFERENCES users(user_id),
  lender_id TEXT NOT NULL REFERENCES users(user_id),
  hours INTEGER NOT NULL,
  status TEXT NOT NULL,          -- pending|approved|rejected|revoked|expired|picked_up
  created_at INTEGER NOT NULL,
  decided_at INTEGER
);
CREATE TABLE mailbox (
  request_id TEXT PRIMARY KEY REFERENCES borrow_requests(id),
  recipient_id TEXT NOT NULL,
  ciphertext TEXT NOT NULL,      -- opaque base64 E2E sealed blob; relay never reads it
  ttl_expires_at INTEGER NOT NULL
);
```

## Endpoints
### `POST /borrow/request`  { "lenderId": "<uuid>", "hours": 2 }
Caller = requester. `1 <= hours <= 4`. Creates a `pending` request. → `200 { "requestId": "<uuid>" }`.

### `GET /borrow/inbox`
Returns work addressed to the caller:
```json
{ "incoming": [ { "requestId":"..","requesterId":"..","requesterName":"Alice",
                  "requesterEncryptionPubKey":"<b64>","hours":2,"createdAt":123 } ],
  "outgoing": [ { "requestId":"..","lenderId":"..","lenderName":"Bob","hours":2,
                  "status":"approved","decidedAt":456 } ] }
```
`incoming` = pending requests where caller is the lender (includes the requester's
encryption pubkey so the lender can seal to it). `outgoing` = the caller's own
requests with their current status.

### `POST /borrow/decision`  { "requestId":"..","approve":true,"ciphertext":"<b64>" }
Caller must be the request's lender; request must be `pending`. On approve:
status→`approved`, store `ciphertext` in the mailbox (recipient = requester, TTL
= now+600s). On reject: status→`rejected`. → `204`.

### `GET /borrow/pickup/{requestId}`
Request ID is a path segment (so it's covered by the signature). Caller must be
the requester; request must be `approved` with an unexpired mailbox entry. →
`200 { "ciphertext":"<b64>" }`, then status→`picked_up` and the mailbox row is
deleted (one-shot).

### `POST /borrow/revoke`  { "requestId":".." }
Caller must be the request's lender or requester. status→`revoked`; any mailbox
row deleted. → `204`.

## Sealed-box format (Swift↔Swift, opaque to relay)
`ciphertext` = standard base64 of: `ephPub(32) || nonce(12) || AESGCM(ct+tag)`.
ECIES with CryptoKit `Curve25519.KeyAgreement`:
- Sender: ephemeral X25519 keypair; `shared = keyAgreement(ephPriv, recipientPub)`;
  `key = HKDF<SHA256>(shared, salt: ephPub||recipientPub, info: "claudeometer-borrow-v1", outputByteCount: 32)`;
  seal plaintext with `AES.GCM` under `key` + random 12-byte nonce.
- Recipient: `shared = keyAgreement(recipientPriv, ephPub)`; same HKDF; `AES.GCM.open`.
Plaintext = the lender's raw Claude Code credential blob (the same bytes M1's
CredentialStore reads/writes).
