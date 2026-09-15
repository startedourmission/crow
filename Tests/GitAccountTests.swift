import XCTest
import CrowCore
@testable import Crow

final class GitAccountTests: XCTestCase {
    func testCloneAddressesAndDestinationValidation() throws {
        for source in ["https://github.com/team/project.git", "git@github.com:team/project.git", "ssh://git@host:2222/team/project.git", "/tmp/project.git"] {
            let request = try GitCloneRequest(source: source, parent: "~/Projects", folder: "project")
            XCTAssertEqual(GitCloneRequest.suggestedFolder(source), "project")
            XCTAssertTrue(request.command().contains("clone --progress -- "))
        }
        for source in ["-upload-pack=bad", "ext::sh -c bad", "https://user:secret@github.com/team/project.git", "https://github.com/team/project.git?token=secret", "git@host:repo\nwhoami"] {
            XCTAssertThrowsError(try GitCloneRequest(source: source, parent: "~", folder: "project"))
        }
        for folder in ["", ".", "..", "../project", "-project"] {
            XCTAssertThrowsError(try GitCloneRequest(source: "https://github.com/team/project.git", parent: "~", folder: folder))
        }
        XCTAssertThrowsError(try GitCloneRequest(source: "https://github.com/team/project.git", parent: "relative", folder: "project"))
        XCTAssertFalse(try GitCloneRequest(source: "https://github.com.evil.example/team/project.git", parent: "~", folder: "project").supportsSavedCredential)
        XCTAssertFalse(try GitCloneRequest(source: "git@github.com:team/project.git", parent: "~", folder: "project").supportsSavedCredential)
        XCTAssertTrue(try GitCloneRequest(source: "https://github.com/team/project.git", parent: "~", folder: "project").supportsSavedCredential)
        XCTAssertThrowsError(try GitCloneRequest.completedPath("/tmp/partial"))
    }

    #if os(macOS)
    @MainActor func testLocalClonePreservesQuotedPathsAndRejectsExistingFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-clone-'한글-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.git")
        _ = try await ReverseSSHCommand.run("/usr/bin/git", ["init", "--bare", source.path])
        let request = try GitCloneRequest(source: source.path, parent: root.path, folder: "project ' 한글 $(touch INJECTED)")
        let path = try await GitRepository.clone(request)
        let destination = root.appendingPathComponent(request.folder).resolvingSymlinksInPath()
        XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath(), destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git/HEAD").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("INJECTED").path))
        let origin = try await ReverseSSHCommand.run("/usr/bin/git", ["-C", path, "remote", "get-url", "origin"])
        XCTAssertEqual(origin, source.path)
        let marker = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        do { _ = try await GitRepository.clone(request); XCTFail("Existing folders must be refused") } catch {}
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        let empty = root.appendingPathComponent("existing-empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        do {
            _ = try await GitRepository.clone(GitCloneRequest(source: source.path, parent: root.path, folder: empty.lastPathComponent))
            XCTFail("Even existing empty folders must be refused")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty.path), [])
        let missing = try GitCloneRequest(source: root.appendingPathComponent("missing.git").path, parent: root.path, folder: "failed-clone")
        do { _ = try await GitRepository.clone(missing); XCTFail("Missing repositories must fail") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(missing.folder).path))
    }

    @MainActor func testCloneCredentialHelperOnlyAnswersGitHubHTTPSReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-clone-auth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture-user".utf8).write(to: root.appendingPathComponent("username"))
        try Data("fixture-token".utf8).write(to: root.appendingPathComponent("token"))
        let helper = root.appendingPathComponent("helper")
        try Data(GitRepository.credentialHelper(directory: root).utf8).write(to: helper)
        for (operation, protocolName, host, allowed) in [
            ("get", "https", "github.com", true), ("get", "https", "github.com:443", true),
            ("get", "https", "github.com.evil.example", false), ("get", "http", "github.com", false),
            ("get", "https", "github.com:8443", false), ("store", "https", "github.com", false)] {
            let input = Data("protocol=\(protocolName)\nhost=\(host)\n\n".utf8)
            let result = try await ReverseSSHCommand.run("/bin/sh", [helper.path, operation], input: input)
            XCTAssertEqual(result, allowed ? "username=fixture-user\npassword=fixture-token" : "")
        }
    }
    #endif

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
