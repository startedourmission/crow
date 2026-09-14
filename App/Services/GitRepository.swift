import Foundation
import CrowCore

struct RepositorySnapshot: Sendable {
    let root: String
    let status: GitStatus
    let remote: GitRemoteInfo?
    let authorName: String
    let authorEmail: String
}

struct GitProjectList: Sendable {
    let paths: [String]
    let warning: String?
}

enum GitRepository {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func query(path: String) -> String {
        let git = "git --no-optional-locks -c core.fsmonitor=false -C " + quote(path)
        return """
        crow_git_root=$(\(git) rev-parse --show-toplevel) && {
          printf '%s\\0' "$crow_git_root"
          crow_git_branch=$(\(git) symbolic-ref --quiet --short HEAD 2>/dev/null || :)
          crow_git_remote=$(\(git) config --get "branch.$crow_git_branch.remote" || :)
          if [ -z "$crow_git_remote" ] || [ "$crow_git_remote" = . ]; then
            if \(git) remote get-url origin >/dev/null 2>&1; then crow_git_remote=origin
            else crow_git_remote=$(\(git) remote | head -n 1); fi
          fi
          crow_git_url=$(\(git) remote get-url "$crow_git_remote" 2>/dev/null || :)
          printf '%s\\0' "$crow_git_remote" "$crow_git_url"
          printf '%s\\0' "$(\(git) config --get user.name || :)" "$(\(git) config --get user.email || :)"
          \(git) status --porcelain=v1 -z --branch --untracked-files=normal && printf 'CROW_GIT_STATUS_END\\0'
        }
        """
    }
    static func parse(_ data: Data) throws -> RepositorySnapshot {
        let end = Data("CROW_GIT_STATUS_END\0".utf8)
        guard data.suffix(end.count) == end else {
            throw failure("Git status did not complete. Check folder access and that Git is installed on this host.")
        }
        let payload = data.dropLast(end.count)
        var cursor = payload.startIndex
        var fields: [String] = []
        for _ in 0..<5 {
            guard let separator = payload[cursor...].firstIndex(of: 0) else {
                throw failure("Git returned incomplete repository information.")
            }
            fields.append(String(decoding: payload[cursor..<separator], as: UTF8.self))
            cursor = payload.index(after: separator)
        }
        guard fields[0].hasPrefix("/") else { throw failure("Git did not return an absolute repository path.") }
        return RepositorySnapshot(root: fields[0], status: GitStatus(porcelain: Data(payload[cursor...])),
            remote: GitRemoteInfo(name: fields[1], url: fields[2]), authorName: fields[3], authorEmail: fields[4])
    }

    /// Discover worktrees, including the selected folder itself, without entering .git
    /// or following symlinked folders outside the workspace. Run once per refresh.
    static func projectsQuery(path: String) -> String {
        let inspect = """
        for crow_git_marker do
          crow_git_folder=${crow_git_marker%/.git}
          if crow_git_root=$(git --no-optional-locks -c core.fsmonitor=false -C "$crow_git_folder" rev-parse --show-toplevel); then
            printf '%s\\0' "$crow_git_root"
          else
            printf 'CROW_GIT_PROJECTS_PARTIAL\\0'
          fi
        done
        """
        return "cd -- " + quote(path) + " || exit; "
            + "command -v git >/dev/null || { printf 'Git is unavailable in the SSH shell PATH.\\n' >&2; exit 127; }; "
            + "if ! find . -name .git -prune \\( -type d -o -type f \\) -exec sh -c " + quote(inspect)
            + " sh {} +; then printf 'CROW_GIT_PROJECTS_PARTIAL\\0'; fi; printf 'CROW_GIT_PROJECTS_END\\0'"
    }

    static func parseProjects(_ data: Data) throws -> GitProjectList {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard fields.popLast() == "", fields.popLast() == "CROW_GIT_PROJECTS_END",
              fields.allSatisfy({ $0.hasPrefix("/") || $0 == "CROW_GIT_PROJECTS_PARTIAL" }) else {
            throw failure("Could not list Git projects. Check folder access and that Git is installed on this host.")
        }
        return GitProjectList(paths: Set(fields.filter { $0.hasPrefix("/") }).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            warning: fields.contains("CROW_GIT_PROJECTS_PARTIAL") ? "Some folders or repositories could not be read. Showing the Git projects that are accessible." : nil)
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CrowGit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    #if os(macOS)
    static func read(path: String, remote: SystemSSHSpec? = nil) async throws -> RepositorySnapshot {
        try parse(await execute(query: query(path: path), remote: remote))
    }

    static func projects(path: String, remote: SystemSSHSpec? = nil) async throws -> GitProjectList {
        try parseProjects(await execute(query: projectsQuery(path: path), remote: remote))
    }

    private static func execute(query: String, remote: SystemSSHSpec?) async throws -> Data {
        let work = Task.detached(priority: .utility) {
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
            return data
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
            guard Date() < deadline else { throw failure("Git request timed out. Try a smaller project folder. The terminal connection was left open.") }
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
