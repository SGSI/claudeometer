# Multi-Team Phase 3 — Swift Client & Teams-Hub UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Give the macOS app the client methods and UI to create/join/leave teams, switch which team's board it views, and (as owner) approve join requests — consuming the Phase 1+2 relay.

**Architecture:** Add team models + methods to `RelayClient` (Core, unit-tested via `MockURLProtocol`); extend `TeamController` with multi-team state; rebuild the popover "Team" page into a Teams hub in the app target (AppKit, thin).

**Tech Stack:** Swift 6, `ClaudeUsageBarCore` (URLSession relay client), AppKit menu-bar UI, Swift Testing.

## Global Constraints

- Reference spec: `docs/superpowers/specs/2026-07-07-multi-team-design.md` §6 (endpoints) and §10 (UI).
- Sign the **path only** (no query) — for `GET /board?team=X`, sign `/board` and attach `?team=` to the URL separately.
- Path-segment team names are percent-encoded in the URL but signed decoded (matching the relay's `r.URL.Path`).
- Board decoding is unchanged (`BoardRow`); the cross-team redaction arrives as `borrowingFrom == "another team"` with nil `borrowingUntil`.
- New Core code is unit-tested; AppKit wiring stays thin and is verified by running the app.

---

### Task 1: RelayClient team models + methods (+ tests)

**Files:** Modify `Sources/ClaudeUsageBarCore/RelayClient.swift`; Test `Tests/ClaudeUsageBarCoreTests/RelayClientTeamsTests.swift`

**Interfaces produced (all on `RelayClient`):**
- Models: `struct TeamSummary: Codable, Equatable, Sendable { let name: String; let memberCount: Int }`; `struct JoinRequestSummary: Codable, Equatable, Sendable { let id, userName: String; let createdAt: Int }`; `enum JoinOutcome: Equatable, Sendable { case joined; case pending }`.
- `func createTeam(name: String, password: String, visibility: String) async throws` (POST `/teams`, 200)
- `func listPublicTeams() async throws -> [TeamSummary]` (GET `/teams`, 200)
- `func joinTeam(name: String, password: String?) async throws -> JoinOutcome` (POST `/teams/{name}/join`; 200 → `.joined`, 202 → `.pending`)
- `func leaveTeam(name: String) async throws` (POST `/teams/{name}/leave`, 204)
- `func listJoinRequests(team: String) async throws -> [JoinRequestSummary]` (GET `/teams/{name}/requests`, 200)
- `func decideJoinRequest(team: String, id: String, approve: Bool) async throws` (POST `/teams/{name}/requests/{id}`, 204)
- `func fetchBoard(team: String?) async throws -> [BoardRow]` — extends the existing board fetch with an optional team query.

- [ ] **Step 1: Tests** (`RelayClientTeamsTests.swift`, mirror `RelayClientTests` — `MockURLProtocol`, `CapturedRequest`, signature verification):
  - `createTeam` posts `{name,password,visibility}` to `/teams`, signs `/teams`.
  - `listPublicTeams` decodes `[{name,memberCount}]`.
  - `joinTeam` with password → 200 → `.joined`; without/wrong → 202 → `.pending`; asserts path `/teams/Growth/join` is signed decoded.
  - `leaveTeam` succeeds on 204.
  - `listJoinRequests` decodes rows; `decideJoinRequest` posts `{approve:true}` and succeeds on 204.
  - `fetchBoard(team: "tech")` hits URL path `/board` with query `team=tech`, signs `/board` (no query), decodes rows incl. a redacted `borrowingFrom=="another team"`.
- [ ] **Step 2:** `swift test --filter RelayClientTeamsTests` → FAIL.
- [ ] **Step 3: Implement.** Add the models and methods. Add a private `signedRequest(method:path:body:userId:query:)` overload (or extend the existing one) that signs `path` but appends `URLQueryItem`s to the URL. For path-segment names use `appendingPathComponent(name)` (encodes) while signing the decoded `"/teams/\(name)/join"`. Reuse `checkStatus`/`decode`. `joinTeam` maps 200→`.joined`, 202→`.pending` (accept either via a small status switch instead of `checkStatus(expect:)`).
- [ ] **Step 4:** `swift test --filter RelayClientTeamsTests` → PASS; then full `swift test`.
- [ ] **Step 5:** commit `feat(core): RelayClient team methods (create/join/leave/discover/approve) + team board`.

---

### Task 2: TeamController multi-team state

**Files:** Modify `Sources/ClaudeUsageBar/TeamController.swift`

**Interfaces produced:**
- `private(set) var myTeams: [String]` — teams the user belongs to (derived: after each board refresh, the controller also refreshes membership by listing which teams include `userId`; simplest v1 = a `myTeams` cache updated by create/join/leave calls + a `refreshMyTeams()` that infers from a `GET /teams` + local record). *(v1 keeps it minimal — track joined team names locally in the identity store; see Step 3.)*
- `var selectedTeam: String?` — which team's board is shown (nil = union).
- Passthroughs: `createTeam`, `joinTeam`, `leaveTeam`, `listJoinRequests`, `decideJoinRequest`, and `refreshBoard(team:)` calling the Task-1 methods, each firing `onChange`.

- [ ] **Step 1–5:** thin async wrappers mirroring the existing `enroll`/`postUsage`/`refreshBoard` style (log-and-swallow for background, surfaced messages for user-initiated). Persist the selected team + known team names in a small `teams.json` beside the identity. Commit `feat(app): TeamController multi-team state (my teams, selected team, passthroughs)`.

---

### Task 3: Teams-hub UI

**Files:** Modify `Sources/ClaudeUsageBar/ClaudeUsageBarApp.swift`

- Replace the single team page with a hub: a **team switcher** (segmented/list of `myTeams`, plus "All"), the existing `teamSection` bound to the selected team's board (`fetchBoard(team:)`), a **"＋ Create" / "Join"** affordance opening simple forms (name + password + visibility for create; name + password for join), a **Discover** list (`listPublicTeams`) with join/ask-to-join, an owner **pending-requests** list with Approve/Reject, and a **Leave** action. Cross-team borrows already render the neutral chip from the redacted `borrowingFrom`.
- Verified by running the app (kill + relaunch per project convention).
- Commit `feat(app): teams hub UI — switcher, create/join/leave, discover, join approvals`.

---

## Self-Review
- **Spec §6 coverage:** every endpoint has a client method (T1) ✓.
- **Spec §10 coverage:** switcher, create/join/leave, discover, owner approvals, cross-team chip (T3) ✓.
- **Backward-compat:** `fetchBoard(team: nil)` == old `/board` (now the union) so the personal page keeps working ✓.
- Tasks 2–3 are AppKit-thin and outlined; their exact code is finalized at execution once Task 1's signatures are fixed.
