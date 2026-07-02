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
