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
