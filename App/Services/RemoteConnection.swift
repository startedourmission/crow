import Foundation
import Security
@preconcurrency import Citadel
@preconcurrency import Crypto
@preconcurrency import NIOCore
@preconcurrency import NIOSSH
import CrowCore

struct HostCredential: Codable, Sendable {
    var password = ""
    var privateKey = ""
    var passphrase = ""
}

enum SecureStore {
    static func data(for account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.chajinwoo.crow", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        return result as? Data
    }

    static func set(_ data: Data, for account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.chajinwoo.crow", kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw keychainError(added) }
        } else if status != errSecSuccess { throw keychainError(status) }
    }

    static func remove(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.chajinwoo.crow", kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        ])
    }

    static func credential(_ host: SSHHost) throws -> HostCredential {
        guard let data = try data(for: host.id.rawValue.uuidString) else { return HostCredential() }
        return try JSONDecoder().decode(HostCredential.self, from: data)
    }
}

struct HostKeyChallenge: Error, Identifiable, LocalizedError, Sendable {
    var id: String { account }
    let host: SSHHost
    let key: String
    let changed: Bool
    var account: String { "host-key:\(host.hostname.lowercased()):\(host.port)" }
    var fingerprint: String {
        let encoded = key.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return "SHA256:" + Data(SHA256.hash(data: Data(base64Encoded: encoded) ?? Data())).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }
    var errorDescription: String? {
        "\(host.hostname):\(host.port)\n\(fingerprint)\n" + (changed
            ? "The host key has CHANGED. Verify the new fingerprint with your server administrator before replacing it."
            : "Verify this fingerprint with your server before trusting this first connection.")
    }
}

private final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: SSHHost
    let trusted: String?
    private let lock = NSLock()
    private var observed: HostKeyChallenge?
    var challenge: HostKeyChallenge? { lock.withLock { observed } }

    init(host: SSHHost, trusted: String?) { self.host = host; self.trusted = trusted }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        if key == trusted { validationCompletePromise.succeed(()); return }
        let failure = HostKeyChallenge(host: host, key: key, changed: trusted != nil)
        lock.withLock { observed = failure }
        validationCompletePromise.fail(failure)
    }
}

@MainActor
final class RemoteConnection {
    private(set) var client: SSHClient?
    private var sftp: SFTPClient?
    #if os(macOS)
    private var system: SystemSFTP?
    func attach(_ spec: SystemSSHSpec) throws { system = try SystemSFTP(spec: spec) }
    #endif
    var isConnected: Bool {
        #if os(macOS)
        if let system { return system.isConnected }
        #endif
        return client?.isConnected ?? false
    }

    func connect(_ host: SSHHost, credential: HostCredential) async throws {
        let keyAccount = "host-key:\(host.hostname.lowercased()):\(host.port)"
        let trusted = try SecureStore.data(for: keyAccount).flatMap { String(data: $0, encoding: .utf8) }
        let check = HostKeyCheck(host: host, trusted: trusted)
        let authentication: @Sendable () -> SSHAuthenticationMethod
        switch host.authentication {
        case .password:
            authentication = { .passwordBased(username: host.username, password: credential.password) }
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: credential.privateKey,
                decryptionKey: credential.passphrase.isEmpty ? nil : Data(credential.passphrase.utf8))
            authentication = { .ed25519(username: host.username, privateKey: key) }
        case .rsa:
            let key = try Insecure.RSA.PrivateKey(sshRsa: credential.privateKey,
                decryptionKey: credential.passphrase.isEmpty ? nil : Data(credential.passphrase.utf8))
            authentication = { .rsa(username: host.username, privateKey: key) }
        }
        var settings = SSHClientSettings(host: host.hostname, port: host.port,
            authenticationMethod: authentication, hostKeyValidator: .custom(check))
        settings.connectTimeout = .seconds(20)
        do { client = try await SSHClient.connect(to: settings) }
        catch { if let challenge = check.challenge { throw challenge }; throw error }
    }

    func disconnect() async {
        #if os(macOS)
        system?.close(); system = nil
        #endif
        let old = client
        client = nil
        sftp = nil
        try? await old?.close()
    }

    private func files() async throws -> SFTPClient {
        if let sftp { return sftp }
        guard let client else { throw FileFailure.disconnected }
        let opened = try await client.openSFTP()
        sftp = opened
        return opened
    }

    func realPath(_ path: String) async throws -> String {
        #if os(macOS)
        if let system { return try await system.realPath(path) }
        #endif
        let sftp = try await files()
        let home = try await sftp.getRealPath(atPath: ".")
        let requested = path == "~" ? home : path.hasPrefix("~/") ? home + "/" + path.dropFirst(2) : path
        return try await sftp.getRealPath(atPath: requested)
    }

    func list(_ path: String) async throws -> [FileEntry] {
        #if os(macOS)
        if let system { return try await system.list(path) }
        #endif
        let sftp = try await files()
        let messages = try await sftp.listDirectory(atPath: path)
        var entries: [FileEntry] = []
        for message in messages {
            for component in message.components where component.filename != "." && component.filename != ".." {
                let directory = ((component.attributes.permissions ?? 0) & 0o170000) == 0o040000
                entries.append(FileEntry(name: component.filename,
                    path: (path as NSString).appendingPathComponent(component.filename), isDirectory: directory))
            }
        }
        return entries.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    func read(_ path: String, maximumSize: Int = TextFiles.sizeLimit) async throws -> String {
        #if os(macOS)
        if let system { return try await system.read(path, maximumSize: maximumSize) }
        #endif
        let sftp = try await files()
        let attributes = try await sftp.getAttributes(at: path)
        guard (attributes.size ?? 0) <= maximumSize else { throw FileFailure.tooLarge }
        let bytes = try await sftp.withFile(filePath: path, flags: .read) { file in
            var data = Data()
            while true {
                let chunk = try await file.read(from: UInt64(data.count), length: 32_768)
                if chunk.readableBytes == 0 { break }
                data.append(contentsOf: chunk.readableBytesView)
                if data.count > maximumSize { throw FileFailure.tooLarge }
            }
            return data
        }
        return try TextFiles.decode(bytes)
    }

    func write(_ text: String, path: String, expected: String?, overwrite: Bool = false) async throws {
        #if os(macOS)
        if let system { try await system.write(text, path: path, expected: expected, overwrite: overwrite); return }
        #endif
        if !overwrite, let expected, try await read(path) != expected { throw FileFailure.conflict }
        let sftp = try await files()
        // Upload to a sibling first. A failed upload never truncates the original.
        let temporary = path + ".crow-upload-" + UUID().uuidString
        do {
            let permissions = try await sftp.getAttributes(at: path).permissions
            var attributes = SFTPFileAttributes()
            attributes.permissions = permissions
            try await sftp.withFile(filePath: temporary, flags: [.write, .create, .forceCreate], attributes: attributes) { file in
                let data = Array(text.utf8)
                for offset in stride(from: 0, to: data.count, by: 32_768) {
                    try await file.write(ByteBuffer(bytes: data[offset..<min(data.count, offset + 32_768)]), at: UInt64(offset))
                }
            }
            if !overwrite, let expected, try await read(path) != expected { throw FileFailure.conflict }
            // SFTP v3 does not promise rename-over-existing. Keep a rollback copy
            // until replacement succeeds, instead of deleting the original first.
            let backup = path + ".crow-backup-" + UUID().uuidString
            try await sftp.rename(at: path, to: backup)
            do { try await sftp.rename(at: temporary, to: path) }
            catch {
                do { try await sftp.rename(at: backup, to: path) }
                catch {
                    throw NSError(domain: "Crow.SFTP", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        "Upload failed. The original is recoverable at \(backup). Your edited text is still open."])
                }
                throw error
            }
            try? await sftp.remove(at: backup)
        } catch {
            try? await sftp.remove(at: temporary)
            throw error
        }
    }

    func create(_ path: String, directory: Bool) async throws {
        #if os(macOS)
        if let system { try await system.create(path, directory: directory); return }
        #endif
        let sftp = try await files()
        if directory { try await sftp.createDirectory(atPath: path) }
        else { try await sftp.withFile(filePath: path, flags: [.write, .create, .forceCreate]) { _ in } }
    }

    func rename(_ source: String, to destination: String) async throws {
        #if os(macOS)
        if let system { try await system.rename(source, to: destination); return }
        #endif
        try await files().rename(at: source, to: destination)
    }

    func trash(_ entry: FileEntry) async throws -> String {
        // Recoverable remote deletion: move to a uniquely named hidden sibling.
        let target = (entry.path as NSString).deletingLastPathComponent + "/.crow-trash-" + UUID().uuidString + "-" + entry.name
        try await rename(entry.path, to: target)
        return target
    }
}
