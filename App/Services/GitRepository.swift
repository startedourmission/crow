import Foundation
import CrowCore

struct RepositorySnapshot: Sendable {
    let root: String
    let status: GitStatus
}

enum GitRepository {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func query(path: String) -> String {
        let git = "git --no-optional-locks -c core.fsmonitor=false -C " + quote(path)
        return "crow_git_root=$(\(git) rev-parse --show-toplevel) && printf '%s\\0' \"$crow_git_root\" && \(git) status --porcelain=v1 -z --branch --untracked-files=normal"
    }
    static func parse(_ data: Data) throws -> RepositorySnapshot {
        guard let separator = data.firstIndex(of: 0) else { throw failure("Unable to read Git repository status.") }
        let root = String(decoding: data[..<separator], as: UTF8.self)
        guard root.hasPrefix("/") else { throw failure("Git did not return an absolute repository path.") }
        return RepositorySnapshot(root: root, status: GitStatus(porcelain: data.subdata(in: data.index(after: separator)..<data.endIndex)))
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CrowGit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    #if os(macOS)
    static func read(path: String, remote: SystemSSHSpec? = nil) async throws -> RepositorySnapshot {
        let work = Task.detached(priority: .utility) {
            let query = query(path: path)
            let data: Data
            if let remote {
                guard FileManager.default.fileExists(atPath: remote.socket) else {
                    throw failure("SSH is disconnected. Reconnect from the terminal.")
                }
                let marker = "CROW_GIT_" + UUID().uuidString
                // Shell stdin also supports Windows SSH -> POSIX login shells without
                // relying on the server's remote-command quoting configuration.
                let script = "printf '\(marker)\\n'; \(query); crow_git_result=$?; printf '\\0\(marker)_END\\0'; exit \"$crow_git_result\""
                let output = try run("/usr/bin/ssh", ["-T"] + remote.multiplexArguments,
                    input: Data(("sh -c " + quote(script) + "\n").utf8))
                guard let start = output.range(of: Data((marker + "\n").utf8)),
                      let end = output.range(of: Data(("\0" + marker + "_END\0").utf8)), start.upperBound <= end.lowerBound else {
                    throw failure("Git requires a POSIX login shell and Git on the SSH server.")
                }
                data = output.subdata(in: start.upperBound..<end.lowerBound)
            } else {
                data = try run("/bin/sh", ["-c", query])
            }
            return try parse(data)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// Bounded, cancellable background process. File-backed output avoids full-pipe
    /// deadlocks; all temporary files and only this child process are cleaned up.
    private static func run(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> Data {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("crow-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("stdout"), errorURL = temporary.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL), error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }
        let inputURL = temporary.appendingPathComponent("stdin")
        try (input ?? Data()).write(to: inputURL)
        let stdin = try FileHandle(forReadingFrom: inputURL)
        defer { try? stdin.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        process.standardOutput = output; process.standardError = error; process.standardInput = stdin
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(12)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw failure("Git status timed out. The terminal connection was left open.") }
            for url in [outputURL, errorURL] {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < 8 * 1024 * 1024 else { throw failure("Git output is too large to display.") }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        let result = try Data(contentsOf: outputURL)
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(detail.isEmpty ? "Not a Git repository, or Git is unavailable in this environment." : String(detail.prefix(2000)))
        }
        return result
    }
    #endif
}
