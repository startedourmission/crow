#if os(macOS)
import Foundation
import CrowCore

struct SSHResolvedConfiguration: Sendable {
    let host: SSHHost
    let values: [String: [String]]

    // These features require OpenSSH rather than Crow's direct SSH transport.
    var requiresOpenSSH: Bool {
        let options = ["proxycommand", "proxyjump", "localforward", "remoteforward", "dynamicforward",
                       "remotecommand", "certificatefile", "identityagent", "controlpath", "localcommand"]
        return options.contains { name in
            values[name, default: []].contains { !["none", ""].contains($0) }
        } || values["forwardagent"]?.first == "yes" || values["forwardx11"]?.first == "yes"
          || values["pubkeyauthentication"]?.first == "false" || values["pubkeyauthentication"]?.first == "no"
    }

    func hasIdentityFile(directory: String) -> Bool {
        values["identityfile", default: []].contains { path in
            let expanded = (path as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)
            return FileManager.default.fileExists(atPath: absolute)
        }
    }
}

struct SystemSSHSpec: Sendable {
    let host: SSHHost
    let socket: String
    let arguments: [String]
    let directory: String
    var multiplexArguments: [String] {
        // Never fall back to a new connection if the authenticated master exits.
        ["-F", "/dev/null", "-S", socket, "-o", "ControlMaster=no", "-o", "BatchMode=yes",
         "-o", "ProxyCommand=false", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
         "-p", String(host.port), host.userAtHost]
    }
    var initialArguments: [String] {
        ["-o", "ControlMaster=auto", "-o", "ControlPersist=60", "-o", "ControlPath=\(socket)"] + arguments
    }
}

/// Private, per-app shell integration. No keystroke logging and no shell rc edits.
@MainActor final class SystemSSHBridge {
    let root: URL
    private var task: Task<Void, Never>?
    private var seen: Set<String> = []
    private var owned: [SystemSSHSpec] = []
    var onConnection: ((SystemSSHSpec) -> Void)?

    init(startupDirectory: String? = nil) throws {
        root = URL(fileURLWithPath: "/tmp/crw-" + String(UUID().uuidString.prefix(12)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let original = startupDirectory ?? ProcessInfo.processInfo.environment["ZDOTDIR"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"] {
            var text = "export ZDOTDIR=\(Self.quote(original))\n[[ -r \(Self.quote(original + "/" + file)) ]] && source \(Self.quote(original + "/" + file))\n"
            if file == ".zshrc" {
                text += """
                function ssh() {
                  local crow_request crow_option crow_exit=0
                  for crow_option in "$@"; do
                    case "$crow_option" in
                      -N|-f|-fN|-Nf|-G|-V|-T|-s|-M|-O*|-S*|-W*|-Q*|*ControlPath=*|*ControlMaster=*|*ControlPersist=*)
                        command /usr/bin/ssh "$@"; return $? ;;
                    esac
                  done
                  crow_request=$(/usr/bin/mktemp -d \(Self.quote(root.path + "/r.XXXXXXXX"))) || { command /usr/bin/ssh "$@"; return $?; }
                  (umask 077; builtin printf '%s\\0' "$@" > "$crow_request/args"; builtin printf '%s' "$PWD" > "$crow_request/cwd")
                  (umask 077; builtin printf '%s' "$CROW_TERMINAL_ID" > "$crow_request/terminal-id"; : > "$crow_request/active")
                  command /usr/bin/ssh -o ControlMaster=auto -o ControlPersist=60 -o "ControlPath=$crow_request/s" "$@" || crow_exit=$?
                  /bin/rm -f -- "$crow_request/active"
                  return $crow_exit
                }

                """
            }
            if file == ".zshrc" || file == ".zlogin" { text += SSHCommand.directoryTrackingCommand + "\n" }
            // Keep startup routing in our private directory even if user rc files set ZDOTDIR.
            text += "export ZDOTDIR=\(Self.quote(root.path))\n"
            try Data(text.utf8).write(to: root.appendingPathComponent(file))
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await self?.poll()
            }
        }
    }

    var environment: [String] {
        var env = TerminalCommand.utf8Environment(ProcessInfo.processInfo.environment)
        env["ZDOTDIR"] = root.path; env["TERM"] = "xterm-256color"
        return env.map { "\($0.key)=\($0.value)" }
    }

    func activeSocket(for terminalID: UUID) -> String? {
        guard let requests = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        let active = requests.filter { request in
            request.lastPathComponent.hasPrefix("r.") &&
            FileManager.default.fileExists(atPath: request.appendingPathComponent("active").path) &&
            FileManager.default.fileExists(atPath: request.appendingPathComponent("s").path) &&
            (try? String(contentsOf: request.appendingPathComponent("terminal-id"), encoding: .utf8)) == terminalID.uuidString
        }
        guard active.count == 1 else { return nil }
        return active[0].appendingPathComponent("s").path
    }

    func imagePasteConnection(socket: String) async throws -> SystemSSHSpec {
        await poll()
        guard let spec = owned.last(where: { $0.socket == socket }) else { throw CommandError("Wait for this SSH connection to finish opening before pasting an image.") }
        return spec
    }

    func prepare(_ arguments: [String], directory: String) async throws -> SystemSSHSpec {
        guard SSHCommand.isInteractive(arguments) else { throw CommandError("Use an interactive ssh connection; run tunnels or remote commands in the local terminal.") }
        let host = try await Self.resolve(arguments, directory: directory)
        let request = root.appendingPathComponent("q-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: request, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var savedHost = host; savedHost.commandArguments = arguments; savedHost.commandDirectory = directory
        let spec = SystemSSHSpec(host: savedHost, socket: request.appendingPathComponent("s").path, arguments: arguments, directory: directory)
        owned.append(spec)
        return spec
    }

    func poll() async {
        guard let requests = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for request in requests where request.lastPathComponent.hasPrefix("r.") && !seen.contains(request.path) {
            guard (try? request.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  FileManager.default.fileExists(atPath: request.appendingPathComponent("active").path),
                  FileManager.default.fileExists(atPath: request.appendingPathComponent("s").path) else { continue }
            seen.insert(request.path)
            guard let data = try? Data(contentsOf: request.appendingPathComponent("args")), data.count < 131_072,
                  let directory = try? String(contentsOf: request.appendingPathComponent("cwd"), encoding: .utf8) else { continue }
            let arguments = data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
            guard SSHCommand.isInteractive(arguments) else { continue }
            do {
                var host = try await Self.resolve(arguments, directory: directory)
                // ControlPersist can leave a socket after the terminal command exits.
                // It must not resurrect a workspace while host resolution is in flight.
                guard FileManager.default.fileExists(atPath: request.appendingPathComponent("active").path) else { continue }
                host.commandArguments = arguments; host.commandDirectory = directory
                let spec = SystemSSHSpec(host: host, socket: request.appendingPathComponent("s").path, arguments: arguments, directory: directory)
                owned.append(spec); onConnection?(spec)
            } catch { /* A terminal-only command must keep working even if import fails. */ }
        }
    }

    nonisolated static func resolve(_ arguments: [String], directory: String) async throws -> SSHHost {
        try await resolveConfiguration(arguments, directory: directory).host
    }

    /// Query only public identity metadata; do not import, export or unlock keys.
    nonisolated static func hasAgentIdentities(environment: [String: String] = ProcessInfo.processInfo.environment) async -> Bool {
        guard let socket = environment["SSH_AUTH_SOCK"], !socket.isEmpty else { return false }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
            process.arguments = ["-l"]; process.environment = environment
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return true } // Do not replace an agent we cannot inspect.
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
            defer { timeout.cancel() }
            process.waitUntilExit()
            // ssh-add: 1 = no identities; 2 = unable to contact the agent.
            return ![1, 2].contains(process.terminationStatus)
        }.value
    }

    nonisolated static func resolveConfiguration(_ arguments: [String], directory: String) async throws -> SSHResolvedConfiguration {
        try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-G"] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
            defer { timeout.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CommandError("OpenSSH could not resolve this command. Check the host and options.") }
            var config: [String: [String]] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let pair = line.split(separator: " ", maxSplits: 1)
                if pair.count == 2 { config[String(pair[0]), default: []].append(String(pair[1])) }
            }
            guard let hostname = config["hostname"]?.first, let username = config["user"]?.first, let port = config["port"]?.first.flatMap(Int.init) else {
                throw CommandError("OpenSSH did not return a hostname, username and port.")
            }
            return SSHResolvedConfiguration(host: SSHHost(name: config["host"]?.first ?? hostname, hostname: hostname, port: port, username: username), values: config)
        }.value
    }

    func stop() {
        task?.cancel(); task = nil
        let specs = owned, directory = root
        Task.detached {
            for spec in specs where FileManager.default.fileExists(atPath: spec.socket) {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = ["-O", "exit"] + spec.multiplexArguments
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try? process.run(); if process.isRunning { process.waitUntilExit() }
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }
    nonisolated static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
#endif
