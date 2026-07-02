> Do not run automatically — human-executed gate. Touches the live Claude Code Keychain item.

# Spike: Claude Code Keychain round-trip

Goal: prove Claudeometer can back up → overwrite → restore the
`Claude Code-credentials` item without corrupting a live Claude Code session,
and discover the item's `acct` attribute.

## 1. Discover the acct attribute
Command: `security find-generic-password -s "Claude Code-credentials"`
- Result (acct value): ____________________
- Does `parseAccountAttribute` extract it correctly? ☐ yes ☐ no

## 2. Back up the current blob
Command: `security find-generic-password -s "Claude Code-credentials" -w > /tmp/cc.bak`
- Result (byte count `wc -c /tmp/cc.bak`): ____________________

## 3. Overwrite in place with the SAME acct, then read back
Command:
`security add-generic-password -s "Claude Code-credentials" -a "<ACCT FROM STEP 1>" -U -w "$(cat /tmp/cc.bak)"`
then `security find-generic-password -s "Claude Code-credentials" -w | diff - /tmp/cc.bak`
- Round-trips identically (diff empty)? ☐ yes ☐ no
- Did macOS show an ACL/allow prompt? ☐ no ☐ yes (how many times): ____

## 4. Confirm Claude Code still works after an overwrite
- Run `claude` in a new terminal. Does it authenticate normally? ☐ yes ☐ no
- If it prompts to log in, the blob shape or acct is wrong — STOP and revisit.

## 5. Confirm a switch is picked up on next launch (not mid-session)
- Start a `claude` session, switch the item to a different blob, observe the
  running session is unaffected; a NEW `claude` uses the new blob. ☐ confirmed

## 6. Restore
Command: `security add-generic-password -s "Claude Code-credentials" -a "<ACCT>" -U -w "$(cat /tmp/cc.bak)"; rm /tmp/cc.bak`
- Restored and temp file removed? ☐ yes

## Decisions
- Write mechanism confirmed: `add-generic-password … -U` ☐ works ☐ needs change: ______
- acct attribute is stable across refreshes? ☐ yes ☐ no — if no, `AccountManager`
  must re-read it before each write (already does via `accountAttribute`).
- ACL prompt behavior acceptable (0 or one-time "Always Allow")? ☐ yes ☐ no: ______
