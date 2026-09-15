import Foundation
import Darwin
import CrowCore
#if CROW_APP_TEST
import AppKit
@testable import Crow
#endif

/// The shared-key transport is retired. No fixture may silently restore unrestricted access.
@main struct ReverseSSHSmoke {
    #if CROW_APP_TEST
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        NSApplication.shared.run()
    }
    #else
    static func main() async { await run() }
    #endif

    @MainActor static func run() async {
        do {
            guard CommandLine.arguments.count == 1 else {
                throw CommandError("Live reverse connections are disabled. Run this check without connection arguments.")
            }
            let session = ReverseSSHSession()
            defer { session.stop() }
            for password in [nil, Optional("previous password")] {
                var connected = false, copied = false
                session.start(password: password, onReady: { _ in copied = true }) {
                    connected = true
                    throw CommandError("An SSH connection must not be requested")
                }
                await Task.yield()
                try require(!connected && !copied && !session.isEnabled && session.connectCommand == nil,
                    "Legacy startup issued reverse access")
                do {
                    let server = try await ReverseSSHServer.create(password: password)
                    server.stop()
                    throw CommandError("A legacy SSH listener opened")
                } catch {
                    try require(error.localizedDescription == ReverseSSHAccessPolicy.unavailableMessage,
                        "Server creation did not fail closed")
                }
            }
            let script = ReverseSSHConnector.script(path: "/tmp/crow-disabled-fixture", port: 1,
                username: "fixture", passwordRequired: true)
            do {
                _ = try await ReverseSSHCommand.run("/bin/sh", ["-c", script])
                throw CommandError("Legacy connector ran successfully")
            } catch {
                try require(error.localizedDescription.contains(ReverseSSHAccessPolicy.unavailableMessage),
                    "Legacy connector did not explain its refusal")
            }
            print("PASS legacy reverse access: no SSH connection, listener, copied command or password bypass")
            exit(0)
        } catch { print("FAIL", error.localizedDescription); exit(1) }
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CommandError(message) }
    }
}
