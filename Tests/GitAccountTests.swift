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

    func testTokenValidationUsesFixedEndpointAndSanitizedErrors() throws {
        let request = try GitAccountAPI.request(token: " test-token ")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/user")
        XCTAssertNil(request.url?.user)
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        for token in ["", "bad\r\nX-Header: value", "two words", "한글", String(repeating: "a", count: 8193)] {
            XCTAssertThrowsError(try GitAccountAPI.request(token: token))
        }
        let data = Data(#"{"login":"octocat","name":"Octo Cat"}"#.utf8)
        XCTAssertEqual(try GitAccountAPI.account(data: data, status: 200).login, "octocat")
        for status in [301, 401, 403, 429, 500] {
            XCTAssertThrowsError(try GitAccountAPI.account(data: Data("secret-token".utf8), status: status)) {
                XCTAssertFalse($0.localizedDescription.contains("secret-token"))
            }
        }
        XCTAssertThrowsError(try GitAccountAPI.account(data: Data("{}".utf8), status: 200))
    }

    @MainActor func testKeychainSaveRestoreFailedReplacementAndRemoval() async throws {
        let key = "test-git-account-" + UUID().uuidString
        defer { try? SecureStore.remove(key) }
        let store = GitAccountStore(key: key)
        store.reload()
        XCTAssertNil(store.account)
        let account = GitHubAccount(login: "fixture", name: "Fixture")
        try store.store(account, token: "test-only-token")
        let previous = try SecureStore.data(for: key)
        let restored = GitAccountStore(key: key)
        restored.reload()
        XCTAssertEqual(restored.account, account)
        do { try await store.save(token: "bad\ntoken"); XCTFail("Invalid token must fail") } catch {}
        XCTAssertEqual(try SecureStore.data(for: key), previous)
        XCTAssertEqual(store.account, account)
        try store.remove()
        XCTAssertNil(try SecureStore.data(for: key))
        XCTAssertNil(store.account)
    }
}
