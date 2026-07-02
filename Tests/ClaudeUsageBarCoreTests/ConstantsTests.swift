import Testing
@testable import ClaudeUsageBarCore

@Suite struct ConstantsTests {
    @Test func serviceNames() {
        #expect(ClaudeometerConstants.claudeCodeKeychainService == "Claude Code-credentials")
        #expect(ClaudeometerConstants.vaultServicePrefix == "Claudeometer-account-")
    }
}
