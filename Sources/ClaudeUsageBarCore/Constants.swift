import Foundation

/// Service names used to look up credential items in the macOS Keychain.
public enum ClaudeometerConstants {
    /// The generic-password service Claude Code itself uses.
    public static let claudeCodeKeychainService = "Claude Code-credentials"
    /// Prefix for Claudeometer's own vault items: `Claudeometer-account-<uuid>`.
    public static let vaultServicePrefix = "Claudeometer-account-"
}
