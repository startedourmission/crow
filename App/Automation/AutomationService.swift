import CrowCore
import Foundation

struct CronJob: Identifiable, Equatable {
    var id: Int
    var schedule: String
    var command: String
    var enabled: Bool
    static let disabledPrefix = "# crow-disabled: "

    static func parse(_ source: String) -> [CronJob] {
        source.components(separatedBy: "\n").enumerated().compactMap { index, original in
            var line = original.trimmingCharacters(in: .whitespaces)
            let enabled = !line.hasPrefix(disabledPrefix)
            if !enabled { line.removeFirst(disabledPrefix.count) }
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let count = line.hasPrefix("@") ? 1 : 5
            let fields = line.split(maxSplits: count, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count == count + 1, !fields[0].contains("=") else { return nil }
            return CronJob(id: index, schedule: fields.prefix(count).joined(separator: " "), command: fields[count], enabled: enabled)
        }
    }

    func replacing(in source: String, isNew: Bool = false) throws -> String {
        let schedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = schedule.split(whereSeparator: \.isWhitespace)
        let macros = ["@reboot", "@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight", "@hourly"]
        guard !command.isEmpty, !command.contains("\n"), !command.contains("\r"), !command.contains("\0"),
              !schedule.contains("\n"), !schedule.contains("\r"),
              macros.contains(schedule) || (fields.count == 5 && fields.allSatisfy({ $0.range(of: "^[a-zA-Z0-9*/,?\\-]+$", options: .regularExpression) != nil })) else {
            throw CommandError("Enter a five-field cron schedule (or @reboot, @daily, etc.) and a single-line command.")
        }
        let line = (enabled ? "" : Self.disabledPrefix) + schedule + " " + command
        if isNew { return source + (source.isEmpty || source.hasSuffix("\n") ? "" : "\n") + line + "\n" }
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(id) else { throw CommandError("This cron entry changed. Refresh and reopen it.") }
        lines[id] = line
        return lines.joined(separator: "\n")
    }
}

struct LaunchJob: Identifiable, Decodable {
    var id: String { path }
    var path: String
    var label: String
    var schedule: String
    var writable: Bool
    var system: Bool
    var daemon: Bool
}

struct LaunchDocument {
    var values: [String: Any]
    init(data: Data) throws {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = values["Label"] as? String, !label.isEmpty else { throw CommandError("This plist has no launchd Label.") }
        self.values = values
    }
    var label: String { values["Label"] as? String ?? "" }
    func xml() throws -> String { String(decoding: try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0), as: UTF8.self) }
}

struct AutomationSnapshot {
    var os = ""
    var uid = ""
    var home = ""
    var cron = ""
    var cronAvailable = false
    var launchJobs: [LaunchJob] = []
    var services: [String: Int] = [:]
    var agentDomain = ""
    var warnings: [String] = []
    func domain(for job: LaunchJob) -> String { job.daemon ? "system" : agentDomain }
}

@MainActor final class AutomationService {
    typealias Runner = @MainActor (String) async throws -> String
    private let run: Runner
    init(run: @escaping Runner) { self.run = run }
    convenience init(state: WorkspaceState) {
        self.init { command in
            #if os(macOS)
            if !state.snapshot.workspace.isRemote {
                return try await ReverseSSHCommand.run("/bin/sh", ["-c", command], operation: "Automation")
            }
            if let ssh = state.systemSSH, state.remote?.isConnected == true {
                return try await ReverseSSHCommand.run("/usr/bin/ssh", ["-T"] + ssh.multiplexArguments
                    + ["sh -c " + TerminalCommand.quote(command)], operation: "Automation")
            }
            #endif
            guard state.snapshot.workspace.isRemote, let remote = state.remote, remote.isConnected else {
                throw CommandError(state.snapshot.workspace.isRemote ? "Connect this SSH host to manage its automations." : "Select an SSH host to manage automations from iOS.")
            }
            return try await remote.workspaceCommand(command, operation: "Automation")
        }
    }

    func load() async throws -> AutomationSnapshot {
        let info = try await run("uname -s; id -u; printf '%s' \"$HOME\"").split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard info.count == 3 else { throw CommandError("Could not identify the selected device.") }
        var result = AutomationSnapshot(os: info[0], uid: info[1], home: info[2])
        do { result.cron = try await readCron(); result.cronAvailable = true }
        catch { result.warnings.append(error.localizedDescription) }
        guard result.os == "Darwin" else { return result }
        do {
            let json = try await run(Self.launchListCommand)
            result.launchJobs = try JSONDecoder().decode([LaunchJob].self, from: Data(json.utf8))
        } catch { result.warnings.append("launchd files: " + error.localizedDescription) }
        result.agentDomain = "gui/" + result.uid
        do { result.services.merge(Self.services(try await run("launchctl print " + TerminalCommand.quote(result.agentDomain)), domain: result.agentDomain)) { _, new in new } }
        catch {
            result.agentDomain = "user/" + result.uid
            do { result.services.merge(Self.services(try await run("launchctl print " + TerminalCommand.quote(result.agentDomain)), domain: result.agentDomain)) { _, new in new } }
            catch { result.warnings.append("User launchd status: " + error.localizedDescription) }
        }
        do { result.services.merge(Self.services(try await run("launchctl print system"), domain: "system")) { _, new in new } }
        catch { result.warnings.append("System launchd status: " + error.localizedDescription) }
        return result
    }

    // Preserve exact trailing newlines; command runners trim their text output.
    func readCron() async throws -> String {
        let encoded = try await run(Self.cronPreparation + "read_cron \"$crow_tmp/current\" && base64 < \"$crow_tmp/current\"")
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), let source = String(data: data, encoding: .utf8) else {
            throw CommandError("Could not decode this user's crontab as UTF-8.")
        }
        return source
    }

    func saveCron(_ source: String, expected: String) async throws {
        guard source.utf8.count <= 256 * 1024, !source.contains("\0") else { throw CommandError("Crontab must be UTF-8 text under 256 KB.") }
        let source = source.isEmpty || source.hasSuffix("\n") ? source : source + "\n"
        _ = try await run(Self.cronPreparation + """
        read_cron "$crow_tmp/current" || exit
        printf '%s' \(TerminalCommand.quote(expected)) > "$crow_tmp/expected"
        cmp -s "$crow_tmp/current" "$crow_tmp/expected" || { echo 'Crontab changed since opening. Refresh before saving.' >&2; exit 1; }
        printf '%s' \(TerminalCommand.quote(source)) > "$crow_tmp/new"
        crontab "$crow_tmp/new"
        """)
    }

    func readLaunch(_ job: LaunchJob) async throws -> Data {
        let path = TerminalCommand.quote(job.path)
        let encoded = try await run("test -f \(path) && test ! -L \(path) && test \"$(wc -c < \(path))\" -le 524288 && base64 < \(path)")
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { throw CommandError("Could not read launchd plist.") }
        return data
    }

    func saveLaunch(_ xml: String, job: LaunchJob, expected: Data) async throws {
        guard job.writable else { throw CommandError("This launchd file is read-only for the connected user.") }
        let data = Data(xml.utf8), document = try LaunchDocument(data: data)
        guard data.count <= 524288, document.label == job.label else { throw CommandError("Keep the existing Label and a plist size under 512 KB.") }
        let path = TerminalCommand.quote(job.path)
        _ = try await run("""
        set -e
        crow_path=\(path)
        test -f "$crow_path" && test ! -L "$crow_path" && test -O "$crow_path"
        crow_tmp=$(mktemp -d "$(dirname "$crow_path")/.crow-automation.XXXXXX")
        trap 'rm -rf "$crow_tmp"' EXIT HUP INT TERM
        printf '%s' \(TerminalCommand.quote(expected.base64EncodedString())) | /usr/bin/base64 -D > "$crow_tmp/expected"
        cmp -s "$crow_path" "$crow_tmp/expected" || { echo 'This plist changed since opening. Refresh before saving.' >&2; exit 1; }
        printf '%s' \(TerminalCommand.quote(xml)) > "$crow_tmp/new"
        /usr/bin/plutil -lint "$crow_tmp/new" >/dev/null
        chmod "$(stat -f '%Lp' "$crow_path")" "$crow_tmp/new"
        mv -f "$crow_tmp/new" "$crow_path"
        """)
    }

    func reloadLaunch(_ job: LaunchJob, domain: String) async throws {
        guard job.writable else { throw CommandError("This launchd job is read-only for the connected user.") }
        let target = TerminalCommand.quote(domain + "/" + job.label)
        _ = try await run("set -e; if launchctl print \(target) >/dev/null 2>&1; then launchctl bootout \(target); fi; launchctl bootstrap \(TerminalCommand.quote(domain)) \(TerminalCommand.quote(job.path))")
    }

    static func services(_ text: String, domain: String) -> [String: Int] {
        var inside = false, result: [String: Int] = [:]
        for line in text.components(separatedBy: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line == "services = {" { inside = true; continue }
            if inside && line == "}" { break }
            guard inside else { continue }
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            if fields.count == 3, let pid = Int(fields[0]) { result[domain + "/" + fields[2]] = pid }
        }
        return result
    }

    private static let cronPreparation = """
    command -v crontab >/dev/null 2>&1 || { echo 'crontab is not installed on this device.' >&2; exit 1; }
    crow_tmp=$(mktemp -d) || exit
    trap 'rm -rf "$crow_tmp"' EXIT HUP INT TERM
    read_cron() {
      if LC_ALL=C crontab -l > "$1" 2> "$crow_tmp/error"; then return 0; fi
      if LC_ALL=C grep -qi 'no crontab for' "$crow_tmp/error"; then : > "$1"; return 0; fi
      cat "$crow_tmp/error" >&2; return 1
    }

    """

    static let launchListCommand = "/usr/bin/osascript -l JavaScript -e " + TerminalCommand.quote(#"""
    ObjC.import('Foundation');
    const fm = $.NSFileManager.defaultManager;
    const home = ObjC.unwrap($.NSHomeDirectory());
    const directories = [home + '/Library/LaunchAgents', '/Library/LaunchAgents', '/Library/LaunchDaemons', '/System/Library/LaunchAgents', '/System/Library/LaunchDaemons'];
    let result = [];
    for (const dir of directories) {
      const items = fm.contentsOfDirectoryAtPathError(dir, null);
      if (!items.js) continue;
      for (const name of ObjC.deepUnwrap(items)) {
        if (!name.endsWith('.plist')) continue;
        const path = dir + '/' + name;
        const attrs = ObjC.deepUnwrap(fm.attributesOfItemAtPathError(path, null));
        if (!attrs || attrs.NSFileType !== 'NSFileTypeRegular' || attrs.NSFileSize > 524288) continue;
        const value = $.NSDictionary.dictionaryWithContentsOfFile(path);
        if (!value.js) continue;
        const p = ObjC.deepUnwrap(value);
        if (typeof p.Label !== 'string') continue;
        let schedule = p.StartInterval ? 'Every ' + p.StartInterval + ' seconds' : p.StartCalendarInterval ? 'Calendar schedule' : p.KeepAlive ? 'Keep alive' : p.RunAtLoad ? 'On load' : 'On demand';
        const owner = attrs.NSFileOwnerAccountName === ObjC.unwrap($.NSUserName());
        result.push({path, label:p.Label, schedule, writable:owner && !!fm.isWritableFileAtPath(path) && !!fm.isWritableFileAtPath(dir), system:dir.startsWith('/System/'), daemon:dir.endsWith('/LaunchDaemons')});
      }
    }
    JSON.stringify(result);
    """#)
}
