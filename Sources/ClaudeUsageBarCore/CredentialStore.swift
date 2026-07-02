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
