import XCTest
import CrowCore
@testable import Crow

final class GitAccountTests: XCTestCase {
    func testRemoteAddressesNeverDisplayEmbeddedCredentials() throws {
        let https = try XCTUnwrap(GitRemoteInfo(name: "origin", url: "https://person:secret@github.com/team/repo.git?token=secret#secret"))
        XCTAssertEqual(https.displayAddress, "github.com/team/repo")
        XCTAssertTrue(https.isGitHub)
        XCTAssertFalse(https.usesSSH)
        let ssh = try XCTUnwrap(GitRemoteInfo(name: "upstream", url: "git@github.com:another/repo.git"))
        XCTAssertEqual(ssh.displayAddress, "github.com/another/repo")
        XCTAssertTrue(ssh.usesSSH)
        XCTAssertEqual(GitRemoteInfo(name: "origin", url: "ssh://git@ssh.github.com:443/team/repo.git")?.host, "ssh.github.com")
        XCTAssertFalse(GitRemoteInfo(name: "origin", url: "https://github.com.evil.example/team/repo.git")!.isGitHub)
        XCTAssertNil(GitRemoteInfo(name: "", url: ""))
    }

    func testMetadataFramingAndStatusPreserveUnicodeAndRejectTruncation() throws {
        let fields = ["/repo ' 한글", "origin", "git@github.com:owner/repo.git", "작성자", "writer@example.org"]
        let data = Data((fields.joined(separator: "\0") + "\0## main\0?? file.txt\0CROW_GIT_STATUS_END\0").utf8)
        let result = try GitRepository.parse(data)
        XCTAssertEqual(result.authorName, "작성자")
        XCTAssertEqual(result.authorEmail, "writer@example.org")
        XCTAssertEqual(result.remote?.repository, "owner/repo")
        XCTAssertEqual(result.status.changes.first?.path, "file.txt")
        XCTAssertThrowsError(try GitRepository.parse(data.dropLast()))
        XCTAssertThrowsError(try GitRepository.parse(Data("/repo\0CROW_GIT_STATUS_END\0".utf8)))
    }

    @MainActor func testCredentialsSaveOfflineRestoreReplaceAndRemove() throws {
        let key = "test-git-account-" + UUID().uuidString
        defer { try? SecureStore.remove(key) }
        let store = GitAccountStore(key: key)
        try store.save(accountID: " fixture-user ", token: " test-only-token ")
        XCTAssertEqual(store.account?.login, "fixture-user")
        let restored = GitAccountStore(key: key)
        restored.reload()
        XCTAssertEqual(restored.account?.login, "fixture-user")
        XCTAssertEqual(try restored.credential()?.token, "test-only-token")
        let previous = try SecureStore.data(for: key)
        for (login, token) in [("", "test-token"), ("two words", "test-token"), ("fixture", ""), ("fixture", "bad\ntoken")] {
            XCTAssertThrowsError(try restored.save(accountID: login, token: token))
            XCTAssertEqual(try SecureStore.data(for: key), previous)
        }
        try restored.save(accountID: "other-user", token: "replacement-token")
        XCTAssertEqual(try restored.credential()?.account.login, "other-user")
        XCTAssertEqual(try restored.credential()?.token, "replacement-token")
        try restored.remove()
        XCTAssertNil(try restored.credential())
        XCTAssertNil(restored.account)
    }

    @MainActor func testExistingCredentialFormatRemainsReadable() throws {
        let key = "test-git-account-" + UUID().uuidString
        defer { try? SecureStore.remove(key) }
        try SecureStore.set(Data(#"{"account":{"login":"legacy","name":"Existing Account"},"token":"existing-token"}"#.utf8), for: key)
        let store = GitAccountStore(key: key)
        store.reload()
        XCTAssertEqual(store.account?.login, "legacy")
        XCTAssertEqual(try store.credential()?.token, "existing-token")
    }
}
