import Foundation
import CrowCore

/// Only a disposable loopback sshd, key pair, known-hosts file and workspace are used.
/// The deliberately broken subsystem reproduces the Windows-sshd/WSL channel mismatch.
@MainActor func sftpFallback() async throws {
    try await sftpSession(subsystem: "/usr/bin/false")
    try await sftpSession(subsystem: "/usr/libexec/sftp-server")
    try await sftpSession(subsystem: "/usr/libexec/sftp-server", shellOnly: "/bin/bash")
    try await sftpSession(subsystem: "/usr/libexec/sftp-server", shellOnly: "/bin/zsh")
    try await sftpSession(subsystem: "/usr/libexec/sftp-server", stallSubsystem: true)
    try await sftpSession(subsystem: "/usr/bin/false", rejectCommands: true)
}

@MainActor private func sftpSession(subsystem: String, rejectCommands: Bool = false, shellOnly: String? = nil,
                                   stallSubsystem: Bool = false) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-sftp-smoke-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    func process(_ executable: String, _ arguments: [String]) throws -> Process {
        let value = Process(); value.executableURL = URL(fileURLWithPath: executable); value.arguments = arguments
        value.standardInput = FileHandle.nullDevice; value.standardOutput = FileHandle.nullDevice; value.standardError = FileHandle.nullDevice
        try value.run(); return value
    }
    let hostKey = root.appendingPathComponent("host-key").path, key = root.appendingPathComponent("key").path
    for path in [hostKey, key] {
        let keygen = try process("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path])
        keygen.waitUntilExit(); try check(keygen.terminationStatus == 0, "Fixture key generation failed")
    }
    let port = Int.random(in: 23000...45000)
    let config = root.appendingPathComponent("sshd_config")
    let wrapper = root.appendingPathComponent("shell-only")
    if let shellOnly {
        // Reproduce the general capability mismatch: SSH exec/subsystem requests
        // fail, but a plain shell works. No Windows/WSL/distro detection is involved.
        try Data("""
        #!/bin/sh
        cd \(SystemSSHBridge.quote(root.path)) || exit 1
        case "$SSH_ORIGINAL_COMMAND" in
          '') printf 'A login banner before the binary protocol\\n'; exec \(shellOnly) ;;
          'sleep 40') pwd > terminal-start-path; exec /bin/sh -c "$SSH_ORIGINAL_COMMAND" ;;
          *) printf 'Remote command wrapper rejected its options\\n' >&2; exit 127 ;;
        esac

        """.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    } else if stallSubsystem {
        try Data("""
        #!/bin/sh
        case "$SSH_ORIGINAL_COMMAND" in
          '\(subsystem)') exec sleep 20 ;;
          *) printf 'Startup notice before remote command\\n'; exec /bin/sh -c "$SSH_ORIGINAL_COMMAND" ;;
        esac

        """.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    }
    try Data("""
    Port \(port)
    ListenAddress 127.0.0.1
    HostKey \(hostKey)
    PidFile \(root.path)/sshd.pid
    AuthorizedKeysFile \(key).pub
    StrictModes no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    UsePAM no
    AllowUsers \(NSUserName())
    Subsystem sftp \(subsystem)
    \(rejectCommands ? "ForceCommand /usr/bin/false" : (shellOnly != nil || stallSubsystem) ? "ForceCommand \(wrapper.path)" : "")
    LogLevel ERROR

    """.utf8).write(to: config)
    let server = try process("/usr/sbin/sshd", ["-D", "-e", "-f", config.path])
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    try await Task.sleep(for: .milliseconds(250))
    try check(server.isRunning, "Loopback sshd did not start")
    let knownHosts = root.appendingPathComponent("known-hosts")
    let publicKey = try String(contentsOfFile: hostKey + ".pub", encoding: .utf8)
    try Data("[127.0.0.1]:\(port) \(publicKey)".utf8).write(to: knownHosts)
    // Keep Unix-domain socket paths below Darwin's limit.
    let socket = "/tmp/crow-sftp-" + String(UUID().uuidString.prefix(12))
    let host = SSHHost(name: "Loopback", hostname: "127.0.0.1", port: port, username: NSUserName())
    let master = try process("/usr/bin/ssh", ["-F", "/dev/null", "-N", "-M", "-S", socket,
        "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=\(knownHosts.path)", "-i", key, "-p", String(port), host.userAtHost])
    defer { if master.isRunning { master.terminate(); master.waitUntilExit() } }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) { try await Task.sleep(for: .milliseconds(20)) }
    try check(master.isRunning && FileManager.default.fileExists(atPath: socket), "Authenticated fixture connection did not start")
    let spec = SystemSSHSpec(host: host, socket: socket, arguments: [], directory: root.path)
    if rejectCommands {
        let files = try SystemSFTP(spec: spec)
        defer { files.close() }
        do { _ = try await files.list(root.path); try check(false, "Rejected server unexpectedly accepted SFTP") }
        catch let error as CommandError {
            for stage in ["SFTP subsystem:", "Remote command:", "Shell stream:"] {
                try check(error.localizedDescription.contains(stage), "Failed negotiation omitted \(stage): \(error.localizedDescription)")
            }
            try check(!error.localizedDescription.contains("WSL"), "Generic error prescribed host-specific configuration")
        }
        try check(!files.isConnected && master.isRunning, "Failed fallback remained connected or stopped SSH master")
        print("PASS SFTP: all transports rejected; stage diagnostics, no crash, SSH master preserved")
        return
    }
    let terminal = try process("/usr/bin/ssh", ["-T"] + spec.multiplexArguments + ["sleep 40"])
    defer { if terminal.isRunning { terminal.terminate(); terminal.waitUntilExit() } }
    let cancelled = try SystemSFTP(spec: spec)
    cancelled.close()
    do { _ = try await cancelled.list(root.path); try check(false, "Close before handshake resurrected SFTP") }
    catch FileFailure.disconnected {}
    let files = try SystemSFTP(spec: spec)
    defer { files.close() }
    if shellOnly != nil {
        let initialPath = try await files.realPath(".")
        let terminalPath = try String(contentsOf: root.appendingPathComponent("terminal-start-path"), encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        try check(canonical(initialPath) == canonical(root.path) && canonical(initialPath) == canonical(terminalPath),
                  "First file connection ignored the terminal's starting directory: SFTP=\(initialPath), terminal=\(terminalPath), expected=\(root.path)")
        let explicitHome = try await files.realPath("~")
        try check(canonical(explicitHome) == canonical(FileManager.default.homeDirectoryForCurrentUser.path),
                  "Explicit Home action was confused with the starting directory: SFTP=\(explicitHome), home=\(FileManager.default.homeDirectoryForCurrentUser.path)")
        // Resolving/choosing another folder must not change the channel's start path.
        try check(try await files.realPath(".") == initialPath, "Folder selection mutated the initial directory")
    }
    let path = root.appendingPathComponent("fallback 한글.md").path
    try await files.create(path, directory: false)
    let source = String(repeating: "# Capability negotiation\n\n한글 file contents\n", count: 2000)
    try await files.write(source, path: path, expected: "", overwrite: false)
    try check(try await files.read(path) == source, "Fallback SFTP read/write failed")
    try check(try await files.list(root.path).contains { $0.name == "fallback 한글.md" }, "Fallback SFTP directory listing failed")
    do {
        try await files.write("must not overwrite", path: path, expected: "stale", overwrite: false)
        try check(false, "Fallback SFTP overwrote a conflicting file")
    } catch FileFailure.conflict {}
    let renamed = root.appendingPathComponent("renamed.md").path
    try await files.rename(path, to: renamed)
    try check(try await files.read(renamed) == source, "Fallback SFTP rename failed")
    files.close()
    do { _ = try await files.list(root.path); try check(false, "Explicit close resurrected SFTP") }
    catch FileFailure.disconnected {}
    try check(master.isRunning && terminal.isRunning, "SFTP fallback or close stopped another SSH session")
    print("PASS SFTP (\(shellOnly.map { "shell-only " + $0 } ?? (stallSubsystem ? "subsystem timeout + noisy command" : subsystem))): list/read/write/rename/conflict/close; existing SSH session preserved")
}
