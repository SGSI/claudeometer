# Claudeometer — Multiple Teams

**Status:** Design (approved direction, pending spec review)
**Date:** 2026-07-07
**Author:** brainstormed with the product owner

---

## 1. Problem

Today the relay *is* a single implicit team: `GET /board` returns every enrolled
user, and any user may borrow from any other. To distribute Claudeometer beyond
one group, users must be able to form **multiple named teams** on a shared relay,
belong to several at once, and have usage-sharing and borrowing scoped to the
teams they share — while keeping each team's membership and borrow activity
private from teams a user also belongs to.

---

## 2. Goals / Non-Goals

### Goals
- Multiple teams on one shared relay; a user can belong to many.
- Team = unique name + password + visibility (private | public).
- Create / join (by password) / leave. Public teams also support ask-to-join +
  owner approval, and are discoverable; private teams are invisible.
- Borrowing and usage visibility scoped to **shared team membership**, enforced
  server-side.
- Cross-team privacy: a borrow counterparty who is not in the viewing team is
  never revealed to it.
- Migrate all current users into a private team **KC-Tech**.

### Non-Goals (v1)
- **Multi-device / second Mac for one person** — deferred. One name = one device
  key; reinstall on the same Mac keeps identity via the Keychain.
- **TLS** — the relay may stay plain HTTP for now (owner's call); passwords are
  still hashed at rest. Network-sniffing of join passwords is an accepted risk
  until TLS lands (see §9).
- **Rename** of a user or team — names are the primary key and FK-referenced, so
  renaming is out of scope for v1.
- Team member roles beyond `owner`/`member`; per-member permissions; audit logs.

---

## 3. Decisions (chosen with the owner)

| Decision | Choice | Rationale |
|---|---|---|
| Relay tenancy | **One shared relay** | Public teams discoverable relay-wide; all orgs coexist in one namespace. |
| Public teams in v1 | **Yes** | Discovery + ask-to-join included now. Approval routing is in-app (no dependency on the dormant notification system). |
| Identity / names | **Name is the primary key**, global `UNIQUE NOT NULL`, for users and teams | Owner's explicit choice. Signing key remains the actual authenticator; name is the lookup key. |
| Transport | **Plain HTTP allowed for now** | Owner's call. Passwords hashed at rest; sniffing is an accepted risk (§9). |
| Admin model | **Creator = owner** | Owner approves public join-requests, rotates password, removes members, deletes team. Avoids one arbitrary member locking others out. |
| Second device | **Deferred** | One name = one device key in v1. |
| KC-Tech owner | **The product owner (Sanket)** | Rotate `<seed-password>` after migration — it is effectively public. |
| Leave/remove mid-borrow | **In-flight borrow runs to window end** | Less disruptive; no new borrows after leaving. |
| Last member leaves | **Team auto-deletes** | No orphaned unique-name squatting. |
| Usage value | **Global per user**, shown only to shared teams | One self-reported number; visibility gated by membership. |

---

## 4. Identity & naming

- User identity is the **display name** (primary key), bound at enroll to the
  device's ed25519 signing key. Every signed request identifies the caller by
  name; the relay verifies the signature against the key bound to that name.
- Team identity is the **team name** (primary key).
- Names are **`UNIQUE NOT NULL`**, compared **trimmed + case-insensitively**
  (`"Sanket"`, `"sanket"`, `"sanket "` collide) to prevent look-alike squatting.
- **Enroll semantics:** enrolling a name that is free binds it to the caller's
  key. Enrolling a name already bound to a **different** key → `409 name taken`.
  Enrolling a name bound to the **same** key is idempotent (you). A device thus
  "owns" its name via its key.
- **No rename** in v1 (name is FK-referenced across memberships and borrows).

> Accepted limitation: whoever enrolls a name first owns it (land-grab /
> first-enroller impersonation). The signing key — not the name — is the real
> credential, so this does not weaken request authentication; it only affects who
> holds a given label.

---

## 5. Data model (SQLite)

Existing `users`, `usage_posts`, `borrow_requests`, `mailbox` tables are
repointed from the `user_id` UUID to the user **name** as identity (see §8
migration — a table rebuild, since SQLite can't alter a PK in place).

```sql
CREATE TABLE teams (
  name         TEXT PRIMARY KEY,          -- trimmed, unique (case-insensitive collation)
  password_hash TEXT NOT NULL,            -- argon2id (or bcrypt) — never plaintext
  password_salt TEXT NOT NULL,
  kdf_params   TEXT NOT NULL,
  visibility   TEXT NOT NULL CHECK (visibility IN ('private','public')),
  created_by   TEXT NOT NULL REFERENCES users(name),
  created_at   INTEGER NOT NULL
);

CREATE TABLE memberships (
  team_name TEXT NOT NULL REFERENCES teams(name),
  user_name TEXT NOT NULL REFERENCES users(name),
  role      TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner','member')),
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (team_name, user_name)       -- composite PK ⇒ no duplicate membership
);

CREATE TABLE join_requests (
  id         TEXT PRIMARY KEY,
  team_name  TEXT NOT NULL REFERENCES teams(name),
  user_name  TEXT NOT NULL REFERENCES users(name),
  status     TEXT NOT NULL CHECK (status IN ('pending','approved','rejected')),
  created_at INTEGER NOT NULL,
  decided_by TEXT,
  decided_at INTEGER
);
```

Notes:
- Uniqueness is enforced by a case-insensitive collation (or a stored normalized
  `name_norm` column with `UNIQUE`) so trims/casing can't dodge it.
- `PRAGMA foreign_keys = ON` must be set on the connection — today it isn't, so
  the `REFERENCES` clauses are currently declarative-only. Membership cleanup on
  member removal is handled in code regardless (FKs won't cascade borrows).

---

## 6. Protocol / endpoints

All authed (signed) unless noted. Name-based identity in the signature.

| Method / path | Who | Body → result |
|---|---|---|
| `POST /teams` | any user | `{name, password, visibility}` → creates team; caller becomes `owner` member. `409` if name taken. |
| `GET /teams` | any user | Lists **public** teams (name, member count, visibility). Private teams never appear. |
| `POST /teams/{name}/join` | any user | `{password}`. Correct password → instant member. Public + omitted/incorrect password → creates a **pending** `join_request` (ask-to-join). Private + wrong password → generic `403` (no existence leak). |
| `GET /teams/{name}/requests` | owner | Pending join-requests for the team. |
| `POST /teams/{name}/requests/{id}` | owner | `{approve}` → adds member or rejects. Idempotent (first decision wins). |
| `POST /teams/{name}/leave` | member | Removes caller. Last member → team auto-deleted. |
| `GET /board?team={name}` | member | Team-scoped board (replaces the global board). `403` if caller isn't a member. |
| Borrow endpoints | member | `/borrow/request`, `/decision`, `/pickup`, `/revoke` gain a **shared-team** check (§7). |

**Breaking change:** `GET /board` is now team-scoped. A client that omits `team`
defaults to the union of the caller's memberships (never "all relay users"), so
old clients don't re-leak the whole relay.

---

## 7. Borrow scoping & cross-team privacy (server-enforced)

**Eligibility (all must hold, checked server-side):**
1. Requester and lender **share at least one team**.
2. The existing relative rule — requester's 5-hour usage % **strictly greater**
   than the lender's.
3. Re-checked at **request, decision, and pickup** — a membership change
   mid-flow can't sneak a credential across a boundary.

**Single-active-borrow lock:** a lender has one real credential, so they may lend
to **one** borrower at a time, and the lock spans **all** their teams (lending in
`product` marks them unavailable in `tech` too). A borrower holds **one** active
borrow.

**Per-viewing-team board redaction** — for `GET /board?team=T`:
- Roster = members of `T` only.
- For each active borrow (requester R, lender L) surfaced on `T`'s board, reveal
  a counterparty's identity **only if that counterparty is also in `T`**.
  Otherwise the row reads `borrowingFrom: "another team"` / `lendingTo` entry
  redacted — with **no name, no user id, no keys, and no borrow-until timestamp**
  that could fingerprint the outsider.
- Worked example: I'm in `tech` and `product`, borrowing from F (only in
  `product`).
  - `product` board: my row → "borrowing from **F**"; F's row → "lending to
    **me**".
  - `tech` board: my row → "borrowing from **another team**"; F does not appear
    at all.

**Usage numbers** are the user's own global self-report, shown only on the boards
of teams they belong to. No per-team usage snapshots.

---

## 8. Migration

Additive and idempotent, in one transaction:

1. Create `teams`, `memberships`, `join_requests`.
2. **Dedup existing user names** so the global unique/PK constraint can't abort:
   any collision gets a deterministic suffix (e.g. `Sanket`, `Sanket-2`) on the
   losing rows; each user keeps its device-key binding.
3. **Rebuild identity tables** to make `name` the PK (SQLite can't alter a PK in
   place): create new `users`/`usage_posts`/`borrow_requests`/`mailbox` with
   name-based keys, copy rows across (mapping old `user_id` → name), swap.
4. Create team **KC-Tech**: `visibility='private'`,
   `password_hash = argon2id("<seed-password>", salt)`, `created_by = <owner>`.
5. Insert a `memberships` row for **every** existing user (owner = the product
   owner, role `owner`; everyone else `member`). Verify
   `count(memberships) == count(users)` before commit.
6. Post-migration action item: **rotate the KC-Tech password** — `<seed-password>` is in
   this doc and git history, so treat it as burned.

Historical `borrow_requests` all reference users now in KC-Tech, so past borrows
stay coherent — no rewrite of borrow history needed.

---

## 9. Security notes

- **Transport (accepted risk).** Relay may run over plain HTTP; join passwords
  travel in cleartext and are sniffable on the network path. Acceptable only on a
  trusted network. **When distributing wider, add TLS** (re-enable ATS / require
  `https` for team endpoints). Passwords are argon2id-hashed at rest regardless.
- **Membership = credential reach.** Being in a team authorizes *requesting*
  another member's real Claude credential. Public teams therefore admit
  strangers into borrow range — mitigated by: owner-only approval,
  per-request/approve/pickup shared-team checks, and rate-limited join requests.
- **Replay window.** The existing 300s no-nonce signature window means a captured
  signed join/borrow can be replayed in-window; note for the TLS follow-up.
- **No existence leak.** Wrong team name and wrong password on a private-team join
  return the same generic error.

---

## 10. UI (menu-bar app)

The single "Team" page becomes a **Teams hub**:

- **My teams switcher** → per-team board (roster + usage bars + Request buttons),
  reusing the existing team-row UI (now including online status/freshness and
  the online-first sort from the prior feature).
- **Create team** (name, password, visibility) and **Join team** (name +
  password) entries; a **Discover** list of public teams (join-with-password or
  ask-to-join).
- **Owner surface:** a pending join-requests list with Approve/Reject and a
  count badge — in-app, no notification dependency.
- **Leave team** action.
- **Cross-team borrow** renders a neutral "borrowing externally" chip (no
  counterparty details) per §7.
- **Empty states:** user in 0 teams ("Create or join a team" + Discover); team of
  1 ("Share the name + password to invite"); no eligible lenders.

---

## 11. Edge cases

- User in 0 teams: still enrolled and posting usage, appears on no board, can't
  be borrowed from.
- Two clients create the same team name / enroll the same name concurrently →
  `UNIQUE` arbitrates; the loser gets a clean "already taken" error (no crash).
- Owner leaves: ownership must transfer (oldest remaining member) or the team
  auto-deletes if they were the last member. *(Decision: auto-promote the
  earliest-joined remaining member to owner.)*
- Join-request approved twice / approve-then-reject race → first decision wins
  (idempotent).
- Member removed mid-borrow → in-flight borrow runs to its window end; no new
  borrows; their pending requests are cancelled.

---

## 12. Testing

- **Relay (Go):** shared-team borrow enforcement (request/decision/pickup);
  per-viewing-team board redaction (the F-not-in-tech case, incl. id/key
  stripping); single-active-borrow lock across teams; join-by-password vs
  ask-to-join + owner approval; leave / last-member auto-delete / owner
  transfer; name-uniqueness collisions; migration dedup + KC-Tech seeding.
- **Core (Swift):** any pure membership/visibility helpers extracted to Core,
  unit-tested like `TeamActivity`.
- **App (Swift):** thin AppKit wiring, verified by running the app.

---

## 13. Out of scope / future

- Multi-device identity portability; rename.
- TLS + nonce-based replay protection (strongly recommended before wider
  distribution).
- Richer roles (multiple admins, per-member permissions), audit trail.
- Notification-driven join/borrow alerts (layer on once the app is Developer
  ID-signed — see the separate app-signing/crash investigation).
