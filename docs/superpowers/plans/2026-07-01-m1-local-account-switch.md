# M1 — Local Account Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Claudeometer store multiple Claude credentials locally as named accounts and one-click switch which one Claude Code uses, with automatic time-boxed revert — the local foundation of the "Claudeometer Teams" pooling product.

**Architecture:** Extract the new logic into a testable Swift library target `ClaudeUsageBarCore` (credential blob model, Keychain credential store, account vault, borrow-state math, and the switch/revert orchestrator). The existing executable target `ClaudeUsageBar` gains a thin `@MainActor` controller that drives the Core library and wires switching into the menu-bar UI. Credential blobs live only in the macOS Keychain; only non-secret account metadata is written to disk.

**Tech Stack:** Swift 6, Swift Package Manager, AppKit, CryptoKit (SHA-256 fingerprint), Swift Testing (`import Testing`) for unit tests, `/usr/bin/security` for Keychain I/O.

## Global Constraints

Every task's requirements implicitly include these (copied from the spec):

- **Platform:** macOS 13+; Swift tools 6.0.
- **Credentials are Keychain-only** — a credential blob must NEVER be written to disk in plaintext. Only metadata (`id, label, accountEmail, isSelf, addedAt`) and borrow state may be persisted to `~/Library/Application Support/Claudeometer/accounts.json`.
- **The Claude Code credential lives in the Keychain generic-password item with service name `Claude Code-credentials`.** Its blob shape is `{"claudeAiOauth":{"accessToken":...,"expiresAt":...,...}}`. Preserve the blob byte-for-byte when moving it.
- **Vault items** use service name `Claudeometer-account-<uuid>`.
- **Borrow defaults:** presets 30m / 1h / 2h; hard cap 4h; minimum 1m.
- **A switch takes effect on the next `claude` launch** (Claude Code caches credentials at start). Never claim to hijack a running session; warn instead.
- **Undocumented endpoints / soft expiry:** M1 does no networking; a session simply auto-reverts locally at `revertAt`.
- Follow the repo's existing Swift style (the app is currently a single large file; NEW logic goes in the new `ClaudeUsageBarCore` target rather than growing `main.swift`).

---

## File Structure

**New library target — `Sources/ClaudeUsageBarCore/`:**
- `Constants.swift` — shared service-name constants.
- `CredentialBlob.swift` — opaque credential blob (raw `Data`) + SHA-256 fingerprint + minimal decode (token suffix, expiry).
- `CredentialStore.swift` — `CredentialStore` protocol, `SecurityCommand` pure arg/parse helpers, errors.
- `SecurityCLICredentialStore.swift` — real `CredentialStore` over `/usr/bin/security`.
- `ActiveBorrow.swift` — borrow state struct + `remaining/isExpired` math + `BorrowDuration` presets/clamp.
- `Account.swift` — `Account`, `AccountsFile`, and the `AccountStore` metadata persistence.
- `AccountManager.swift` — capture / switch / revert orchestration over a `CredentialStore` + `AccountStore`.
- `ClaudeProcessDetector.swift` — "is `claude` running?" with an injectable process lister.

**New tests — `Tests/ClaudeUsageBarCoreTests/`:** one file per Core file above (except the CLI/process real impls, which are exercised via injectable seams + a manual runbook).

**Executable target — `Sources/ClaudeUsageBar/`:**
- `MultiAccountController.swift` — NEW `@MainActor` bridge: builds the real `AccountManager`, first-run self-capture, auto-revert timer, menu-item builder, badge state.
- `main.swift` — MODIFY: `import ClaudeUsageBarCore`; instantiate the controller; inject account menu items into the popover's `•••` menu; render the borrowed badge/countdown in the menu bar.

**Package + docs:**
- `Package.swift` — MODIFY: add the Core library target, the test target, and the executable's dependency on Core.
- `docs/superpowers/spikes/keychain-roundtrip.md` — NEW manual runbook produced by Task 3.

---

## Task 1: Scaffold Core library + test target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/ClaudeUsageBarCore/Constants.swift`
- Test: `Tests/ClaudeUsageBarCoreTests/ConstantsTests.swift`

**Interfaces:**
- Produces: `enum ClaudeometerConstants { static let claudeCodeKeychainService: String; static let vaultServicePrefix: String }`

- [ ] **Step 1: Rewrite `Package.swift` to add the Core + test targets**

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClaudeUsageBar", targets: ["ClaudeUsageBar"])
    ],
    targets: [
        .target(
            name: "ClaudeUsageBarCore",
            path: "Sources/ClaudeUsageBarCore"
        ),
        .executableTarget(
            name: "ClaudeUsageBar",
            dependencies: ["ClaudeUsageBarCore"],
            path: "Sources/ClaudeUsageBar"
        ),
        .testTarget(
            name: "ClaudeUsageBarCoreTests",
            dependencies: ["ClaudeUsageBarCore"],
            path: "Tests/ClaudeUsageBarCoreTests"
        )
    ]
)
```

- [ ] **Step 2: Create `Sources/ClaudeUsageBarCore/Constants.swift`**

```swift
import Foundation

/// Service names used to look up credential items in the macOS Keychain.
public enum ClaudeometerConstants {
    /// The generic-password service Claude Code itself uses.
    public static let claudeCodeKeychainService = "Claude Code-credentials"
    /// Prefix for Claudeometer's own vault items: `Claudeometer-account-<uuid>`.
    public static let vaultServicePrefix = "Claudeometer-account-"
}
```

- [ ] **Step 3: Write the failing test `Tests/ClaudeUsageBarCoreTests/ConstantsTests.swift`**

```swift
import Testing
@testable import ClaudeUsageBarCore

@Suite struct ConstantsTests {
    @Test func serviceNames() {
        #expect(ClaudeometerConstants.claudeCodeKeychainService == "Claude Code-credentials")
        #expect(ClaudeometerConstants.vaultServicePrefix == "Claudeometer-account-")
    }
}
```

- [ ] **Step 4: Build and run tests to verify the target wiring works**

Run: `swift build && swift test --filter ConstantsTests`
Expected: PASS — 1 test passes. (This proves the three-target package and the Swift Testing harness compile and run.)

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/ClaudeUsageBarCore/Constants.swift Tests/ClaudeUsageBarCoreTests/ConstantsTests.swift
git commit -m "chore: scaffold ClaudeUsageBarCore library and test target"
```

---

## Task 2: `CredentialBlob` — opaque blob with fingerprint + decode

**Files:**
- Create: `Sources/ClaudeUsageBarCore/CredentialBlob.swift`
- Test: `Tests/ClaudeUsageBarCoreTests/CredentialBlobTests.swift`

**Interfaces:**
- Produces:
  - `struct CredentialBlob { let raw: Data; var fingerprint: String; func decoded() -> DecodedCredential? }`
  - `struct DecodedCredential { let accessTokenSuffix: String; let expiresAtMillis: Int64; func isExpired(now: Date) -> Bool }`

- [ ] **Step 1: Write the failing tests `Tests/ClaudeUsageBarCoreTests/CredentialBlobTests.swift`**

```swift
import Testing
import Foundation
@testable import ClaudeUsageBarCore

@Suite struct CredentialBlobTests {
    let sample = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-abcd1234","expiresAt":1893456000000}}"#.utf8)

    @Test func decodesTokenSuffixAndExpiry() {
        let decoded = CredentialBlob(raw: sample).decoded()
        #expect(decoded?.accessTokenSuffix == "abcd1234")
        #expect(decoded?.expiresAtMillis == 1893456000000)
    }

    @Test func fingerprintIsStableAndContentSensitive() {
        let a = CredentialBlob(raw: sample).fingerprint
        let b = CredentialBlob(raw: sample).fingerprint
        let c = CredentialBlob(raw: Data("{}".utf8)).fingerprint
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 64) // hex SHA-256
    }

    @Test func expiryComparison() {
        let d = DecodedCredential(accessTokenSuffix: "x", expiresAtMillis: 1000) // 1000 ms
        #expect(d.isExpired(now: Date(timeIntervalSince1970: 2)) == true)    // 2000 ms > 1000
        #expect(d.isExpired(now: Date(timeIntervalSince1970: 0.5)) == false) // 500 ms < 1000
    }

    @Test func zeroExpiryNeverExpires() {
        let d = DecodedCredential(accessTokenSuffix: "x", expiresAtMillis: 0)
        #expect(d.isExpired(now: Date(timeIntervalSince1970: 9_999_999_999)) == false)
    }

    @Test func malformedBlobDecodesToNil() {
        #expect(CredentialBlob(raw: Data("not json".utf8)).decoded() == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CredentialBlobTests`
Expected: FAIL — build error: cannot find `CredentialBlob` / `DecodedCredential` in scope.

- [ ] **Step 3: Create `Sources/ClaudeUsageBarCore/CredentialBlob.swift`**

```swift
import Foundation
import CryptoKit

/// A decoded, non-secret view of a credential blob.
public struct DecodedCredential: Equatable, Sendable {
    public let accessTokenSuffix: String
    public let expiresAtMillis: Int64

    public init(accessTokenSuffix: String, expiresAtMillis: Int64) {
        self.accessTokenSuffix = accessTokenSuffix
        self.expiresAtMillis = expiresAtMillis
    }

    /// True when the credential's expiry has passed. Expiry of 0 means "no expiry known".
    public func isExpired(now: Date) -> Bool {
        guard expiresAtMillis > 0 else { return false }
        return Double(expiresAtMillis) < now.timeIntervalSince1970 * 1000
    }
}

/// An opaque Claude credential blob. The raw bytes are preserved verbatim so the
/// blob can be moved between Keychain items without corruption.
public struct CredentialBlob: Equatable, Sendable {
    public let raw: Data

    public init(raw: Data) {
        self.raw = raw
    }

    /// A stable content fingerprint (hex SHA-256) used to tell two blobs apart
    /// without exposing the secret.
    public var fingerprint: String {
        SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }

    /// Best-effort decode of the non-secret fields we care about. Returns nil for
    /// malformed input.
    public func decoded() -> DecodedCredential? {
        struct Blob: Decodable { let claudeAiOauth: OAuth }
        struct OAuth: Decodable { let accessToken: String; let expiresAt: Int64? }
        guard let blob = try? JSONDecoder().decode(Blob.self, from: raw) else { return nil }
        return DecodedCredential(
            accessTokenSuffix: String(blob.claudeAiOauth.accessToken.suffix(8)),
            expiresAtMillis: blob.claudeAiOauth.expiresAt ?? 0
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CredentialBlobTests`
Expected: PASS — 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsageBarCore/CredentialBlob.swift Tests/ClaudeUsageBarCoreTests/CredentialBlobTests.swift
git commit -m "feat: add CredentialBlob with fingerprint and decode"
```

---

## Task 3: `CredentialStore` protocol, `security` command helpers, real store + Keychain spike

**Files:**
- Create: `Sources/ClaudeUsageBarCore/CredentialStore.swift`
- Create: `Sources/ClaudeUsageBarCore/SecurityCLICredentialStore.swift`
- Create: `docs/superpowers/spikes/keychain-roundtrip.md`
- Test: `Tests/ClaudeUsageBarCoreTests/SecurityCommandTests.swift`

**Interfaces:**
- Consumes: `CredentialBlob` (Task 2), `ClaudeometerConstants` (Task 1).
- Produces:
  - `protocol CredentialStore { func read(service: String) throws -> CredentialBlob?; func write(service: String, account: String, blob: CredentialBlob) throws; func delete(service: String) throws; func accountAttribute(service: String) throws -> String? }`
  - `enum CredentialStoreError: Error, Equatable { case commandFailed(status: Int32, message: String) }`
  - `enum SecurityCommand` with pure `readArgs/writeArgs/deleteArgs/attributesArgs` and `parseAccountAttribute(from:)`, plus `itemNotFoundStatus: Int32`.
  - `struct SecurityCLICredentialStore: CredentialStore`

> **This task carries the highest-risk unknown (writing the Claude-Code-owned Keychain item).** The pure argument builders and the attribute parser are unit-tested; the real process execution against the live Keychain is proven by the manual runbook in Step 6 before the store is trusted by later tasks.

- [ ] **Step 1: Write the failing tests `Tests/ClaudeUsageBarCoreTests/SecurityCommandTests.swift`**

```swift
import Testing
@testable import ClaudeUsageBarCore

@Suite struct SecurityCommandTests {
    @Test func readArgs() {
        #expect(SecurityCommand.readArgs(service: "svc") == ["find-generic-password", "-s", "svc", "-w"])
    }

    @Test func writeArgsUseUpdateFlag() {
        #expect(SecurityCommand.writeArgs(service: "svc", account: "acct", secret: "S")
                == ["add-generic-password", "-s", "svc", "-a", "acct", "-U", "-w", "S"])
    }

    @Test func deleteArgs() {
        #expect(SecurityCommand.deleteArgs(service: "svc") == ["delete-generic-password", "-s", "svc"])
    }

    @Test func attributesArgs() {
        #expect(SecurityCommand.attributesArgs(service: "svc") == ["find-generic-password", "-s", "svc"])
    }

    @Test func parseAccountAttributeQuotedForm() {
        let dump = """
        keychain: "/Users/x/Library/Keychains/login.keychain-db"
            "acct"<blob>="Claude Code"
            "svce"<blob>="Claude Code-credentials"
        """
        #expect(SecurityCommand.parseAccountAttribute(from: dump) == "Claude Code")
    }

    @Test func parseAccountAttributeHexForm() {
        let dump = #"    "acct"<blob>=0x61626364  "abcd""#
        #expect(SecurityCommand.parseAccountAttribute(from: dump) == "abcd")
    }

    @Test func parseAccountAttributeMissing() {
        #expect(SecurityCommand.parseAccountAttribute(from: "no acct here") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SecurityCommandTests`
Expected: FAIL — build error: cannot find `SecurityCommand` in scope.

- [ ] **Step 3: Create `Sources/ClaudeUsageBarCore/CredentialStore.swift`**

```swift
import Foundation

/// Abstraction over Keychain credential storage so business logic can be tested
/// with an in-memory fake.
public protocol CredentialStore: Sendable {
    /// Returns the blob for `service`, or nil if no such item exists.
    func read(service: String) throws -> CredentialBlob?
    /// Creates or updates (`-U`) the item for `service`/`account`.
    func write(service: String, account: String, blob: CredentialBlob) throws
    /// Deletes the item for `service`. A missing item is not an error.
    func delete(service: String) throws
    /// The `acct` attribute of an existing item, needed to update it in place.
    func accountAttribute(service: String) throws -> String?
}

public enum CredentialStoreError: Error, Equatable {
    case commandFailed(status: Int32, message: String)
}

/// Pure builders/parsers for `/usr/bin/security` invocations (unit-tested).
public enum SecurityCommand {
    public static let executable = "/usr/bin/security"
    /// `security` returns this exit code when an item is not found.
    public static let itemNotFoundStatus: Int32 = 44

    public static func readArgs(service: String) -> [String] {
        ["find-generic-password", "-s", service, "-w"]
    }

    public static func writeArgs(service: String, account: String, secret: String) -> [String] {
        ["add-generic-password", "-s", service, "-a", account, "-U", "-w", secret]
    }

    public static func deleteArgs(service: String) -> [String] {
        ["delete-generic-password", "-s", service]
    }

    public static func attributesArgs(service: String) -> [String] {
        ["find-generic-password", "-s", service]
    }

    /// Extracts the `acct` attribute value from a `security find-generic-password`
    /// attribute dump. Handles both the quoted (`="value"`) and hex-blob
    /// (`=0x..  "value"`) forms `security` emits.
    public static func parseAccountAttribute(from dump: String) -> String? {
        for line in dump.split(separator: "\n") where line.contains("\"acct\"") {
            guard let eq = line.range(of: "=") else { continue }
            let rhs = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            if rhs.hasPrefix("0x") {
                // Hex form: the human-readable value follows in quotes.
                if let open = rhs.range(of: "\"") {
                    let after = rhs[open.upperBound...]
                    if let close = after.range(of: "\"") {
                        return String(after[..<close.lowerBound])
                    }
                }
                continue
            }
            if rhs.hasPrefix("\""), rhs.hasSuffix("\""), rhs.count >= 2 {
                return String(rhs.dropFirst().dropLast())
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Create `Sources/ClaudeUsageBarCore/SecurityCLICredentialStore.swift`**

```swift
import Foundation

/// Real `CredentialStore` backed by `/usr/bin/security`.
public struct SecurityCLICredentialStore: CredentialStore {
    public init() {}

    public func read(service: String) throws -> CredentialBlob? {
        let result = run(SecurityCommand.readArgs(service: service))
        if result.status == SecurityCommand.itemNotFoundStatus { return nil }
        guard result.status == 0 else {
            throw CredentialStoreError.commandFailed(status: result.status, message: result.stderr)
        }
        // `security -w` prints the secret followed by a trailing newline.
        var out = result.stdout
        if out.hasSuffix("\n") { out.removeLast() }
        return CredentialBlob(raw: Data(out.utf8))
    }

    public func write(service: String, account: String, blob: CredentialBlob) throws {
        let secret = String(decoding: blob.raw, as: UTF8.self)
        let result = run(SecurityCommand.writeArgs(service: service, account: account, secret: secret))
        guard result.status == 0 else {
            throw CredentialStoreError.commandFailed(status: result.status, message: result.stderr)
        }
    }

    public func delete(service: String) throws {
        let result = run(SecurityCommand.deleteArgs(service: service))
        guard result.status == 0 || result.status == SecurityCommand.itemNotFoundStatus else {
            throw CredentialStoreError.commandFailed(status: result.status, message: result.stderr)
        }
    }

    public func accountAttribute(service: String) throws -> String? {
        let result = run(SecurityCommand.attributesArgs(service: service))
        if result.status == SecurityCommand.itemNotFoundStatus { return nil }
        guard result.status == 0 else {
            throw CredentialStoreError.commandFailed(status: result.status, message: result.stderr)
        }
        // Attributes are printed to stdout; some `security` versions use stderr.
        return SecurityCommand.parseAccountAttribute(from: result.stdout + "\n" + result.stderr)
    }

    private func run(_ args: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SecurityCommand.executable)
        process.arguments = args
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", "\(error)") }
        process.waitUntilExit()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, stdout, stderr)
    }
}
```

- [ ] **Step 5: Run the unit tests to verify they pass**

Run: `swift test --filter SecurityCommandTests`
Expected: PASS — 7 tests pass.

- [ ] **Step 6: Run the Keychain round-trip spike and record findings**

Create `docs/superpowers/spikes/keychain-roundtrip.md` with the runbook below, then execute each command in a terminal and fill in the **Result** lines. **Do NOT proceed to Task 4 until the round-trip is proven safe.**

````markdown
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
````

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeUsageBarCore/CredentialStore.swift Sources/ClaudeUsageBarCore/SecurityCLICredentialStore.swift Tests/ClaudeUsageBarCoreTests/SecurityCommandTests.swift docs/superpowers/spikes/keychain-roundtrip.md
git commit -m "feat: add CredentialStore, security CLI store, and keychain round-trip spike"
```

---

## Task 4: `ActiveBorrow` + `BorrowDuration` math

**Files:**
- Create: `Sources/ClaudeUsageBarCore/ActiveBorrow.swift`
- Test: `Tests/ClaudeUsageBarCoreTests/ActiveBorrowTests.swift`

**Interfaces:**
- Produces:
  - `struct ActiveBorrow: Codable, Equatable, Sendable { let activeAccountId: UUID; let selfAccountId: UUID; let startedAt: Date; let revertAt: Date; func remaining(now: Date) -> TimeInterval; func isExpired(now: Date) -> Bool }`
  - `enum BorrowDuration { static let presets: [TimeInterval]; static let maxInterval: TimeInterval; static let minInterval: TimeInterval; static func clamp(_:) -> TimeInterval }`

- [ ] **Step 1: Write the failing tests `Tests/ClaudeUsageBarCoreTests/ActiveBorrowTests.swift`**

```swift
import Testing
import Foundation
@testable import ClaudeUsageBarCore

@Suite struct ActiveBorrowTests {
    let selfId = UUID()
    let otherId = UUID()

    func makeBorrow(start: TimeInterval, revert: TimeInterval) -> ActiveBorrow {
        ActiveBorrow(activeAccountId: otherId, selfAccountId: selfId,
                     startedAt: Date(timeIntervalSince1970: start),
                     revertAt: Date(timeIntervalSince1970: revert))
    }

    @Test func remainingCountsDown() {
        let b = makeBorrow(start: 0, revert: 7200)
        #expect(b.remaining(now: Date(timeIntervalSince1970: 0)) == 7200)
        #expect(b.remaining(now: Date(timeIntervalSince1970: 3600)) == 3600)
    }

    @Test func remainingNeverNegative() {
        let b = makeBorrow(start: 0, revert: 7200)
        #expect(b.remaining(now: Date(timeIntervalSince1970: 9000)) == 0)
    }

    @Test func expiryBoundary() {
        let b = makeBorrow(start: 0, revert: 7200)
        #expect(b.isExpired(now: Date(timeIntervalSince1970: 7199)) == false)
        #expect(b.isExpired(now: Date(timeIntervalSince1970: 7200)) == true)
    }

    @Test func clampToBounds() {
        #expect(BorrowDuration.clamp(10) == BorrowDuration.minInterval)         // below min
        #expect(BorrowDuration.clamp(2 * 3600) == 2 * 3600)                     // in range
        #expect(BorrowDuration.clamp(9 * 3600) == BorrowDuration.maxInterval)   // above cap
    }

    @Test func presetsAreThirtyOneAndTwoHours() {
        #expect(BorrowDuration.presets == [1800, 3600, 7200])
        #expect(BorrowDuration.maxInterval == 14400)
    }

    @Test func codableRoundTrip() throws {
        let b = makeBorrow(start: 100, revert: 7300)
        let data = try JSONEncoder().encode(b)
        let back = try JSONDecoder().decode(ActiveBorrow.self, from: data)
        #expect(back == b)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ActiveBorrowTests`
Expected: FAIL — build error: cannot find `ActiveBorrow` / `BorrowDuration` in scope.

- [ ] **Step 3: Create `Sources/ClaudeUsageBarCore/ActiveBorrow.swift`**

```swift
import Foundation

/// Records which account is currently written into the Claude Code credential
/// item and which account to restore when the window ends.
public struct ActiveBorrow: Codable, Equatable, Sendable {
    public let activeAccountId: UUID
    public let selfAccountId: UUID
    public let startedAt: Date
    public let revertAt: Date

    public init(activeAccountId: UUID, selfAccountId: UUID, startedAt: Date, revertAt: Date) {
        self.activeAccountId = activeAccountId
        self.selfAccountId = selfAccountId
        self.startedAt = startedAt
        self.revertAt = revertAt
    }

    public func remaining(now: Date) -> TimeInterval {
        max(0, revertAt.timeIntervalSince(now))
    }

    public func isExpired(now: Date) -> Bool {
        now >= revertAt
    }
}

/// Borrow-window duration policy.
public enum BorrowDuration {
    public static let minInterval: TimeInterval = 60          // 1 minute
    public static let maxInterval: TimeInterval = 4 * 60 * 60 // 4 hours
    public static let presets: [TimeInterval] = [30 * 60, 60 * 60, 120 * 60]

    public static func clamp(_ interval: TimeInterval) -> TimeInterval {
        min(max(interval, minInterval), maxInterval)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ActiveBorrowTests`
Expected: PASS — 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsageBarCore/ActiveBorrow.swift Tests/ClaudeUsageBarCoreTests/ActiveBorrowTests.swift
git commit -m "feat: add ActiveBorrow state and BorrowDuration policy"
```

---

## Task 5: `Account`, `AccountsFile`, and `AccountStore` persistence

**Files:**
- Create: `Sources/ClaudeUsageBarCore/Account.swift`
- Test: `Tests/ClaudeUsageBarCoreTests/AccountStoreTests.swift`

**Interfaces:**
- Consumes: `ActiveBorrow` (Task 4).
- Produces:
  - `struct Account: Codable, Equatable, Identifiable, Sendable { let id: UUID; var label: String; var accountEmail: String?; var isSelf: Bool; let addedAt: Date; var keychainService: String }`
  - `struct AccountsFile: Codable, Equatable, Sendable { var accounts: [Account]; var activeBorrow: ActiveBorrow?; var selfAccount: Account?; func account(id:) -> Account? }`
  - `final class AccountStore { init(directory: URL); func load() -> AccountsFile; func save(_:) throws }`

- [ ] **Step 1: Write the failing tests `Tests/ClaudeUsageBarCoreTests/AccountStoreTests.swift`**

```swift
import Testing
import Foundation
@testable import ClaudeUsageBarCore

@Suite struct AccountStoreTests {
    /// Fresh temp dir per test.
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadMissingReturnsEmpty() throws {
        let store = AccountStore(directory: try tempDir())
        #expect(store.load() == AccountsFile())
    }

    @Test func saveThenLoadRoundTrips() throws {
        let dir = try tempDir()
        let store = AccountStore(directory: dir)
        let account = Account(id: UUID(), label: "Priya", accountEmail: nil, isSelf: false,
                              addedAt: Date(timeIntervalSince1970: 42))
        try store.save(AccountsFile(accounts: [account], activeBorrow: nil))
        #expect(store.load().accounts == [account])
    }

    @Test func keychainServiceUsesPrefix() {
        let id = UUID()
        let account = Account(id: id, label: "x", accountEmail: nil, isSelf: false, addedAt: Date())
        #expect(account.keychainService == "Claudeometer-account-\(id.uuidString)")
    }

    @Test func selfAccountAndLookup() {
        let me = Account(id: UUID(), label: "Me", accountEmail: nil, isSelf: true, addedAt: Date())
        let other = Account(id: UUID(), label: "Priya", accountEmail: nil, isSelf: false, addedAt: Date())
        let file = AccountsFile(accounts: [me, other], activeBorrow: nil)
        #expect(file.selfAccount == me)
        #expect(file.account(id: other.id) == other)
        #expect(file.account(id: UUID()) == nil)
    }

    @Test func persistedFileHasNoRawSecret() throws {
        // Guardrail: metadata store must never contain a token; only labels/ids.
        let dir = try tempDir()
        let store = AccountStore(directory: dir)
        let account = Account(id: UUID(), label: "Priya", accountEmail: "p@example.com", isSelf: false, addedAt: Date())
        try store.save(AccountsFile(accounts: [account], activeBorrow: nil))
        let json = try String(contentsOf: dir.appendingPathComponent("accounts.json"), encoding: .utf8)
        #expect(json.contains("Priya"))
        #expect(json.contains("accessToken") == false)
        #expect(json.contains("claudeAiOauth") == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AccountStoreTests`
Expected: FAIL — build error: cannot find `Account` / `AccountsFile` / `AccountStore` in scope.

- [ ] **Step 3: Create `Sources/ClaudeUsageBarCore/Account.swift`**

```swift
import Foundation

/// Non-secret metadata for one vaulted Claude account. The credential blob is
/// stored separately in the Keychain under `keychainService`.
public struct Account: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var label: String
    public var accountEmail: String?
    public var isSelf: Bool
    public let addedAt: Date

    public init(id: UUID, label: String, accountEmail: String?, isSelf: Bool, addedAt: Date) {
        self.id = id
        self.label = label
        self.accountEmail = accountEmail
        self.isSelf = isSelf
        self.addedAt = addedAt
    }

    public var keychainService: String {
        ClaudeometerConstants.vaultServicePrefix + id.uuidString
    }
}

/// The full on-disk state: the vaulted accounts plus the current borrow, if any.
public struct AccountsFile: Codable, Equatable, Sendable {
    public var accounts: [Account]
    public var activeBorrow: ActiveBorrow?

    public init(accounts: [Account] = [], activeBorrow: ActiveBorrow? = nil) {
        self.accounts = accounts
        self.activeBorrow = activeBorrow
    }

    public var selfAccount: Account? {
        accounts.first { $0.isSelf }
    }

    public func account(id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }
}

/// Persists `AccountsFile` as `accounts.json` in the given directory. Secrets are
/// NEVER written here — only metadata and borrow state.
public final class AccountStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("accounts.json")
    }

    public func load() -> AccountsFile {
        guard let data = try? Data(contentsOf: fileURL) else { return AccountsFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AccountsFile.self, from: data)) ?? AccountsFile()
    }

    public func save(_ file: AccountsFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AccountStoreTests`
Expected: PASS — 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsageBarCore/Account.swift Tests/ClaudeUsageBarCoreTests/AccountStoreTests.swift
git commit -m "feat: add Account model and AccountStore persistence"
```

---

## Task 6: `AccountManager` — capture / switch / revert orchestration

**Files:**
- Create: `Sources/ClaudeUsageBarCore/AccountManager.swift`
- Test: `Tests/ClaudeUsageBarCoreTests/AccountManagerTests.swift`

**Interfaces:**
- Consumes: `CredentialStore` (Task 3), `AccountStore` + `Account` + `AccountsFile` (Task 5), `ActiveBorrow` + `BorrowDuration` (Task 4), `CredentialBlob` (Task 2).
- Produces:
  - `struct AccountManager { init(credentialStore:store:claudeCodeService:now:); func captureCurrent(label:isSelf:) throws -> Account; func switchTo(accountId:duration:) throws; func revert() throws; func snapshot() -> AccountsFile }`
  - `enum AccountManager.ManagerError: Error, Equatable { case noSelfAccount, accountNotFound, noActiveClaudeCredential }`

**Design notes for the implementer:**
- The Claude Code item is updated in place with `-U`, and updating requires its
  `acct` attribute. The manager reads that attribute live via
  `credentialStore.accountAttribute(service:)` before each write, falling back to
  a captured value — so it survives Claude Code rotating the item.
- `switchTo` only refreshes the SELF backup from the live Claude Code item when we
  are **not already borrowing** (otherwise we would overwrite self's real backup
  with a borrowed blob).
- Switching to the self account is equivalent to `revert()`.

- [ ] **Step 1: Write the failing tests `Tests/ClaudeUsageBarCoreTests/AccountManagerTests.swift`**

```swift
import Testing
import Foundation
@testable import ClaudeUsageBarCore

/// In-memory CredentialStore for deterministic tests.
final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    var items: [String: CredentialBlob] = [:]
    var acctAttribute: String? = "Claude Code"

    func read(service: String) throws -> CredentialBlob? { items[service] }
    func write(service: String, account: String, blob: CredentialBlob) throws { items[service] = blob }
    func delete(service: String) throws { items[service] = nil }
    func accountAttribute(service: String) throws -> String? { acctAttribute }
}

@Suite struct AccountManagerTests {
    let ccService = ClaudeometerConstants.claudeCodeKeychainService

    func makeManager(_ fake: FakeCredentialStore, dir: URL, now: @escaping () -> Date = { Date(timeIntervalSince1970: 1000) }) -> AccountManager {
        AccountManager(credentialStore: fake, store: AccountStore(directory: dir), now: now)
    }

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cbmgr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func blob(_ s: String) -> CredentialBlob { CredentialBlob(raw: Data(s.utf8)) }

    @Test func captureSelfStoresBlobAndMarksSelf() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())

        let account = try mgr.captureCurrent(label: "Me", isSelf: true)

        #expect(account.isSelf == true)
        #expect(fake.items[account.keychainService] == blob("MY-CREDS"))
        #expect(mgr.snapshot().selfAccount?.id == account.id)
    }

    @Test func captureWithNoActiveCredentialThrows() throws {
        let mgr = makeManager(FakeCredentialStore(), dir: try tempDir())
        #expect(throws: AccountManager.ManagerError.noActiveClaudeCredential) {
            try mgr.captureCurrent(label: "Me", isSelf: true)
        }
    }

    @Test func onlyOneSelfAccount() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("A")
        let mgr = makeManager(fake, dir: try tempDir())
        _ = try mgr.captureCurrent(label: "Me", isSelf: true)
        fake.items[ccService] = blob("B")
        _ = try mgr.captureCurrent(label: "NewMe", isSelf: true)
        #expect(mgr.snapshot().accounts.filter { $0.isSelf }.count == 1)
    }

    @Test func switchWritesTargetBlobAndRecordsBorrow() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())
        let me = try mgr.captureCurrent(label: "Me", isSelf: true)
        fake.items[ccService] = blob("PRIYA-CREDS")
        let priya = try mgr.captureCurrent(label: "Priya", isSelf: false)
        // restore my creds as the active item before switching
        fake.items[ccService] = blob("MY-CREDS")

        try mgr.switchTo(accountId: priya.id, duration: 7200)

        #expect(fake.items[ccService] == blob("PRIYA-CREDS"))         // active is Priya
        #expect(fake.items[me.keychainService] == blob("MY-CREDS"))   // self backed up
        let borrow = mgr.snapshot().activeBorrow
        #expect(borrow?.activeAccountId == priya.id)
        #expect(borrow?.selfAccountId == me.id)
        #expect(borrow?.revertAt == Date(timeIntervalSince1970: 1000 + 7200))
    }

    @Test func revertRestoresSelf() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())
        _ = try mgr.captureCurrent(label: "Me", isSelf: true)
        fake.items[ccService] = blob("PRIYA-CREDS")
        let priya = try mgr.captureCurrent(label: "Priya", isSelf: false)
        fake.items[ccService] = blob("MY-CREDS")
        try mgr.switchTo(accountId: priya.id, duration: 7200)

        try mgr.revert()

        #expect(fake.items[ccService] == blob("MY-CREDS"))
        #expect(mgr.snapshot().activeBorrow == nil)
    }

    @Test func switchingWhileBorrowingKeepsSelfBackupIntact() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())
        let me = try mgr.captureCurrent(label: "Me", isSelf: true)
        fake.items[ccService] = blob("A-CREDS"); let a = try mgr.captureCurrent(label: "A", isSelf: false)
        fake.items[ccService] = blob("B-CREDS"); let b = try mgr.captureCurrent(label: "B", isSelf: false)
        fake.items[ccService] = blob("MY-CREDS")

        try mgr.switchTo(accountId: a.id, duration: 3600)   // now borrowing A (self backed up)
        try mgr.switchTo(accountId: b.id, duration: 3600)   // switch to B while borrowing

        #expect(fake.items[ccService] == blob("B-CREDS"))
        #expect(fake.items[me.keychainService] == blob("MY-CREDS")) // self NOT clobbered by A's blob
        #expect(mgr.snapshot().activeBorrow?.activeAccountId == b.id)
    }

    @Test func switchingToSelfReverts() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())
        let me = try mgr.captureCurrent(label: "Me", isSelf: true)
        fake.items[ccService] = blob("PRIYA-CREDS"); let priya = try mgr.captureCurrent(label: "Priya", isSelf: false)
        fake.items[ccService] = blob("MY-CREDS")
        try mgr.switchTo(accountId: priya.id, duration: 3600)

        try mgr.switchTo(accountId: me.id, duration: 3600)

        #expect(fake.items[ccService] == blob("MY-CREDS"))
        #expect(mgr.snapshot().activeBorrow == nil)
    }

    @Test func switchToUnknownAccountThrows() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())
        _ = try mgr.captureCurrent(label: "Me", isSelf: true)
        #expect(throws: AccountManager.ManagerError.accountNotFound) {
            try mgr.switchTo(accountId: UUID(), duration: 3600)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AccountManagerTests`
Expected: FAIL — build error: cannot find `AccountManager` in scope.

- [ ] **Step 3: Create `Sources/ClaudeUsageBarCore/AccountManager.swift`**

```swift
import Foundation

/// Orchestrates capturing, switching, and reverting accounts by moving credential
/// blobs between the Claude Code Keychain item and per-account vault items.
public struct AccountManager {
    private let credentialStore: CredentialStore
    private let store: AccountStore
    private let claudeCodeService: String
    private let now: () -> Date

    public enum ManagerError: Error, Equatable {
        case noSelfAccount
        case accountNotFound
        case noActiveClaudeCredential
    }

    public init(credentialStore: CredentialStore,
                store: AccountStore,
                claudeCodeService: String = ClaudeometerConstants.claudeCodeKeychainService,
                now: @escaping () -> Date = Date.init) {
        self.credentialStore = credentialStore
        self.store = store
        self.claudeCodeService = claudeCodeService
        self.now = now
    }

    /// The `acct` attribute needed to update the Claude Code item in place.
    private func claudeCodeAccount() -> String {
        (try? credentialStore.accountAttribute(service: claudeCodeService)) ?? "Claude Code"
    }

    /// Snapshots whatever is currently in the Claude Code item into a new vault
    /// account. Marking `isSelf` clears any previous self flag.
    @discardableResult
    public func captureCurrent(label: String, isSelf: Bool) throws -> Account {
        guard let blob = try credentialStore.read(service: claudeCodeService) else {
            throw ManagerError.noActiveClaudeCredential
        }
        var file = store.load()
        let email = blob.decoded().map { "…\($0.accessTokenSuffix)" }
        let account = Account(id: UUID(), label: label, accountEmail: email, isSelf: isSelf, addedAt: now())
        try credentialStore.write(service: account.keychainService, account: account.id.uuidString, blob: blob)
        if isSelf {
            file.accounts = file.accounts.map { var a = $0; a.isSelf = false; return a }
        }
        file.accounts.append(account)
        try store.save(file)
        return account
    }

    /// Switches the Claude Code item to `accountId`'s blob for `duration` seconds.
    /// Switching to the self account is equivalent to `revert()`.
    public func switchTo(accountId: UUID, duration: TimeInterval) throws {
        var file = store.load()
        guard let target = file.account(id: accountId) else { throw ManagerError.accountNotFound }
        guard let selfAccount = file.selfAccount else { throw ManagerError.noSelfAccount }

        if target.isSelf {
            try revert()
            return
        }

        // Keep self's backup current only when we are not already borrowing.
        if file.activeBorrow == nil, let current = try credentialStore.read(service: claudeCodeService) {
            try credentialStore.write(service: selfAccount.keychainService,
                                      account: selfAccount.id.uuidString, blob: current)
        }

        guard let targetBlob = try credentialStore.read(service: target.keychainService) else {
            throw ManagerError.accountNotFound
        }
        try credentialStore.write(service: claudeCodeService, account: claudeCodeAccount(), blob: targetBlob)

        file = store.load() // reload in case captureCurrent above changed it
        file.activeBorrow = ActiveBorrow(
            activeAccountId: target.id,
            selfAccountId: selfAccount.id,
            startedAt: now(),
            revertAt: now().addingTimeInterval(BorrowDuration.clamp(duration))
        )
        try store.save(file)
    }

    /// Restores the self account's blob into the Claude Code item and clears the
    /// borrow. No-op when not borrowing.
    public func revert() throws {
        var file = store.load()
        guard let borrow = file.activeBorrow else { return }
        guard let selfAccount = file.account(id: borrow.selfAccountId) else { throw ManagerError.noSelfAccount }
        guard let selfBlob = try credentialStore.read(service: selfAccount.keychainService) else {
            throw ManagerError.noActiveClaudeCredential
        }
        try credentialStore.write(service: claudeCodeService, account: claudeCodeAccount(), blob: selfBlob)
        file.activeBorrow = nil
        try store.save(file)
    }

    public func snapshot() -> AccountsFile {
        store.load()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AccountManagerTests`
Expected: PASS — 8 tests pass.

- [ ] **Step 5: Run the full Core suite to confirm no regressions**

Run: `swift test`
Expected: PASS — all suites green.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeUsageBarCore/AccountManager.swift Tests/ClaudeUsageBarCoreTests/AccountManagerTests.swift
git commit -m "feat: add AccountManager capture/switch/revert orchestration"
```

---

## Task 7: `ClaudeProcessDetector` — running-`claude` warning

**Files:**
- Create: `Sources/ClaudeUsageBarCore/ClaudeProcessDetector.swift`
- Test: `Tests/ClaudeUsageBarCoreTests/ClaudeProcessDetectorTests.swift`

**Interfaces:**
- Produces: `struct ClaudeProcessDetector { init(lister: @escaping () -> [String]); func isClaudeRunning() -> Bool; static func pgrepLister() -> [String] }`

- [ ] **Step 1: Write the failing tests `Tests/ClaudeUsageBarCoreTests/ClaudeProcessDetectorTests.swift`**

```swift
import Testing
@testable import ClaudeUsageBarCore

@Suite struct ClaudeProcessDetectorTests {
    @Test func detectsExactName() {
        let d = ClaudeProcessDetector(lister: { ["node", "claude", "zsh"] })
        #expect(d.isClaudeRunning() == true)
    }

    @Test func detectsPathSuffix() {
        let d = ClaudeProcessDetector(lister: { ["/Users/x/.claude/local/claude"] })
        #expect(d.isClaudeRunning() == true)
    }

    @Test func ignoresUnrelatedProcesses() {
        let d = ClaudeProcessDetector(lister: { ["claudeometer", "node", "Claude"] })
        #expect(d.isClaudeRunning() == false)  // "claudeometer" and the desktop "Claude" app are not the CLI
    }

    @Test func emptyListIsNotRunning() {
        #expect(ClaudeProcessDetector(lister: { [] }).isClaudeRunning() == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClaudeProcessDetectorTests`
Expected: FAIL — build error: cannot find `ClaudeProcessDetector` in scope.

- [ ] **Step 3: Create `Sources/ClaudeUsageBarCore/ClaudeProcessDetector.swift`**

```swift
import Foundation

/// Detects whether the `claude` CLI is currently running, so the UI can warn that
/// a switch takes effect only on the next launch.
public struct ClaudeProcessDetector {
    private let lister: () -> [String]

    public init(lister: @escaping () -> [String] = ClaudeProcessDetector.pgrepLister) {
        self.lister = lister
    }

    public func isClaudeRunning() -> Bool {
        lister().contains { name in
            name == "claude" || name.hasSuffix("/claude")
        }
    }

    /// Lists process command names via `pgrep -l claude`.
    public static func pgrepLister() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-l", "claude"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // Each line is "<pid> <command>"; take the command token.
        return text.split(separator: "\n").map { line in
            String(line.split(separator: " ").dropFirst().joined(separator: " "))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClaudeProcessDetectorTests`
Expected: PASS — 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsageBarCore/ClaudeProcessDetector.swift Tests/ClaudeUsageBarCoreTests/ClaudeProcessDetectorTests.swift
git commit -m "feat: add ClaudeProcessDetector for running-claude warning"
```

---

## Task 8: UI wiring — controller, menu items, borrowed badge, auto-revert timer

**Files:**
- Create: `Sources/ClaudeUsageBar/MultiAccountController.swift`
- Modify: `Sources/ClaudeUsageBar/main.swift` (import; instantiate controller; first-run self-capture; inject account menu items; render borrowed badge)

**Interfaces:**
- Consumes: everything from Core — `AccountManager`, `SecurityCLICredentialStore`, `AccountStore`, `ClaudeProcessDetector`, `BorrowDuration`, `AccountsFile`, `ClaudeometerConstants`.
- Produces (for `main.swift`):
  - `@MainActor final class MultiAccountController` with:
    - `var onChange: (() -> Void)?`
    - `func start()`  — first-run self-capture + resume/schedule auto-revert
    - `func accountMenuItems(target: AnyObject) -> [NSMenuItem]`
    - `var badge: (text: String, isBorrowing: Bool)?`  — nil when on self

> UI cannot be unit-tested here; correctness is verified via the `/run` skill
> checklist in Step 6. All decision logic lives in Core (already tested) — this
> controller only schedules timers and builds `NSMenuItem`s.

- [ ] **Step 1: Create `Sources/ClaudeUsageBar/MultiAccountController.swift`**

```swift
import AppKit
import ClaudeUsageBarCore

@MainActor
final class MultiAccountController {
    private let manager: AccountManager
    private let detector = ClaudeProcessDetector()
    private var revertTimer: Timer?

    /// Called whenever accounts or borrow state change, so the UI can re-render.
    var onChange: (() -> Void)?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Claudeometer", isDirectory: true)
        self.manager = AccountManager(credentialStore: SecurityCLICredentialStore(),
                                      store: AccountStore(directory: base))
    }

    /// First-run self-capture and auto-revert scheduling.
    func start() {
        if manager.snapshot().selfAccount == nil {
            // Capture whatever Claude Code is currently logged in as, as "Me".
            _ = try? manager.captureCurrent(label: "Me", isSelf: true)
        }
        scheduleRevert()
        onChange?()
    }

    /// The menu-bar badge string, or nil when running on the self account.
    var badge: (text: String, isBorrowing: Bool)? {
        let file = manager.snapshot()
        guard let borrow = file.activeBorrow,
              let active = file.account(id: borrow.activeAccountId) else { return nil }
        let secs = Int(borrow.remaining(now: Date()))
        let text = "↔ \(active.label) \(secs / 3600):" + String(format: "%02d", (secs % 3600) / 60)
        return (text, true)
    }

    /// Builds the account section for the `•••` menu.
    func accountMenuItems(target: AnyObject) -> [NSMenuItem] {
        let file = manager.snapshot()
        var items: [NSMenuItem] = []

        let header = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)

        for account in file.accounts {
            let active = file.activeBorrow?.activeAccountId == account.id
                || (file.activeBorrow == nil && account.isSelf)
            let item = NSMenuItem(title: account.label, action: #selector(AppDelegate.accountMenuTapped(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.state = active ? .on : .off
            item.representedObject = account.id.uuidString
            if !account.isSelf { item.submenu = durationSubmenu(for: account.id, target: target) }
            items.append(item)
        }

        let add = NSMenuItem(title: "Save current login as account…",
                             action: #selector(AppDelegate.saveCurrentAccountTapped), keyEquivalent: "")
        add.target = target
        items.append(add)

        if file.activeBorrow != nil, let me = file.selfAccount {
            let back = NSMenuItem(title: "Switch back to \(me.label)",
                                  action: #selector(AppDelegate.switchBackTapped), keyEquivalent: "")
            back.target = target
            items.append(back)
        }
        return items
    }

    private func durationSubmenu(for accountId: UUID, target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        for seconds in BorrowDuration.presets {
            let mins = Int(seconds / 60)
            let title = mins % 60 == 0 ? "Use for \(mins / 60)h" : "Use for \(mins)m"
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.useAccountTapped(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = "\(accountId.uuidString)|\(Int(seconds))"
            menu.addItem(item)
        }
        return menu
    }

    // MARK: actions invoked by AppDelegate

    func saveCurrentAccount(label: String) {
        _ = try? manager.captureCurrent(label: label, isSelf: false)
        onChange?()
    }

    /// Returns true on success; false if a running `claude` should trigger a warning.
    func useAccount(id: UUID, seconds: TimeInterval) -> Bool {
        try? manager.switchTo(accountId: id, duration: seconds)
        scheduleRevert()
        onChange?()
        return !detector.isClaudeRunning()
    }

    func switchBack() {
        try? manager.revert()
        revertTimer?.invalidate()
        onChange?()
    }

    func isClaudeRunning() -> Bool { detector.isClaudeRunning() }

    private func scheduleRevert() {
        revertTimer?.invalidate()
        guard let borrow = manager.snapshot().activeBorrow else { return }
        let delay = max(1, borrow.remaining(now: Date()))
        revertTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.switchBack()
            }
        }
    }
}
```

- [ ] **Step 2: Wire the controller into `AppDelegate` in `main.swift`**

At the top of the file, add the import next to the existing imports (`import AppKit`):

```swift
import ClaudeUsageBarCore
```

In `final class AppDelegate`, add a stored property near the other `private var` declarations (around line 29):

```swift
    private let multiAccount = MultiAccountController()
```

In `applicationDidFinishLaunching`, after the existing `refresh()` call (around line 50), add:

```swift
        multiAccount.onChange = { [weak self] in
            Task { @MainActor in
                self?.renderPopover(status: self?.statusMessage)
                self?.renderStatusImage()
            }
        }
        multiAccount.start()
```

- [ ] **Step 3: Add the menu-action handlers to `AppDelegate` in `main.swift`**

Add these `@objc` methods inside `AppDelegate` (near `refreshNow()` around line 329). `AppDelegate` is `@MainActor`, so they may call the controller directly:

```swift
    @objc func accountMenuTapped(_ sender: NSMenuItem) {
        // Tapping the self row (no submenu) switches back; other rows use their submenu.
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        let file = multiAccountSnapshotIsSelf(id)
        if file { multiAccount.switchBack() }
    }

    @objc func saveCurrentAccountTapped() {
        let alert = NSAlert()
        alert.messageText = "Save current Claude login as…"
        alert.informativeText = "Give this account a name (e.g. a teammate's name)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let label = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty { multiAccount.saveCurrentAccount(label: label) }
        }
    }

    @objc func useAccountTapped(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              let seconds = TimeInterval(String(parts[1])) else { return }
        let clean = multiAccount.useAccount(id: id, seconds: seconds)
        if !clean { warnClaudeRunning() }
    }

    @objc func switchBackTapped() {
        multiAccount.switchBack()
    }

    private func multiAccountSnapshotIsSelf(_ id: UUID) -> Bool {
        // Self row has no submenu; treat a direct tap on it as "switch back".
        multiAccount.badge != nil
    }

    private func warnClaudeRunning() {
        let alert = NSAlert()
        alert.messageText = "Switched — restart `claude` to use it"
        alert.informativeText = "A claude session is running. The new account takes effect the next time you start claude; your current session is unaffected."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
```

- [ ] **Step 4: Inject the account items into the `•••` menu and render the badge**

The `•••` menu is built in `UsagePanelView`. Add a stored `accountItems: [NSMenuItem]` to `UsagePanelView` and insert them before the `Quit` item.

In `UsagePanelView` (class starts ~line 378), add a property and init parameter:

```swift
    private let accountItems: [NSMenuItem]
```

Add `accountItems: [NSMenuItem] = []` as the last parameter of `UsagePanelView.init(...)` and store it: `self.accountItems = accountItems`.

In the menu-building code (the `NSMenu()` around line 735), after the `Login` item and its separator and before the `Quit` item, insert:

```swift
        if !accountItems.isEmpty {
            menu.addItem(.separator())
            for item in accountItems { menu.addItem(item) }
            menu.addItem(.separator())
        }
```

In `AppDelegate.renderPopover(status:)`, pass the items when constructing `UsagePanelView` (around line 210) by adding this argument to the initializer call:

```swift
            accountItems: multiAccount.accountMenuItems(target: self)
```

For the badge, at the end of `renderStatusImage()` (around line 315) or within `setTitle`, prefer the borrowed badge when present. In `apply(_:)` and the icon timer path, add near where the title is computed:

```swift
        if let badge = multiAccount.badge {
            setTitle(badge.text, color: .systemOrange)
            return
        }
```

Place that guard at the start of `apply(_:)` **after** `evaluateNotifications` is still reached is not required for M1 — simplest: add the guard at the top of `setTitle`-driving code in `apply(_:)` so a borrow visually overrides the usage title. (Usage polling continues underneath; the badge just wins the label while borrowing.)

- [ ] **Step 5: Build the app and the whole test suite**

Run: `swift build && swift test`
Expected: PASS — app compiles; all Core suites green.

- [ ] **Step 6: Manual verification via the `/run` skill**

Rebuild and relaunch the app bundle (per repo memory: kill + relaunch, don't just build):

Run:
```bash
./scripts/build-app.sh && (killall Claudeometer 2>/dev/null; open build/Claudeometer.app)
```

Verify the checklist:
- [ ] On first launch, a "Me" account exists (open `•••` → Accounts shows "Me" with a checkmark).
- [ ] Run `claude /login` (via the existing `•••` → Login) using a second account; complete the code paste so `Claude Code-credentials` now holds that account.
- [ ] `•••` → "Save current login as account…" → name it (e.g. "TestB"). It appears under Accounts.
- [ ] Switch back to "Me" first (so Me's backup is your real creds), then Accounts → "TestB" → "Use for 30m". Menu bar shows the orange `↔ TestB 0:30` badge and counts down.
- [ ] `which claude && claude` (new terminal) authenticates as TestB (verify via its usage in the popover or `claude` behavior).
- [ ] With a `claude` session running, trigger a switch and confirm the "restart claude" warning appears and the running session is unaffected.
- [ ] Accounts → "Switch back to Me" (or wait for auto-revert): badge clears, `claude` returns to your account.
- [ ] Confirm `~/Library/Application Support/Claudeometer/accounts.json` contains labels/ids but **no** `accessToken`/`claudeAiOauth`.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeUsageBar/MultiAccountController.swift Sources/ClaudeUsageBar/main.swift
git commit -m "feat: wire local multi-account switching into the menu-bar UI"
```

---

## Self-Review

**Spec coverage (M1 items → tasks):**
- Vault (Keychain slots + metadata JSON) → Tasks 3 (store), 5 (metadata), 6 (capture writes vault items).
- Capture current `Claude Code-credentials` as a named account → Task 6 `captureCurrent`; UI Task 8 "Save current login as account…".
- Switch active account with backup + 2h auto-revert + "switch back" → Task 6 `switchTo`/`revert`; Task 4 duration policy; Task 8 timer + menu items.
- Menu-bar borrowed badge + countdown → Task 8 `badge` + `apply`/`setTitle` guard.
- Running-`claude` warning → Task 7 detector; Task 8 `warnClaudeRunning`.
- Keychain round-trip spike first → Task 3 Step 6 runbook (gate before Task 4+).
- Secrets Keychain-only, metadata-only on disk → Task 5 `persistedFileHasNoRawSecret` test + Task 8 Step 6 manual check.
- Testing strategy (unit for vault/revert/timer; manual for Keychain/UI) → Tasks 2–7 unit tests; Tasks 3 & 8 manual runbooks.

**Placeholder scan:** No "TBD/TODO/handle edge cases" — every code step has full code; every test step has real assertions.

**Type consistency:** `CredentialBlob`, `CredentialStore` (read/write/delete/accountAttribute), `Account.keychainService`, `AccountsFile.selfAccount/account(id:)`, `ActiveBorrow(activeAccountId/selfAccountId/startedAt/revertAt)`, `BorrowDuration.presets/clamp`, `AccountManager.captureCurrent/switchTo/revert/snapshot`, and `MultiAccountController.badge/start/accountMenuItems` are used identically across the tasks that define and consume them.

**Known follow-ups (out of M1 scope, noted for later milestones):** richer popover Accounts section (M1 uses the `•••` menu); cross-account gauges for non-active vaulted accounts (M2 self-reported board supersedes); the `accountEmail` here stores a token-suffix hint, not a real email (real email arrives with the profile call in M2).
