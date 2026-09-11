import XCTest
import CrowCore
@preconcurrency import Crypto
@preconcurrency import Citadel
@testable import Crow

final class SSHKeyStoreTests: XCTestCase {
    private var store: SSHKeyStore!
    override func setUpWithError() throws {
        store = SSHKeyStore(account: "test-ssh-keys-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try SecureStore.remove(store.account) }

    func testGeneratedKeyPersistsAndSignsWithMatchingPublicKey() throws {
        let generated = try store.generate(name: "  Test key  ")
        let restored = try SSHKeyStore(account: store.account).identity(generated.id)
        XCTAssertEqual(restored.name, "Test key")
        XCTAssertEqual(restored.authentication, .ed25519)
        let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: restored.credential.privateKey)
        let blob = try XCTUnwrap(Data(base64Encoded: String(restored.publicKey.split(separator: " ")[1])))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(blob.suffix(32)))
        let message = Data("crow-key-authentication-test".utf8)
        XCTAssertTrue(publicKey.isValidSignature(try privateKey.signature(for: message), for: message))
        XCTAssertEqual(restored.publicKey, generated.publicKey)
        XCTAssertTrue(restored.fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(restored.fingerprint.contains("="))
    }

    func testSharedReferenceSurvivesRenameAndCannotBeDeletedWhileUsed() throws {
        let key = try store.generate(name: "Shared")
        let hosts = (0..<2).map { SSHHost(name: "Test \($0)", hostname: "example.invalid", username: "test") }
        defer { for host in hosts { try? SecureStore.remove(host.id.rawValue.uuidString) } }
        let reference = HostCredential(keyID: key.id)
        for host in hosts { try SecureStore.set(JSONEncoder().encode(reference), for: host.id.rawValue.uuidString) }
        try store.rename(key.id, to: "Renamed")
        XCTAssertEqual(try store.identity(key.id).name, "Renamed")
        for host in hosts {
            let saved = try SecureStore.credential(host)
            XCTAssertTrue(saved.privateKey.isEmpty)
            try saved.resolved(for: .ed25519, keys: store).validatePrivateKey(for: .ed25519)
        }
        XCTAssertThrowsError(try store.remove(key.id, hosts: hosts))
        XCTAssertEqual(try store.identities().count, 1)
        for host in hosts { try SecureStore.remove(host.id.rawValue.uuidString) }
        try store.remove(key.id, hosts: hosts)
        XCTAssertTrue(try store.identities().isEmpty)
        XCTAssertThrowsError(try reference.resolved(for: .ed25519, keys: store))
    }

    func testImportRejectsDuplicatesPublicKeysInvalidNamesAndWrongTypes() throws {
        let key = Curve25519.Signing.PrivateKey().makeSSHRepresentation()
        let imported = try store.importKey(name: "Imported", privateKey: key, passphrase: "")
        XCTAssertThrowsError(try store.importKey(name: "Duplicate", privateKey: key, passphrase: ""))
        XCTAssertThrowsError(try store.importKey(name: "Public", privateKey: imported.publicKey, passphrase: ""))
        XCTAssertThrowsError(try store.generate(name: "  "))
        XCTAssertThrowsError(try store.rename(imported.id, to: "name\nwith newline"))
        XCTAssertThrowsError(try HostCredential(keyID: imported.id).resolved(for: .rsa, keys: store))
        XCTAssertEqual(try store.identities().count, 1)
    }

    func testLegacyHostCredentialsStillDecodeAndResolve() throws {
        let original = HostCredential(privateKey: Curve25519.Signing.PrivateKey().makeSSHRepresentation())
        let legacy = try JSONSerialization.data(withJSONObject: ["password": "", "privateKey": original.privateKey, "passphrase": ""])
        let restored = try JSONDecoder().decode(HostCredential.self, from: legacy)
        XCTAssertNil(restored.keyID)
        XCTAssertEqual(try restored.resolved(for: .ed25519, keys: store).privateKey, original.privateKey)
    }

    func testUnreadableLibraryIsNotOverwritten() throws {
        let corrupted = Data("not-json".utf8)
        try SecureStore.set(corrupted, for: store.account)
        XCTAssertThrowsError(try store.generate(name: "Must not overwrite"))
        XCTAssertEqual(try SecureStore.data(for: store.account), corrupted)
    }

    #if os(macOS)
    func testSystemDiscoveryFindsKeysWithoutChangingFilesAndSkipsDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-discovery-test-" + UUID().uuidString)
        XCTAssertTrue(try store.discoverSystemKeys(in: root).isEmpty)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let privateKey = Curve25519.Signing.PrivateKey().makeSSHRepresentation()
        let file = root.appendingPathComponent("id_ed25519")
        try Data(privateKey.utf8).write(to: file)
        try Data("Host example\n  Hostname example.invalid\n".utf8).write(to: root.appendingPathComponent("config"))
        try Data("ssh-ed25519 AAAA public-only".utf8).write(to: root.appendingPathComponent("id_ed25519.pub"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-key"), withDestinationURL: file)
        let oversizedField = Data("openssh-key-v1\0".utf8) + Data([255, 255, 255, 255])
        try Data(("-----BEGIN OPENSSH PRIVATE KEY-----\n" + oversizedField.base64EncodedString()
            + "\n-----END OPENSSH PRIVATE KEY-----\n").utf8).write(to: root.appendingPathComponent("malformed"))
        let discovered = try store.discoverSystemKeys(in: root)
        XCTAssertEqual(discovered.count, 1)
        let found = try XCTUnwrap(discovered.first)
        XCTAssertEqual(found.name, "id_ed25519")
        XCTAssertEqual(found.authentication, .ed25519)
        XCTAssertFalse(found.encrypted)
        XCTAssertTrue(try store.identities().isEmpty, "Discovery must not silently copy private keys into Keychain")
        let imported = try store.importSystemKey(found, passphrase: "")
        XCTAssertEqual(imported.publicKey, found.publicKey)
        XCTAssertEqual(imported.fingerprint, found.fingerprint)
        XCTAssertTrue(try store.discoverSystemKeys(in: root).isEmpty, "Already saved keys must not appear twice")
        XCTAssertEqual(try store.importSystemKey(found, passphrase: "").id, imported.id)
        try store.remove(imported.id, hosts: [])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), privateKey)
        XCTAssertEqual(try store.discoverSystemKeys(in: root).count, 1, "Removing the saved copy must preserve the original key")
        try Data(Curve25519.Signing.PrivateKey().makeSSHRepresentation().utf8).write(to: file)
        XCTAssertThrowsError(try store.importSystemKey(found, passphrase: ""), "A changed fingerprint requires discovery again")
        XCTAssertTrue(try store.identities().isEmpty)
    }

    func testOpenSSHAcceptsGeneratedKeyAndEncryptedRSAImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-key-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        func keygen(_ arguments: [String]) throws -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = arguments; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = try store.generate(name: "Generated")
        let file = root.appendingPathComponent("generated")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(key.credential.privateKey.utf8), attributes: [.posixPermissions: 0o600]))
        XCTAssertEqual(try keygen(["-y", "-f", file.path]), key.publicKey)
        let fingerprint = try keygen(["-l", "-E", "sha256", "-f", file.path])
        XCTAssertTrue(fingerprint.contains(key.fingerprint))
        let rsa = root.appendingPathComponent("rsa")
        _ = try keygen(["-q", "-t", "rsa", "-b", "2048", "-C", "", "-N", "fixture-passphrase", "-f", rsa.path])
        let privateKey = try String(contentsOf: rsa, encoding: .utf8)
        let discovered = try XCTUnwrap(store.discoverSystemKeys(in: root).first)
        XCTAssertEqual(discovered.name, "rsa")
        XCTAssertTrue(discovered.encrypted)
        XCTAssertThrowsError(try store.importSystemKey(discovered, passphrase: "wrong"))
        let imported = try store.importSystemKey(discovered, passphrase: "fixture-passphrase")
        XCTAssertEqual(try String(contentsOf: rsa, encoding: .utf8), privateKey)
        XCTAssertEqual(imported.authentication, .rsa)
        XCTAssertEqual(imported.publicKey, try keygen(["-y", "-P", "fixture-passphrase", "-f", rsa.path]))
        try imported.credential.validatePrivateKey(for: .rsa)
    }
    #endif
}
