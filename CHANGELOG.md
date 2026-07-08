# Changelog

All notable changes to Claudeometer are documented here.
This project adheres to [Semantic Versioning](https://semver.org).

## [0.5.0] — 2026-07-09

### Changed
- Version-bump release with no functional changes — cut to verify the new
  in-repo Homebrew tap (`Casks/` in this repo) delivers upgrades end-to-end.

## [0.3.0] — 2026-07-08

### Added
- **Multiple teams.** Create, join, and leave more than one team from a new
  drill-in Teams hub (team list → per-team board). Team names are globally
  unique, owners approve join requests, and usage sharing + borrowing are
  scoped to each team — what you share with one team is redacted from others.
- **Team-board presence.** Boards now show who's online and how fresh each
  teammate's usage is, sorted online-first.

### Changed
- Borrowing is enforced within shared teams: one active borrow at a time, and
  at most one pending request per lender.

## [0.2.4] — 2026-07-02

### Added
- **Borrow-flow notifications.** The borrower is alerted when a request is
  approved, declined, about to end (~10 min), or has ended; the lender's request
  notification gains **Approve / Reject** actions; and the lender is told when a
  borrowed account is returned — alongside the existing usage-threshold alerts.

### Changed
- Proper reverse-DNS bundle identifier (`com.sgsi.claudeometer`) + ad-hoc
  code-signing, so the app has a consistent, registrable identity.

### Known limitation
- macOS **blocks notification delivery for unsigned / ad-hoc builds**
  (`UNErrorDomain 1` — "Notifications are not allowed for this application"). The
  notification code above is complete but stays **dormant until the app ships
  Developer ID-signed + notarized** (planned). The identifier change may also
  re-prompt once for Keychain + notification permission after upgrading.

## [0.2.3] — 2026-07-02

### Changed
- **Borrow eligibility is now relative.** A teammate's "Request" button appears only
  when *your* 5-hour usage is higher than theirs — you borrow from whoever is less
  depleted than you — replacing the fixed "under 50%" rule. The "N lendable" count
  follows the same logic.

## [0.2.2] — 2026-07-02

### Changed
- **Polished popover UI** — serif usage gauge, gradient bars, teammate avatars,
  pill tags, and a warm cream/terra palette matching the landing-page mockups.

### Fixed
- **Borrowing is now clearly shown.** While on a teammate's account, the popover
  shows the *borrowed* account's usage with an **"on <name>'s quota · time left"**
  banner, and that teammate's board row shows **"Borrowing · time left"** instead of
  offering another "Request".
- **Board attribution.** Your board entry always reports your *own* account (even
  while borrowing), and ending a borrow (switch back / auto-revert) now **revokes it
  on the relay** — so the "borrowing from…" tag clears instead of lingering the full
  window.
- **Menu-bar badge %** refreshes on every poll during the 90–100% blink (it was
  frozen at the value from when it crossed 90%, disagreeing with the popover).
- **No more duplicate "… (borrowed)" accounts** — borrowed logins are ephemeral
  (removed on revert) and no longer appear in the ••• menu as reusable.

## [0.2.1] — 2026-07-02

### Fixed
- **Board attribution while borrowing.** When you're on a teammate's borrowed
  account, the app now reports your **own** account's usage (not the lent one), and
  the board shows who is **borrowing from / lending to** whom — so a borrower is no
  longer mistaken for a heavy user of their own quota.

### Added
- **In-app team setup.** The app **prompts for the relay URL on first launch**
  (skippable) and adds a **"Set team relay URL…"** item to the ••• menu — both apply
  immediately, with no config files or relaunch. Install via Homebrew and configure
  entirely in-app.
- Active-borrow tags ("borrowing from…", "lending to…") on the Team page.

## [0.2.0] — 2026-07-02 — Team mode

Claudeometer grows from a personal usage meter into an opt-in **team account-pooling** tool.

### Added
- **Team usage board** — enroll with just a name and see every teammate's live 5-hour
  usage and when their window renews, so you know who has headroom before you're stuck.
- **Borrow a teammate's quota** — request a fixed window (default 2h); they approve from
  their menu bar and your Claude Code switches to their account, then **auto-reverts** when
  the window ends.
- **End-to-end encrypted transfer** — a lent credential is sealed (X25519 ECIES) directly to
  the borrower; the self-hosted relay only ever carries opaque ciphertext and never sees a token.
- **Local multi-account switch** — vault several Claude logins and one-click switch which one
  Claude Code uses, with a time-boxed auto-revert and a borrowed badge in the menu bar.
- **Two-page popover** — a compact personal page plus a separate **Team** page.
- **Self-hosted relay** (`relay/`) — a small Go + SQLite service with Ed25519-signed requests
  and a zero-knowledge mailbox; see `relay/PROTOCOL.md`.

### Notes
- Team mode is **opt-in and off by default**. The relay URL is configured locally
  (`CLAUDEOMETER_RELAY_URL` env or `~/Library/Application Support/Claudeometer/relay-url`) and
  is never hardcoded in the repo — with none set, Claudeometer stays a personal, offline meter.
- Credentials never touch disk in plaintext — they live only in the macOS Keychain.

## [0.1.0] — 2026-06-29 — Initial release

- Native macOS menu-bar meter for your Claude usage: the live 5-hour window with a
  green→red gradient and a mood emoji.
- Popover with burn rate + ETA, 7-day / Sonnet / Opus / OAuth-apps quotas, a 24h pace
  sparkline (30-day local history), and "Hot sessions" from your local Claude Code logs.
- Graduated notifications at 50 / 75 / 90 / 100% of the 5-hour window.
- Reads the Claude Code OAuth token from the macOS Keychain; everything stays on your Mac,
  no telemetry.

[0.2.4]: https://github.com/SGSI/claudeometer/releases/tag/v0.2.4
[0.2.3]: https://github.com/SGSI/claudeometer/releases/tag/v0.2.3
[0.2.2]: https://github.com/SGSI/claudeometer/releases/tag/v0.2.2
[0.2.1]: https://github.com/SGSI/claudeometer/releases/tag/v0.2.1
[0.2.0]: https://github.com/SGSI/claudeometer/releases/tag/v0.2.0
[0.1.0]: https://github.com/SGSI/claudeometer/releases/tag/v0.1.0
