import XCTest
@testable import CrowCore

final class SSHCommandTests: XCTestCase {
    func testUserHostPortAndQuotedKey() throws {
        let parsed = try SSHCommand("ssh person@example.org -p 2222 -i '/a key/id_ed25519'")
        XCTAssertEqual(parsed.arguments, ["person@example.org", "-p", "2222", "-i", "/a key/id_ed25519"])
        XCTAssertTrue(SSHCommand.isInteractive(parsed.arguments))
        let (host, identity) = try parsed.portableHost(defaultUsername: "unused")
        XCTAssertEqual(host.username, "person"); XCTAssertEqual(host.hostname, "example.org")
        XCTAssertEqual(host.port, 2222); XCTAssertEqual(identity, "/a key/id_ed25519")
    }
    func testAliasIPv6AndAttachedOptions() throws {
        XCTAssertTrue(SSHCommand.isInteractive(try SSHCommand("ssh production").arguments))
        let (host, _) = try SSHCommand("ssh -p2200 -lperson '[::1]'").portableHost(defaultUsername: "")
        XCTAssertEqual(host.hostname, "::1"); XCTAssertEqual(host.username, "person"); XCTAssertEqual(host.port, 2200)
    }
    func testNeverEvaluatesShellSyntax() {
        for line in ["echo ssh host", "ssh host; touch x", "ssh $(whoami)@host", "ssh host | tee x", "ssh 'unfinished"] {
            XCTAssertThrowsError(try SSHCommand(line))
        }
    }
    func testNoninteractiveCommandsAreNotImported() throws {
        for line in ["ssh host uptime", "ssh -N -L 8080:localhost:80 host", "ssh -G host", "ssh -O exit host", "ssh -T host", "ssh -p"] {
            XCTAssertFalse(SSHCommand.isInteractive(try SSHCommand(line).arguments), line)
        }
        XCTAssertTrue(SSHCommand.isInteractive(try SSHCommand("ssh -v -p 2222 -o 'IdentityFile=/a key' person@host").arguments))
    }
}
