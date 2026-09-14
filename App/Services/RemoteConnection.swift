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
    var keyID: UUID?

    func resolved(for authentication: SSHAuthenticationKind, keys: SSHKeyStore = .shared) throws -> HostCredential {
        guard authentication != .password, let keyID else { return self }
        let key = try keys.identity(keyID)
        guard key.authentication == authentication else { throw CommandError("The selected SSH key type does not match this host.") }
        return key.credential
    }

    func validatePrivateKey(for authentication: SSHAuthenticationKind) throws {
        guard !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandError("Import your OpenSSH private key from Files before saving.")
        }
        guard privateKey.contains("-----BEGIN OPENSSH PRIVATE KEY-----") else {
            throw CommandError("Choose an OpenSSH private key such as id_ed25519 or id_rsa, not the .pub public key.")
        }
        do {
            let decryptionKey = passphrase.isEmpty ? nil : Data(passphrase.utf8)
            switch authentication {
            case .ed25519: _ = try Curve25519.Signing.PrivateKey(sshEd25519: privateKey, decryptionKey: decryptionKey)
            case .rsa: _ = try Insecure.RSA.PrivateKey(sshRsa: privateKey, decryptionKey: decryptionKey)
            case .password: break
            }
        } catch {
            throw CommandError("Could not read the private key. Check the selected key type and passphrase.")
        }
    }
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
        let credential = try credential.resolved(for: host.authentication)
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

    func gitStatus(path: String) async throws -> RepositorySnapshot {
        try GitRepository.parse(await gitData(query: GitRepository.query(path: path)))
    }

    func gitProjects(path: String) async throws -> GitProjectList {
        try GitRepository.parseProjects(await gitData(query: GitRepository.projectsQuery(path: path)))
    }

    func workspaceCommand(_ command: String, operation: String = "tmux") async throws -> String {
        String(decoding: try await gitData(query: command, operation: operation), as: UTF8.self)
    }

    private func gitData(query: String, operation: String = "Git") async throws -> Data {
        guard let client, client.isConnected else { throw FileFailure.disconnected }
        let command = "sh -c " + GitRepository.quote(query)
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var output = Data(), diagnostic = Data()
                var completed = false
                do {
                    try await client.withExec(command) { inbound, _ in
                        for try await chunk in inbound {
                            try Task.checkCancellation()
                            switch chunk {
                            case .stdout(let bytes): output.append(contentsOf: bytes.readableBytesView)
                            case .stderr(let bytes): diagnostic.append(contentsOf: bytes.readableBytesView)
                            }
                            guard output.count + diagnostic.count <= 8 * 1024 * 1024 else {
                                throw CommandError("\(operation) output is too large to display.")
                            }
                        }
                        try Task.checkCancellation()
                        completed = true
                    }
                } catch ChannelError.alreadyClosed where completed {
                    // Citadel closes the command channel after EOF; the server can
                    // finish closing it first. The successful output is still valid.
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if !diagnostic.isEmpty {
                        throw CommandError(String(decoding: diagnostic.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    throw error
                }
                return output
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                throw CommandError("\(operation) request timed out. The terminal connection was left open.")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? Data()
        }
        try Task.checkCancellation()
        return data
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
        do {
            let sftp = try await files()
            let home = try await sftp.getRealPath(atPath: ".")
            let requested = path == "~" ? home : path.hasPrefix("~/") ? home + "/" + path.dropFirst(2) : path
            return try await sftp.getRealPath(atPath: requested)
        } catch { throw folderError(error, path: path) }
    }

    func list(_ path: String) async throws -> [FileEntry] {
        try await listing(path).map(\.entry)
    }
    func listing(_ path: String) async throws -> [RemoteFileListing] {
        #if os(macOS)
        if let system { return try await system.listing(path) }
        #endif
        let messages: [SFTPMessage.Name]
        do { messages = try await files().listDirectory(atPath: path) }
        catch { throw folderError(error, path: path) }
        var entries: [RemoteFileListing] = []
        for message in messages {
            for component in message.components where component.filename != "." && component.filename != ".." {
                let directory = ((component.attributes.permissions ?? 0) & 0o170000) == 0o040000
                entries.append(RemoteFileListing(entry: FileEntry(name: component.filename,
                    path: (path as NSString).appendingPathComponent(component.filename), isDirectory: directory),
                    size: component.attributes.size, modified: component.attributes.accessModificationTime?.modificationTime,
                    permissions: component.attributes.permissions))
            }
        }
        return entries.sorted { left, right in
            if left.entry.isDirectory != right.entry.isDirectory { return left.entry.isDirectory }
            return left.entry.name.localizedStandardCompare(right.entry.name) == .orderedAscending
        }
    }

    private func folderError(_ error: Error, path: String) -> Error {
        let status: SFTPMessage.Status
        if let value = error as? SFTPMessage.Status { status = value }
        else if case SFTPError.errorStatus(let value) = error { status = value }
        else { return error }
        let detail = status.errorCode == .permissionDenied
            ? "The SSH server denied access to this folder. Check permissions on the server, including access to iCloud Drive if this is a Mac."
            : status.message
        return CommandError("Cannot open remote folder: \(path)\nSFTP \(status.errorCode.rawValue): \(detail)")
    }

    func revision(_ path: String) async throws -> FileRevision {
        #if os(macOS)
        if let system { return try await system.revision(path) }
        #endif
        let attributes = try await files().getAttributes(at: path)
        return FileRevision(size: attributes.size, modified: attributes.accessModificationTime?.modificationTime)
    }

    func uploadClipboardImage(_ data: Data) async throws -> String {
        try ClipboardImage.validate(data)
        #if os(macOS)
        if let system { return try await system.uploadClipboardImage(data) }
        #endif
        let sftp = try await files()
        let directory = "/tmp/crow-clipboard-" + UUID().uuidString
        let path = directory + "/image.png"
        var directoryAttributes = SFTPFileAttributes(); directoryAttributes.permissions = 0o700
        var fileAttributes = SFTPFileAttributes(); fileAttributes.permissions = 0o600
        try await sftp.createDirectory(atPath: directory, attributes: directoryAttributes)
        do {
            try await sftp.withFile(filePath: path, flags: [.write, .create, .forceCreate], attributes: fileAttributes) { file in
                for offset in stride(from: 0, to: data.count, by: 32_768) {
                    try Task.checkCancellation()
                    try await file.write(ByteBuffer(bytes: data[offset..<min(offset + 32_768, data.count)]), at: UInt64(offset))
                }
            }
            return path
        } catch {
            try? await sftp.remove(at: path)
            try? await sftp.rmdir(at: directory)
            throw error
        }
    }

    func read(_ path: String, maximumSize: Int = TextFiles.sizeLimit) async throws -> String {
        try TextFiles.decode(await readData(path, maximumSize: maximumSize))
    }

    func readData(_ path: String, maximumSize: Int = TextFiles.sizeLimit) async throws -> Data {
        #if os(macOS)
        if let system { return try await system.readData(path, maximumSize: maximumSize) }
        #endif
        let sftp = try await files()
        let attributes = try await sftp.getAttributes(at: path)
        guard (attributes.size ?? 0) <= maximumSize else { throw FileFailure.tooLarge }
        let bytes = try await sftp.withFile(filePath: path, flags: .read) { file in
            var data = Data()
            while true {
                try Task.checkCancellation()
                let chunk = try await file.read(from: UInt64(data.count), length: 32_768)
                if chunk.readableBytes == 0 { break }
                data.append(contentsOf: chunk.readableBytesView)
                if data.count > maximumSize { throw FileFailure.tooLarge }
            }
            return data
        }
        return bytes
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

    private func ensurePrivateDirectory(_ path: String) async throws {
        #if os(macOS)
        if let system { try await system.ensurePrivateDirectory(path); return }
        #endif
        let sftp = try await files()
        var attributes = SFTPFileAttributes(); attributes.permissions = 0o700
        try? await sftp.createDirectory(atPath: path, attributes: attributes)
        // Directory listings expose the link's own type; STAT alone follows links.
        let parent = (path as NSString).deletingLastPathComponent
        guard try await list(parent).contains(where: { $0.path == path && $0.isDirectory }),
              let mode = try await sftp.getAttributes(at: path).permissions, mode & 0o777 == 0o700 else {
            throw CommandError("Crow storage must be a private directory (permissions 700): \(path)")
        }
    }

    static func trashCommand(path: String) -> String {
        let item = GitRepository.quote(path)
        // Foundation works without asking Finder to automate a remote desktop.
        let script = "ObjC.import('Foundation'); function run(args) { var error = Ref(); if (!$.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError($.NSURL.fileURLWithPath(args[0]), null, error)) { throw Error(ObjC.unwrap(error[0].localizedDescription)); } }"
        return "if [ \"$(uname -s)\" = Darwin ]; then /usr/bin/osascript -l JavaScript -e " + GitRepository.quote(script) + " -- " + item
            + "; elif command -v gio >/dev/null 2>&1; then gio trash -- " + item
            + "; elif command -v trash-put >/dev/null 2>&1; then trash-put -- " + item
            + "; else printf '%s\\n' 'Trash is unavailable on this server. Install gio or trash-cli, or choose Recovery Folder in Settings.'; exit 1; fi"
    }

    func trash(_ entry: FileEntry, rootPath: String? = nil) async throws -> String {
        let parent = (entry.path as NSString).deletingLastPathComponent
        let root = rootPath ?? parent
        let storage = (root as NSString).appendingPathComponent(".crow")
        let recovery = storage + "/recovery"
        guard !recovery.hasPrefix(entry.path + "/") else { throw FileFailure.invalidName }
        try await ensurePrivateDirectory(storage)
        try await ensurePrivateDirectory(recovery)
        // Consolidate old sibling recovery entries without overwriting anything.
        for old in try await list(parent) where old.path != entry.path && old.name.hasPrefix(".crow-trash-") {
            guard UUID(uuidString: String(old.name.dropFirst(".crow-trash-".count).prefix(36))) != nil else { continue }
            try await rename(old.path, to: recovery + "/legacy-" + UUID().uuidString + "-" + old.name)
        }
        let target = recovery + "/" + UUID().uuidString + "-" + entry.name
        try await rename(entry.path, to: target)
        return target
    }
}

struct RemoteFileListing: Sendable {
    var entry: FileEntry
    var size: UInt64?
    var modified: Date?
    var permissions: UInt32?
    var created: Date? = nil
}
