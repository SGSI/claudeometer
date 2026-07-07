# Multi-Team Phase 2 — Borrow Scoping & Cross-Team Privacy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Scope borrowing and the board to shared team membership, redact cross-team borrow counterparties per viewing team, lock a lender/borrower to one active borrow, and migrate current users into the private KC-Tech team.

**Architecture:** Additive on the Phase-1 relay. New store helpers (`SharesTeam`, active-borrow locks, team-scoped/union board rosters); server enforcement in the borrow handlers and a rewritten `handleBoard`; a one-time guarded KC-Tech data migration in `store.Open`.

**Tech Stack:** Go stdlib + SQLite; existing `signing` auth; Phase-1 team store.

## Global Constraints

- Reference spec: `docs/superpowers/specs/2026-07-07-multi-team-design.md` §7 (scoping/privacy) and §8 (migration).
- Borrow requires a shared team, enforced server-side at **request, decision, and pickup**.
- Board redaction is **per viewing roster**: a borrow counterparty is revealed only if in the roster; otherwise shown as the literal `"another team"` with no id/keys/until.
- One active (`picked_up`, in-window) borrow per borrower; one active lend per lender, spanning all teams.
- KC-Tech migration is one-time + idempotent (guarded on the team's absence) and must not auto-join users enrolled later.
- Tests: `go test ./... -race` from `relay/`.

---

### Task 1: Store helpers — shared-team, active-borrow locks, team/union board rosters

**Files:** Modify `relay/store/teams.go`, `relay/store/store.go`; Test `relay/store/teams_test.go`, `relay/store/store_test.go`

**Interfaces produced:**
- `func (s *Store) SharesTeam(a, b string) (bool, error)`
- `func (s *Store) IsLending(userID string, now int64) (bool, error)`
- `func (s *Store) IsBorrowing(userID string, now int64) (bool, error)`
- `func (s *Store) TeamMemberIDs(team string) (map[string]bool, error)`
- `func (s *Store) VisibleUserIDs(viewer string) (map[string]bool, error)` — union of members across the viewer's teams (incl. viewer)
- `func (s *Store) ListBoardForTeam(team string) ([]BoardRow, error)` and refactor `ListBoard` to share a `scanBoardRows` helper.

- [ ] **Step 1: Tests** (`teams_test.go`): `SharesTeam` true for co-members, false otherwise; `IsLending`/`IsBorrowing` reflect a picked_up in-window row; `TeamMemberIDs`/`VisibleUserIDs` sets; `ListBoardForTeam` returns only members.
- [ ] **Step 2:** `go test ./store/ -run 'SharesTeam|Lending|Borrowing|MemberIDs|Visible|BoardForTeam'` → FAIL.
- [ ] **Step 3: Implement.**
  - `SharesTeam`: `SELECT COUNT(1) FROM memberships m1 JOIN memberships m2 ON m1.team_name=m2.team_name WHERE m1.user_id=? AND m2.user_id=?` (a==b via same-team self-join still >0 if a is in any team; guard a==b→true only if intended — callers pass distinct ids).
  - `IsLending`: `SELECT COUNT(1) FROM borrow_requests WHERE lender_id=? AND status='picked_up' AND ? < decided_at + hours*3600`. `IsBorrowing`: same with `requester_id`.
  - `TeamMemberIDs`: `SELECT user_id FROM memberships WHERE team_name=?` → set.
  - `VisibleUserIDs`: `SELECT DISTINCT m2.user_id FROM memberships m1 JOIN memberships m2 ON m1.team_name=m2.team_name WHERE m1.user_id=?` → set (includes viewer).
  - Extract `scanBoardRows(rows *sql.Rows) ([]BoardRow, error)` from `ListBoard`; add `ListBoardForTeam` = ListBoard query + `JOIN memberships mem ON mem.user_id=u.user_id WHERE mem.team_name=?`.
- [ ] **Step 4:** `go test ./store/ -race` → PASS.
- [ ] **Step 5:** commit `feat(relay): store helpers for shared-team, active-borrow locks, team-scoped board`.

---

### Task 2: Server enforcement — shared team + single-active-borrow lock

**Files:** Modify `relay/server/server.go`; Test `relay/server/borrow_scope_test.go`

- [ ] **Step 1: Tests:** borrow request across non-shared teams → 403; request when requester already borrowing (active) → 409; request when lender already lending (active) → 409; decision/pickup re-check shared team → 403 after the requester leaves the shared team. (Set up two users in a team, exercise; use a second team to break sharing.)
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3: Implement.** In `handleBorrowRequest`, after the lender-exists check and before HasPendingRequest:
  ```go
  if shared, err := s.store.SharesTeam(u.UserID, req.LenderID); err != nil {
      writeErr(w, http.StatusInternalServerError, "team check failed"); return
  } else if !shared {
      writeErr(w, http.StatusForbidden, "no shared team with this lender"); return
  }
  now := s.now().Unix()
  if busy, _ := s.store.IsBorrowing(u.UserID, now); busy {
      writeErr(w, http.StatusConflict, "you already have an active borrow"); return
  }
  if busy, _ := s.store.IsLending(req.LenderID, now); busy {
      writeErr(w, http.StatusConflict, "lender is currently lending"); return
  }
  ```
  In `handleBorrowDecision` (before ApproveBorrow) and `handleBorrowPickup` (before PickupMailbox), add a `SharesTeam(br.RequesterID, br.LenderID)` re-check → 403 on false. In decision-approve also re-check `IsLending(br.LenderID, now)` (a different borrow may have gone active).
- [ ] **Step 4:** `go test ./server/ -race` → PASS.
- [ ] **Step 5:** commit `feat(relay): enforce shared-team + single-active-borrow on the borrow handshake`.

---

### Task 3: Per-viewing-team board with redaction

**Files:** Modify `relay/server/server.go` (`handleBoard`); Test `relay/server/board_scope_test.go`

- [ ] **Step 1: Tests:** `GET /board?team=X` as a non-member → 403; as a member → only X's roster; a member borrowing from someone outside X shows `borrowingFrom == "another team"` with null `borrowingUntil`; within-team borrow shows the real name. `GET /board` (no param) → union of the caller's teams.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3: Implement** — rewrite `handleBoard`:
  ```go
  team := r.URL.Query().Get("team")
  var board []store.BoardRow
  var roster map[string]bool
  if team != "" {
      t, _, err := s.store.GetTeam(team)
      if err != nil { writeErr(w, http.StatusNotFound, "unknown team"); return }
      if ok, _ := s.store.IsMember(t.Name, u.UserID); !ok { writeErr(w, http.StatusForbidden, "not a member"); return }
      board, _ = s.store.ListBoardForTeam(t.Name)
      roster, _ = s.store.TeamMemberIDs(t.Name)
  } else {
      roster, _ = s.store.VisibleUserIDs(u.UserID)
      all, _ := s.store.ListBoard()
      for _, row := range all { if roster[row.UserID] { board = append(board, row) } }
  }
  if board == nil { board = []store.BoardRow{} }
  annotateBoardRedacted(board, roster, s.now().Unix(), s.store)
  writeJSON(w, http.StatusOK, board)
  ```
  Add `annotateBoardRedacted(board, roster, now, store)` using `ListActiveBorrows(now)`:
  ```go
  const elsewhere = "another team"
  for _, a := range actives {
      if r := byID[a.RequesterID]; r != nil { // requester visible on this board
          if roster[a.LenderID] { name, ends := a.LenderName, a.EndsAt; r.BorrowingFrom = &name; r.BorrowingUntil = &ends } else { s := elsewhere; r.BorrowingFrom = &s /* no until */ }
      }
      if r := byID[a.LenderID]; r != nil { // lender visible on this board
          if roster[a.RequesterID] { r.LendingTo = append(r.LendingTo, a.RequesterName) } else { r.LendingTo = append(r.LendingTo, elsewhere) }
      }
  }
  ```
- [ ] **Step 4:** `go test ./server/ -race` → PASS.
- [ ] **Step 5:** commit `feat(relay): team-scoped board with cross-team counterparty redaction`.

---

### Task 4: KC-Tech one-time data migration

**Files:** Modify `relay/store/store.go` (add `migrateKCTech`, call from `Open` after `migrateUserNames`); Test `relay/store/store_test.go`

- [ ] **Step 1: Test:** pre-seed a legacy DB with two users (raw), Open, assert a private team `KC-Tech` exists, both users are members, and the earliest-created (or a user named "Sanket") is `owner`; a second Open is a no-op (still one team, no dupes).
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3: Implement** `migrateKCTech(db)`:
  - If a team with `name_norm='kc-tech'` exists → return (idempotent).
  - Count users; if 0 → return (fresh install; new users don't auto-join).
  - Owner = the user with `name_norm='sanket'` if present, else the earliest `created_at` (tie-break `user_id`).
  - In one tx: insert team `KC-Tech` (`visibility='private'`, `password_hash=HashPassword("<seed-password>")`, `created_by=owner`); insert memberships for every user (`owner` for the owner, `member` otherwise).
  - Call from `Open` after `migrateUserNames`.
- [ ] **Step 4:** `go test ./... -race` → PASS (full relay suite).
- [ ] **Step 5:** commit `feat(relay): one-time KC-Tech private-team migration for existing users`.

---

## Self-Review
- **Spec §7 coverage:** shared-team borrow (T2) ✓; board redaction per viewing team (T3) ✓; single-active-borrow lock (T1 helpers + T2 enforcement) ✓; usage stays global, gated by roster visibility (T3) ✓.
- **Spec §8 coverage:** KC-Tech seed + membership migration (T4) ✓; dedup already in Phase 1.
- **Deferred (documented):** pickup-time is the only fully race-proof lock point; T2 enforces at request+decision+pickup which covers realistic single-user flows. Rotating `<seed-password>` remains a manual post-deploy action.
- **No placeholders; helper/handler names consistent across tasks.**
