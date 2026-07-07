# Team Board — Online Status & Per-Row Usage Freshness

**Status:** Design (approved direction, pending spec review)
**Date:** 2026-07-07
**Author:** brainstormed with the team owner

---

## 1. Problem

The team board (menu-bar popover → **Team**) shows each teammate's current
5-hour usage as a percentage and a mini-bar. Two things are missing:

1. **No presence.** You can't tell who is actually running Claude right now
   versus who has their laptop closed. Everyone looks equally "there."
2. **No per-row freshness.** Each row posts usage only while that person's app
   is running (every 3–5 min). When someone closes their laptop at 25%, their
   row keeps showing a fresh-looking **25%** indefinitely — there is no signal
   the number is hours old. The popover's footer says "Updated 3m ago", but that
   is the *viewer's own* usage fetch time, not each teammate's data currency, so
   it actively reinforces the illusion that every row is current.

**Goal:** on each team row, show (a) whether the teammate is online/active and
(b) how fresh their displayed usage is — so a stale number reads as stale.

---

## 2. Goals / Non-Goals

### Goals
- **Online indicator.** A per-row signal for "this teammate's app is actively
  posting right now."
- **Per-row freshness.** Each row shows how long ago that teammate last posted
  usage, and de-emphasizes the number once it is no longer trustworthy.
- **Client-only.** Use data the board already returns. No relay, protocol, or
  schema changes.
- **Testable core.** The classification logic is a pure function with unit tests,
  matching the existing `ActiveBorrow` precedent.

### Non-Goals
- No relay/protocol changes. `postedAt` and `lastSeen` already ship on every
  `BoardRow`.
- No real-time push/websockets — freshness is derived at render time from the
  last fetched board, refreshed on the existing 3–5 min poll and on manual
  refresh.
- No change to the footer line, the borrow section, or the personal page.
- No new "last active" history or analytics — just the current state per row.

---

## 3. Background — data already available

`BoardRow` (`Sources/ClaudeUsageBarCore/RelayClient.swift`) already carries:

- `postedAt: Int?` — unix seconds when this teammate last posted usage
  (`POST /usage`). `nil` until they have posted at least once. This is the exact
  "how current is the % shown" timestamp.
- `lastSeen: Int` — unix seconds of the teammate's last authenticated relay
  contact. Per `relay/PROTOCOL.md`, only `POST /usage` bumps `last_seen`, and the
  app posts usage + refreshes the board together every poll, so for a running app
  `lastSeen ≈ postedAt`.

Because usage is posted every 3–5 min while the app runs (`pollInterval`, 3 min
at ≥90% utilization up to 5 min otherwise), "recently posted" is a reliable proxy
for "app is running now."

**Decision:** drive both features off `postedAt`. It is the semantically correct
"freshness of the displayed number," and for the online dot it doubles as
"is the app posting right now." `lastSeen` is not needed for v1. A teammate who
has never posted (`postedAt == nil`) already renders `—` for usage and is treated
as offline with no timestamp.

---

## 4. Design

### 4.1 Activity model (new, in Core — testable)

A small pure type in `Sources/ClaudeUsageBarCore/` (new file `TeamActivity.swift`),
classifying a row from `postedAt` and an injected "now":

```
enum TeamActivity {
    case active       // posted <= onlineWithin        → online, number current
    case idle         // onlineWithin < age <= staleAfter → recently away, number ~ok
    case stale        // age > staleAfter               → number not trustworthy
    case neverPosted  // postedAt == nil                → enrolled, no usage yet
}
```

Named thresholds (easy to tune in one place):

- `onlineWithin = 600` seconds (10 min) — tolerates one missed 3–5 min post.
- `staleAfter = 900` seconds (15 min) — ~three missed posts; the number is now
  old enough to distrust.

Classification is `TeamActivity.classify(postedAt: Int?, now: Date) -> TeamActivity`,
pure and deterministic (now is injected, never `Date()` internally), so it is unit
testable exactly like `ActiveBorrow`.

Derived, for the view layer:
- `isOnline` — true only for `.active`.
- `isStale` — true only for `.stale`.

### 4.2 Avatar status dot

Extend `InitialsAvatarView` (app target) with an optional activity state used to
draw a small status dot at the bottom-right of the terra disc:

- `.active` → filled `Theme.green` dot.
- `.idle` / `.stale` / `.neverPosted` → hollow grey dot (`Theme.inkFaint`,
  reduced alpha).
- A thin `Theme.card`-colored ring around the dot separates it from the disc.

The dot is only shown where an activity state is supplied (the team board rows);
avatars elsewhere (borrow cards) pass no state and render unchanged.

Dot geometry: diameter ≈ 34% of the avatar diameter (≈ 9pt on the 26pt row
avatar), inset so it sits just inside the bottom-right edge, drawn in
`InitialsAvatarView.draw(_:)` after the disc + initial.

### 4.3 Always-on freshness caption

Today the row caption renders only when `resetAt != nil`:
`resets \(relativeResetText(resetDate))`. Refactor it into a pure caption builder
so it also carries the freshness suffix and works when `resetAt` is nil:

- Both present → `resets in 1h 17m · 2m ago`
- `resetAt` nil, `postedAt` present → `updated 2m ago`
- `.neverPosted` → no caption suffix (row already shows `—`)

The whole caption is assembled in a pure Core helper that returns the caption
text plus an `isStale` flag. It formats the relative time itself, mirroring the
app target's existing `relative(_:)` phrasing (`Xs/Xm/Xh ago`) — the Core helper
cannot call the app target's private `relative(_:)`, so the phrasing lives in
Core (and the app target's copy may later delegate to it). The app-target label
applies color: `Theme.inkFaint` normally, **`Theme.yellow`** (amber) when
`.stale`.

### 4.4 Dim stale rows

When `isStale`, set `alphaValue ≈ 0.4` on the container holding the mini-bar and
the `%` label (the existing `indented` stack in `teamRow`), so a stale "57%"
visibly recedes. `.active` / `.idle` / `.neverPosted` render at full strength —
`.idle` deliberately does *not* dim, so a teammate who stepped away for 12 minutes
keeps a legible number (that is the grace band between `onlineWithin` and
`staleAfter`).

### 4.5 Row ordering

The board is reordered so the best borrow candidates surface first, replacing the
old "highest usage on top" sort:

1. **Online (`.active`) teammates rank above everyone else** — an online teammate
   at 90% still sorts above an offline one at 5%, because only an online teammate
   can actually approve a borrow.
2. **Within each group, least 5-hour usage first** — the most headroom floats up.
3. Rows with no posted usage sink to the bottom of their group; ties break by
   display name for a stable order across refreshes.

Applied to online and offline groups alike (offline order matters less, but the
same rule keeps it predictable). Implemented as a pure `TeamBoardSort.forDisplay`
in Core, unit-tested.

### 4.6 Self row

The current user's own row is classified identically. Because the app is running
whenever the popover is open, the user's own `postedAt` is fresh, so their row
shows a green dot and a fresh `· Xs ago` timestamp with no special-casing.

---

## 5. Components & boundaries

| Unit | Location | Responsibility | Tested |
|------|----------|----------------|--------|
| `TeamActivity` (+ thresholds, `classify`) | `Sources/ClaudeUsageBarCore/TeamActivity.swift` | Pure classification from `postedAt` + now | ✅ unit |
| Caption builder | Core (same file or alongside) | Pure `(resetAt, postedAt, now) → (text, isStale)` | ✅ unit |
| `TeamBoardSort.forDisplay` | `Sources/ClaudeUsageBarCore/TeamActivity.swift` | Pure ordering: online first, least usage first | ✅ unit |
| `InitialsAvatarView` dot | `Sources/ClaudeUsageBar/ClaudeUsageBarApp.swift` | Draw status dot for a given state | thin, uncovered |
| `teamRow` wiring | same file | Classify row, pass state to avatar, color caption, dim on stale | thin, uncovered |

Rationale for splitting: the app target (`ClaudeUsageBar`) has no test target;
`ClaudeUsageBarCore` does (`Tests/ClaudeUsageBarCoreTests`). Putting all logic and
thresholds in Core makes them testable and keeps the AppKit views declarative.

---

## 6. Data flow

1. Existing poll posts usage and calls `refreshBoard()` → `board: [BoardRow]`
   (unchanged).
2. On render, `teamRow(row:)` calls `TeamActivity.classify(postedAt: row.postedAt,
   now: Date())`.
3. The state drives: avatar dot color, caption suffix text + color, and the
   bar/`%` alpha.
4. No new fetches, timers, or storage. Freshness advances naturally as the board
   re-renders on each poll and on manual refresh.

---

## 7. Edge cases

- **Never posted (`postedAt == nil`).** Offline dot, no timestamp suffix, no
  dimming (already shows `—`).
- **Clock skew.** `postedAt` is server time; `relative()` uses the local clock.
  A small skew can make a just-posted row read `0s`/`1s ago`; acceptable and
  consistent with the existing "asked Xm ago" copy. No correction in v1.
- **Future timestamp.** If `postedAt` is slightly in the future (skew),
  `classify` treats non-positive age as `.active` and `relative()` clamps to
  `0s ago`.
- **Board left stale by a failed refresh.** `TeamController` intentionally keeps
  the last good board on a failed fetch. Rows will correctly age toward `.stale`
  on their own, which is the desired behavior (the data really is old).
- **Boundary values.** Exactly `onlineWithin` (600s) → `.active` (inclusive);
  exactly `staleAfter` (900s) → `.idle` (inclusive); `> staleAfter` → `.stale`.

---

## 8. Testing

Unit tests in `Tests/ClaudeUsageBarCoreTests/TeamActivityTests.swift`
(`import Testing`, `@Suite`), following the `ActiveBorrowTests` style:

- `classify` across boundaries: `nil` → `.neverPosted`; `0s` → `.active`;
  `9m59s`/`10m` → `.active`; `10m01s`/`15m` → `.idle`; `15m01s`/`20m`/`3h` →
  `.stale`; future timestamp → `.active`.
- Caption builder: both fields present; `resetAt` nil + `postedAt` present;
  `neverPosted` (no suffix); the `isStale` flag flips at `staleAfter`.

AppKit rendering (dot drawing, alpha) is not unit-tested, consistent with the
current app target; verified manually by running the app.

---

## 9. Out of scope / future

- Using `lastSeen` as a secondary presence signal (e.g. "seen 2m ago but no usage
  posted"). Not needed while post + board refresh are coupled.
- Real-time presence via server push.
- A dedicated "offline" treatment beyond the dot (e.g. greying the whole row).
- Reworking the footer "Updated …" line to reflect board-fetch time.
