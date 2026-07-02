import Foundation
import os

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
        do {
            try process.run()
        } catch {
            Logger(subsystem: "Claudeometer", category: "ClaudeProcessDetector")
                .error("pgrep launch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        // Drain the pipe before waiting for exit: if the child writes more than the
        // pipe buffer (~64KB) and nothing reads it, both process.waitUntilExit() and
        // the child's write() would block forever. readDataToEndOfFile() blocks until
        // EOF, which happens when the process exits, so this ordering is safe.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        // Each line is "<pid> <command>"; take the command token.
        return text.split(separator: "\n").map { line in
            String(line.split(separator: " ").dropFirst().joined(separator: " "))
        }
    }
}
