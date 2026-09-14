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

    func testOAuthHTTPFailuresExplainConfigurationAndNeverExposeResponseSecrets() throws {
        let valid = Data("{}".utf8)
        XCTAssertEqual(try GitHubOAuth.checkedResponse(valid, status: 200), valid)
        for (status, code, expected) in [(404, "Not Found", "Client ID"), (400, "device_flow_disabled", "Device Flow"),
                                          (429, "unknown", "429"), (503, "unknown", "503")] {
            let data = Data(("{\"error\":\"" + code + "\",\"error_description\":\"private-code\"}").utf8)
            XCTAssertThrowsError(try GitHubOAuth.checkedResponse(data, status: status)) {
                XCTAssertTrue($0.localizedDescription.contains(expected))
                XCTAssertFalse($0.localizedDescription.contains("private-code"))
            }
        }
    }

    func testOAuthClientIDCanBeConfiguredWithoutRebuilding() throws {
        XCTAssertNil(GitHubOAuth.configuredClientID(override: "", bundled: "$(CROW_GITHUB_CLIENT_ID)"))
        XCTAssertEqual(GitHubOAuth.configuredClientID(override: "  custom123  ", bundled: "build123"), "custom123")
        XCTAssertEqual(GitHubOAuth.configuredClientID(override: "  ", bundled: "build123"), "build123")
        XCTAssertNil(GitHubOAuth.configuredClientID(override: "invalid id", bundled: "build123"))
        let id = try XCTUnwrap(GitHubOAuth.configuredClientID(override: "custom123", bundled: ""))
        let request = try GitHubOAuth.request(clientID: id)
        XCTAssertTrue(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("client_id=custom123"))
        for (code, expected) in [("incorrect_client_credentials", "Client ID"), ("device_flow_disabled", "Device Flow")] {
            XCTAssertThrowsError(try GitHubOAuth.authorization(Data(("{\"error\":\"" + code + "\"}").utf8))) {
                XCTAssertTrue($0.localizedDescription.contains(expected))
            }
        }
    }

    func testOAuthUsesFixedEndpointsAndEncodesDeviceCredentialsInPOSTBody() throws {
        let start = try GitHubOAuth.request(clientID: "Iv1.crowfixture")
        XCTAssertEqual(start.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(start.httpMethod, "POST")
        XCTAssertNil(start.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(String(decoding: start.httpBody!, as: UTF8.self).contains("scope=read%3Auser"))
        let poll = try GitHubOAuth.request(clientID: "Iv1.crowfixture", deviceCode: "private&code=1")
        XCTAssertEqual(poll.url?.absoluteString, "https://github.com/login/oauth/access_token")
        XCTAssertNil(poll.url?.query)
        XCTAssertTrue(String(decoding: poll.httpBody!, as: UTF8.self).contains("device_code=private%26code%3D1"))
        for id in ["", "$(CROW_GITHUB_CLIENT_ID)", "bad\nvalue"] {
            XCTAssertThrowsError(try GitHubOAuth.request(clientID: id))
        }
    }

    func testOAuthRejectsUntrustedVerificationURLsAndHandlesApprovalStates() throws {
        let valid = #"{"device_code":"private-code","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
        let code = try GitHubOAuth.authorization(Data(valid.utf8))
        XCTAssertEqual(code.user_code, "ABCD-EFGH")
        XCTAssertEqual(code.interval, 5)
        for invalid in [valid.replacingOccurrences(of: "https://github.com/", with: "https://github.com.evil.example/"),
                        valid.replacingOccurrences(of: "\"interval\":5", with: "\"interval\":0"),
                        valid.replacingOccurrences(of: "\"expires_in\":900", with: "\"expires_in\":-1")] {
            XCTAssertThrowsError(try GitHubOAuth.authorization(Data(invalid.utf8)))
        }
        XCTAssertEqual(try GitHubOAuth.pollResult(Data(#"{"error":"authorization_pending"}"#.utf8)), .pending)
        XCTAssertEqual(try GitHubOAuth.pollResult(Data(#"{"error":"slow_down"}"#.utf8)), .slowDown)
        XCTAssertEqual(try GitHubOAuth.pollResult(Data(#"{"access_token":"fixture-token","token_type":"bearer"}"#.utf8)), .token("fixture-token"))
        for error in ["access_denied", "expired_token", "incorrect_client_credentials", "unknown"] {
            let data = Data(("{\"error\":\"" + error + "\",\"error_description\":\"private-token\"}").utf8)
            XCTAssertThrowsError(try GitHubOAuth.pollResult(data)) {
                XCTAssertFalse($0.localizedDescription.contains("private-token"))
            }
        }
        XCTAssertThrowsError(try GitHubOAuth.pollResult(Data(#"{"access_token":"bad token","token_type":"bearer"}"#.utf8)))
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
