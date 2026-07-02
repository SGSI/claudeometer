import Foundation

/// Real `CredentialStore` backed by `/usr/bin/security`.
public struct SecurityCLICredentialStore: CredentialStore {
    public init() {}

    /// Treats the credential blob as UTF-8 text (Claude Code stores its credential
    /// as UTF-8 JSON). Byte-exactness of the read→write round-trip is validated by
    /// the human-run Keychain spike: `docs/superpowers/spikes/keychain-roundtrip.md`
    /// (which byte-`diff`s the round-trip).
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

    /// Treats the credential blob as UTF-8 text (Claude Code stores its credential
    /// as UTF-8 JSON). Byte-exactness of the read→write round-trip is validated by
    /// the human-run Keychain spike: `docs/superpowers/spikes/keychain-roundtrip.md`
    /// (which byte-`diff`s the round-trip).
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
        // Drain both pipes before waiting for exit: if the child writes more than the
        // pipe buffer (~64KB) and nothing reads it, both process.waitUntilExit() and
        // the child's write() would block forever. readDataToEndOfFile() blocks until
        // EOF, which happens when the process exits, so this ordering is safe.
        // `security` output is tiny, so sequential (non-concurrent) reads are fine here.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)
        return (process.terminationStatus, stdout, stderr)
    }
}
