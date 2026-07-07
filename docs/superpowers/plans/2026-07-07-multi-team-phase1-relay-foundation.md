# Multi-Team Phase 1 — Relay Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the relay-side foundation for multiple teams — globally-unique user names, a teams/memberships/join-requests data model, and team lifecycle endpoints (create, discover, join, leave, approve) — without yet changing borrowing.

**Architecture:** Additive on the existing Go relay (`net/http` + SQLite via `modernc.org/sqlite`). New tables and endpoints only; the existing signature-auth (`withAuth`) and UUID `user_id` identity are preserved. Display names gain a global `UNIQUE NOT NULL` constraint (the "name is primary/unique/not-null" requirement) via a safe dedup migration; the new team tables reference the stable `user_id` internally so no existing FK table is rewritten and current borrow history stays intact.

**Tech Stack:** Go stdlib `net/http`, `modernc.org/sqlite`, `golang.org/x/crypto/bcrypt` (new dep) for password hashing, existing `signing` package for request auth.

## Global Constraints

- Reference spec: `docs/superpowers/specs/2026-07-07-multi-team-design.md`.
- Names (user + team) are compared **trimmed + case-insensitively**; store a normalized key to enforce it. No two users share a name; no two teams share a name.
- Team passwords are **bcrypt-hashed at rest** — never stored or logged in plaintext.
- All new team endpoints are **authed** (signed) except none — every one requires `withAuth`.
- Preserve the existing signed-request contract: caller identity stays the UUID in `X-User-Id`; do not change enroll/usage/borrow signatures.
- Go tests use table-free `testing` with the existing helpers (`newTestStore`, `newTestServer`, `enroll`, `call`); run with `go test ./...` from `relay/`.
- **Implementation-safety note (deviation from the "literal name PK" choice):** we enforce name `UNIQUE NOT NULL` and treat it as the human identity, but keep `user_id` as the internal key the existing tables/protocol point at. Product behaviour is identical (globally-unique names, name-as-identity in the app); this avoids a risky live-relay identity rewrite of existing borrow records. Flag if a literal SQL PK repoint is truly required — it is a separate, staged migration.

---

### Task 1: Enforce globally-unique user names (+ dedup migration)

**Files:**
- Modify: `relay/store/store.go` (schema const ~line 18; add `normalizeName`, `dedupeAndConstrainNames`, call from `New`)
- Test: `relay/store/store_test.go`

**Interfaces:**
- Produces: `func normalizeName(s string) string` (trim + lowercase); `func (s *Store) CreateUser(u *User) error` now returns an error whose `errors.Is(err, ErrNameTaken)` is true on a duplicate normalized name; exported `var ErrNameTaken = errors.New("store: name already taken")`.

- [ ] **Step 1: Write the failing test**

Add to `relay/store/store_test.go`:

```go
func TestCreateUser_DuplicateNameRejected(t *testing.T) {
	s := newTestStore(t)
	must := func(err error) { if err != nil { t.Fatalf("setup: %v", err) } }
	must(s.CreateUser(&User{UserID: "u1", DisplayName: "Sanket", SigningPubKey: "k1", DeviceID: "d1", CreatedAt: 1, LastSeen: 1}))

	// Same name, different case/whitespace, different key → rejected.
	err := s.CreateUser(&User{UserID: "u2", DisplayName: "  sanket ", SigningPubKey: "k2", DeviceID: "d2", CreatedAt: 1, LastSeen: 1})
	if !errors.Is(err, ErrNameTaken) {
		t.Fatalf("CreateUser() dup name err = %v, want ErrNameTaken", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd relay && go test ./store/ -run TestCreateUser_DuplicateNameRejected`
Expected: FAIL (`ErrNameTaken` undefined / no rejection).

- [ ] **Step 3: Implement**

In `relay/store/store.go`:
1. Add near the other errors: `var ErrNameTaken = errors.New("store: name already taken")`.
2. Add a normalized column + unique index to the `users` table in the `schema` const:
   ```sql
   -- add to users table definition:
   name_norm TEXT
   -- after the CREATE TABLE statements, add:
   CREATE UNIQUE INDEX IF NOT EXISTS idx_users_name_norm ON users(name_norm);
   ```
3. Add:
   ```go
   func normalizeName(s string) string {
   	return strings.ToLower(strings.TrimSpace(s))
   }
   ```
4. In `CreateUser`, set `name_norm = normalizeName(u.DisplayName)` in the INSERT, and map a SQLite UNIQUE violation on that index to `ErrNameTaken`:
   ```go
   if err != nil {
   	if strings.Contains(err.Error(), "idx_users_name_norm") || strings.Contains(err.Error(), "UNIQUE") {
   		return ErrNameTaken
   	}
   	return fmt.Errorf("store: create user: %w", err)
   }
   ```
5. Add a startup dedup+backfill migration `dedupeAndConstrainNames`, called from `New` **before** creating the unique index, that: backfills `name_norm` for existing rows; finds rows sharing a `name_norm` (keep the earliest `created_at`, suffix the rest `-2`, `-3`, … on both `display_name` and `name_norm`). Then the `CREATE UNIQUE INDEX` cannot fail. (Add the `name_norm` column with `ALTER TABLE users ADD COLUMN name_norm TEXT` guarded by a check that it doesn't already exist.)

- [ ] **Step 4: Run tests**

Run: `cd relay && go test ./store/ -run TestCreateUser -race`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add relay/store/store.go relay/store/store_test.go
git commit -m "feat(relay): enforce globally-unique user names (normalized) + dedup migration"
```

---

### Task 2: Password hashing helper (bcrypt)

**Files:**
- Create: `relay/store/password.go`
- Test: `relay/store/password_test.go`
- Modify: `relay/go.mod` / `relay/go.sum` (add `golang.org/x/crypto`)

**Interfaces:**
- Produces: `func HashPassword(plain string) (string, error)`; `func CheckPassword(hash, plain string) bool`.

- [ ] **Step 1: Add the dependency**

Run: `cd relay && go get golang.org/x/crypto/bcrypt`

- [ ] **Step 2: Write the failing test**

`relay/store/password_test.go`:

```go
package store

import "testing"

func TestHashAndCheckPassword(t *testing.T) {
	h, err := HashPassword("<seed-password>")
	if err != nil {
		t.Fatalf("HashPassword() error = %v", err)
	}
	if h == "<seed-password>" || h == "" {
		t.Fatalf("hash must not be plaintext/empty, got %q", h)
	}
	if !CheckPassword(h, "<seed-password>") {
		t.Fatalf("CheckPassword() = false for correct password")
	}
	if CheckPassword(h, "wrong") {
		t.Fatalf("CheckPassword() = true for wrong password")
	}
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd relay && go test ./store/ -run TestHashAndCheckPassword`
Expected: FAIL (undefined `HashPassword`).

- [ ] **Step 4: Implement**

`relay/store/password.go`:

```go
package store

import "golang.org/x/crypto/bcrypt"

// HashPassword returns a bcrypt hash (salt embedded) for storage at rest.
func HashPassword(plain string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(plain), bcrypt.DefaultCost)
	return string(b), err
}

// CheckPassword reports whether plain matches the stored bcrypt hash.
func CheckPassword(hash, plain string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(plain)) == nil
}
```

- [ ] **Step 5: Run tests + commit**

Run: `cd relay && go test ./store/ -run TestHashAndCheckPassword`
Expected: PASS.

```bash
git add relay/store/password.go relay/store/password_test.go relay/go.mod relay/go.sum
git commit -m "feat(relay): bcrypt password hashing helper for teams"
```

---

### Task 3: Teams / memberships / join-requests schema + store methods

**Files:**
- Modify: `relay/store/store.go` (schema + new methods); optionally split team methods into `relay/store/teams.go`
- Test: `relay/store/teams_test.go`

**Interfaces:**
- Produces:
  - `type Team struct { Name, Visibility, CreatedBy string; CreatedAt int64 }`
  - `func (s *Store) CreateTeam(name, passwordHash, visibility, createdBy string, now int64) error` → `ErrNameTaken` on dup; also inserts an `owner` membership for `createdBy`.
  - `func (s *Store) GetTeam(name string) (*Team, string /*passwordHash*/, error)` → `ErrNotFound` if none.
  - `func (s *Store) ListPublicTeams() ([]TeamSummary, error)` where `TeamSummary{Name string; MemberCount int}`.
  - `func (s *Store) AddMember(team, user, role string, now int64) error` (idempotent via `INSERT OR IGNORE`).
  - `func (s *Store) RemoveMember(team, user string) (remaining int, err error)`.
  - `func (s *Store) IsMember(team, user string) (bool, error)`; `func (s *Store) MemberRole(team, user string) (string, error)`.
  - `func (s *Store) ListUserTeams(user string) ([]string, error)`.
  - `func (s *Store) DeleteTeam(name string) error`.
  - Join requests: `func (s *Store) CreateJoinRequest(id, team, user string, now int64) error`; `func (s *Store) ListPendingJoinRequests(team string) ([]JoinRequest, error)`; `func (s *Store) DecideJoinRequest(id, decidedBy string, approve bool, now int64) (team, user string, err error)`.

- [ ] **Step 1: Write failing tests**

`relay/store/teams_test.go` — cover create+owner-membership, duplicate-name rejection, join/leave, last-member removal count, public listing excludes private, join-request lifecycle:

```go
package store

import (
	"errors"
	"testing"
)

func seedUser(t *testing.T, s *Store, id, name string) {
	t.Helper()
	if err := s.CreateUser(&User{UserID: id, DisplayName: name, SigningPubKey: "k-" + id, DeviceID: "d-" + id, CreatedAt: 1, LastSeen: 1}); err != nil {
		t.Fatalf("seed user %s: %v", name, err)
	}
}

func TestCreateTeamAddsOwnerMembership(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "Sanket")
	if err := s.CreateTeam("KC-Tech", "hash", "private", "u1", 100); err != nil {
		t.Fatalf("CreateTeam: %v", err)
	}
	role, err := s.MemberRole("KC-Tech", "u1")
	if err != nil || role != "owner" {
		t.Fatalf("owner membership = (%q,%v), want owner", role, err)
	}
}

func TestCreateTeamDuplicateNameRejected(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "Sanket")
	_ = s.CreateTeam("Growth", "h", "public", "u1", 1)
	if err := s.CreateTeam("growth", "h", "public", "u1", 1); !errors.Is(err, ErrNameTaken) {
		t.Fatalf("dup team name err = %v, want ErrNameTaken", err)
	}
}

func TestLeaveReportsRemainingAndListing(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "A")
	seedUser(t, s, "u2", "B")
	_ = s.CreateTeam("T", "h", "public", "u1", 1)
	_ = s.AddMember("T", "u2", "member", 2)
	if n, _ := s.RemoveMember("T", "u2"); n != 1 {
		t.Fatalf("remaining after B leaves = %d, want 1", n)
	}
	pub, _ := s.ListPublicTeams()
	if len(pub) != 1 || pub[0].Name != "T" || pub[0].MemberCount != 1 {
		t.Fatalf("ListPublicTeams = %+v, want one T with 1 member", pub)
	}
}

func TestPrivateTeamNotListed(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "A")
	_ = s.CreateTeam("Secret", "h", "private", "u1", 1)
	pub, _ := s.ListPublicTeams()
	if len(pub) != 0 {
		t.Fatalf("ListPublicTeams = %+v, want empty (private excluded)", pub)
	}
}

func TestJoinRequestLifecycle(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "Owner")
	seedUser(t, s, "u2", "Asker")
	_ = s.CreateTeam("Pub", "h", "public", "u1", 1)
	if err := s.CreateJoinRequest("jr1", "Pub", "u2", 5); err != nil {
		t.Fatalf("CreateJoinRequest: %v", err)
	}
	pend, _ := s.ListPendingJoinRequests("Pub")
	if len(pend) != 1 {
		t.Fatalf("pending = %d, want 1", len(pend))
	}
	team, user, err := s.DecideJoinRequest("jr1", "u1", true, 6)
	if err != nil || team != "Pub" || user != "u2" {
		t.Fatalf("DecideJoinRequest = (%q,%q,%v)", team, user, err)
	}
	if ok, _ := s.IsMember("Pub", "u2"); !ok {
		t.Fatalf("approved asker is not a member")
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd relay && go test ./store/ -run 'TestCreateTeam|TestLeave|TestPrivateTeam|TestJoinRequest'`
Expected: FAIL (undefined methods).

- [ ] **Step 3: Implement schema + methods**

Add to the `schema` const (per spec §5, bcrypt so a single `password_hash`, plus normalized `name_norm` unique index for teams):

```sql
CREATE TABLE IF NOT EXISTS teams (
  name TEXT PRIMARY KEY, name_norm TEXT, password_hash TEXT NOT NULL,
  visibility TEXT NOT NULL, created_by TEXT NOT NULL, created_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_teams_name_norm ON teams(name_norm);
CREATE TABLE IF NOT EXISTS memberships (
  team_name TEXT NOT NULL, user_id TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'member',
  joined_at INTEGER NOT NULL, PRIMARY KEY(team_name, user_id)
);
CREATE TABLE IF NOT EXISTS join_requests (
  id TEXT PRIMARY KEY, team_name TEXT NOT NULL, user_id TEXT NOT NULL,
  status TEXT NOT NULL, created_at INTEGER NOT NULL, decided_by TEXT, decided_at INTEGER
);
```

Implement each method with parameterized queries. `CreateTeam` runs INSERT team + INSERT owner membership in one transaction, mapping the unique-index error to `ErrNameTaken`. `ListPublicTeams` joins `memberships` for `MemberCount` and filters `visibility='public'`. `DecideJoinRequest` updates status and, on approve, `AddMember(...,'member')`; returns the team+user for the caller to act on. (Note: memberships store `user_id`; endpoints resolve display names for the client.)

- [ ] **Step 4: Run tests**

Run: `cd relay && go test ./store/ -race`
Expected: PASS (all store tests, new + existing).

- [ ] **Step 5: Commit**

```bash
git add relay/store/
git commit -m "feat(relay): teams/memberships/join-requests schema + store methods"
```

---

### Task 4: Team lifecycle endpoints (create, discover, join, leave)

**Files:**
- Modify: `relay/server/server.go` (route table ~line 45; new handlers); optionally `relay/server/teams.go`
- Test: `relay/server/teams_test.go`

**Interfaces:**
- Consumes: Task 3 store methods; `withAuth` (injects the authed `*store.User`).
- Produces routes: `POST /teams`, `GET /teams`, `POST /teams/{name}/join`, `POST /teams/{name}/leave`.

- [ ] **Step 1: Write failing server tests**

`relay/server/teams_test.go` — create→owner, discover lists only public, join-by-password (correct→member, wrong on private→403), join public without password→pending request, leave→last-member auto-delete:

```go
package server

import (
	"encoding/json"
	"net/http"
	"testing"

	"claudeometer-relay/signing"
)

func TestCreateAndDiscoverTeams(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)

	body, _ := json.Marshal(createTeamRequest{Name: "Growth", Password: "pw", Visibility: "public"})
	if rec := call(t, s, "POST", "/teams", body, aID, aPriv); rec.Code != http.StatusOK {
		t.Fatalf("create: %d %s", rec.Code, rec.Body.String())
	}
	priv, _ := json.Marshal(createTeamRequest{Name: "Secret", Password: "pw", Visibility: "private"})
	call(t, s, "POST", "/teams", priv, aID, aPriv)

	rec := call(t, s, "GET", "/teams", nil, aID, aPriv)
	var list []map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &list)
	if len(list) != 1 || list[0]["name"] != "Growth" {
		t.Fatalf("discover = %v, want only public Growth", list)
	}
}

func TestJoinByPasswordAndWrongPassword(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Owner", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Joiner", "dev-b", bPub, bPriv)
	body, _ := json.Marshal(createTeamRequest{Name: "Priv", Password: "secret", Visibility: "private"})
	call(t, s, "POST", "/teams", body, aID, aPriv)

	wrong, _ := json.Marshal(joinTeamRequest{Password: "nope"})
	if rec := call(t, s, "POST", "/teams/Priv/join", wrong, bID, bPriv); rec.Code != http.StatusForbidden {
		t.Fatalf("wrong pw join: %d, want 403", rec.Code)
	}
	right, _ := json.Marshal(joinTeamRequest{Password: "secret"})
	if rec := call(t, s, "POST", "/teams/Priv/join", right, bID, bPriv); rec.Code != http.StatusOK {
		t.Fatalf("right pw join: %d %s", rec.Code, rec.Body.String())
	}
}

func TestLeaveLastMemberDeletesTeam(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Solo", "dev-a", aPub, aPriv)
	body, _ := json.Marshal(createTeamRequest{Name: "Only", Password: "pw", Visibility: "public"})
	call(t, s, "POST", "/teams", body, aID, aPriv)
	if rec := call(t, s, "POST", "/teams/Only/leave", nil, aID, aPriv); rec.Code != http.StatusNoContent {
		t.Fatalf("leave: %d %s", rec.Code, rec.Body.String())
	}
	rec := call(t, s, "GET", "/teams", nil, aID, aPriv)
	if rec.Body.String() != "[]\n" && rec.Body.String() != "[]" {
		t.Fatalf("team should be gone, discover = %s", rec.Body.String())
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd relay && go test ./server/ -run 'TestCreateAndDiscover|TestJoinBy|TestLeaveLast'`
Expected: FAIL (undefined request types / routes).

- [ ] **Step 3: Implement handlers + routes**

Add request structs (`createTeamRequest{Name,Password,Visibility}`, `joinTeamRequest{Password}`) and handlers:
- `handleCreateTeam`: validate visibility ∈ {private,public}, non-empty name; `HashPassword`; `store.CreateTeam`; map `ErrNameTaken`→409.
- `handleListTeams`: `store.ListPublicTeams` → JSON array `[{name, memberCount}]`.
- `handleJoinTeam`: path value `name`; load team+hash (`GetTeam`); if password correct → `AddMember(...,'member')` → 200; else if team public → `CreateJoinRequest` → 202 `{status:"pending"}`; else (private, wrong/absent) → 403 generic. Extract `{name}` with `r.PathValue("name")`.
- `handleLeaveTeam`: `RemoveMember`; if `remaining==0` → `DeleteTeam`; → 204.

Wire routes with `s.withAuth(...)`:
```go
mux.HandleFunc("POST /teams", s.withAuth(s.handleCreateTeam))
mux.HandleFunc("GET /teams", s.withAuth(s.handleListTeams))
mux.HandleFunc("POST /teams/{name}/join", s.withAuth(s.handleJoinTeam))
mux.HandleFunc("POST /teams/{name}/leave", s.withAuth(s.handleLeaveTeam))
```

- [ ] **Step 4: Run tests**

Run: `cd relay && go test ./server/ -race`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add relay/server/
git commit -m "feat(relay): team create/discover/join/leave endpoints"
```

---

### Task 5: Join-request approval endpoints (owner-only)

**Files:**
- Modify: `relay/server/server.go` (routes + handlers)
- Test: `relay/server/teams_test.go`

**Interfaces:**
- Consumes: `store.ListPendingJoinRequests`, `store.DecideJoinRequest`, `store.MemberRole`.
- Produces routes: `GET /teams/{name}/requests`, `POST /teams/{name}/requests/{id}`.

- [ ] **Step 1: Write failing test**

Append to `relay/server/teams_test.go`:

```go
func TestOwnerApprovesJoinRequest(t *testing.T) {
	s := newTestServer(t)
	oPub, oPriv, _ := signing.GenerateKeypair()
	jPub, jPriv, _ := signing.GenerateKeypair()
	mPub, mPriv, _ := signing.GenerateKeypair()
	oID := enroll(t, s, "Owner", "dev-o", oPub, oPriv)
	jID := enroll(t, s, "Joiner", "dev-j", jPub, jPriv)
	mID := enroll(t, s, "Member", "dev-m", mPub, mPriv)

	body, _ := json.Marshal(createTeamRequest{Name: "Pub", Password: "pw", Visibility: "public"})
	call(t, s, "POST", "/teams", body, oID, oPriv)
	// Member joins with password (so they are a non-owner member).
	jp, _ := json.Marshal(joinTeamRequest{Password: "pw"})
	call(t, s, "POST", "/teams/Pub/join", jp, mID, mPriv)
	// Joiner asks to join (no password) → pending request.
	call(t, s, "POST", "/teams/Pub/join", []byte(`{}`), jID, jPriv)

	// List requests as owner → 1 pending; extract id.
	rec := call(t, s, "GET", "/teams/Pub/requests", nil, oID, oPriv)
	var reqs []map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &reqs)
	if len(reqs) != 1 {
		t.Fatalf("pending = %d, want 1", len(reqs))
	}
	id := reqs[0]["id"].(string)

	// Non-owner member cannot approve.
	dec, _ := json.Marshal(decideJoinRequest{Approve: true})
	if rec = call(t, s, "POST", "/teams/Pub/requests/"+id, dec, mID, mPriv); rec.Code != http.StatusForbidden {
		t.Fatalf("member approve: %d, want 403", rec.Code)
	}
	// Owner approves.
	if rec = call(t, s, "POST", "/teams/Pub/requests/"+id, dec, oID, oPriv); rec.Code != http.StatusNoContent {
		t.Fatalf("owner approve: %d %s", rec.Code, rec.Body.String())
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd relay && go test ./server/ -run TestOwnerApprovesJoinRequest`
Expected: FAIL.

- [ ] **Step 3: Implement**

- `handleListJoinRequests`: assert caller `MemberRole(name, caller)=="owner"` else 403; return `ListPendingJoinRequests` as `[{id, userName, createdAt}]` (resolve `user_id`→name).
- `handleDecideJoinRequest`: owner-check; `store.DecideJoinRequest(id, callerID, approve, now)`; 204. Idempotent (already-decided → 204/409 consistently).
- Routes:
  ```go
  mux.HandleFunc("GET /teams/{name}/requests", s.withAuth(s.handleListJoinRequests))
  mux.HandleFunc("POST /teams/{name}/requests/{id}", s.withAuth(s.handleDecideJoinRequest))
  ```

- [ ] **Step 4: Run all relay tests**

Run: `cd relay && go test ./... -race`
Expected: PASS (whole relay suite).

- [ ] **Step 5: Commit**

```bash
git add relay/server/
git commit -m "feat(relay): owner-only join-request approval endpoints"
```

---

## Self-Review

- **Spec coverage (Phase 1 slice):** unique/not-null names (T1) ✓; team = name+password+visibility (T3/T4) ✓; hashed passwords (T2) ✓; create (T4) ✓; discover public / hide private (T4) ✓; join by password + private generic 403 (T4) ✓; ask-to-join → pending (T4) + owner approval (T5) ✓; leave + last-member auto-delete (T4) ✓; owner role (T3/T5) ✓. Deferred to later phases (documented): borrow shared-team enforcement, per-viewing-team board redaction, single-active-borrow lock, KC-Tech data migration, Swift client + UI.
- **Placeholder scan:** none — every step has concrete code/commands.
- **Type consistency:** `createTeamRequest`, `joinTeamRequest`, `decideJoinRequest` used consistently across T4/T5; store methods match the Interfaces blocks.

## Notes for later phases
- The **KC-Tech data migration** (seed the private team + add all existing users) lands in the borrow-scoping phase or a dedicated migration task, once membership is proven — it is a data step, not schema.
- `GET /board` stays global until Phase 2 makes it team-scoped; do not change it here.
