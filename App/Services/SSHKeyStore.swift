import Foundation
import CrowCore
@preconcurrency import Crypto
@preconcurrency import Citadel
@preconcurrency import NIOSSH

struct SSHIdentity: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let authentication: SSHAuthenticationKind
    let publicKey: String
    let credential: HostCredential
    let createdAt: Date

    var fingerprint: String {
        let encoded = publicKey.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return "SHA256:" + Data(SHA256.hash(data: Data(base64Encoded: encoded) ?? Data()))
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    var publicKeyLine: String { publicKey + " " + name }
}

/// The complete library lives in this device's Keychain, including imported passphrases.
struct SSHKeyStore {
    static let shared = SSHKeyStore(account: "ssh-identities-v1")
    let account: String

    func identities() throws -> [SSHIdentity] {
        guard let data = try SecureStore.data(for: account) else { return [] }
        return try JSONDecoder().decode([SSHIdentity].self, from: data)
    }

    func identity(_ id: UUID) throws -> SSHIdentity {
        guard let key = try identities().first(where: { $0.id == id }) else {
            throw CommandError("This SSH key is missing. Choose another key in the host settings.")
        }
        return key
    }

    @discardableResult func generate(name: String) throws -> SSHIdentity {
        let key = Curve25519.Signing.PrivateKey()
        return try importKey(name: name, privateKey: key.makeSSHRepresentation(), passphrase: "")
    }

    @discardableResult func importKey(name: String, privateKey: String, passphrase: String) throws -> SSHIdentity {
        let name = try validName(name)
        guard privateKey.contains("-----BEGIN OPENSSH PRIVATE KEY-----") else {
            throw CommandError("Choose an OpenSSH private key, not a .pub public key.")
        }
        let decryption = passphrase.isEmpty ? nil : Data(passphrase.utf8)
        let authentication: SSHAuthenticationKind
        let publicKey: String
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: privateKey, decryptionKey: decryption) {
            authentication = .ed25519
            publicKey = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
        } else if let key = try? Insecure.RSA.PrivateKey(sshRsa: privateKey, decryptionKey: decryption) {
            authentication = .rsa
            publicKey = String(openSSHPublicKey: NIOSSHPrivateKey(custom: key).publicKey)
        } else {
            throw CommandError("Could not read this key. Use an Ed25519 or RSA OpenSSH key and check its passphrase.")
        }
        var keys = try identities()
        guard !keys.contains(where: { $0.publicKey == publicKey }) else {
            throw CommandError("This key is already in SSH Keys. Select the existing key instead.")
        }
        let key = SSHIdentity(id: UUID(), name: name, authentication: authentication, publicKey: publicKey,
            credential: HostCredential(privateKey: privateKey, passphrase: passphrase), createdAt: Date())
        keys.append(key)
        try save(keys)
        return key
    }

    func rename(_ id: UUID, to name: String) throws {
        var keys = try identities()
        guard let index = keys.firstIndex(where: { $0.id == id }) else { throw CommandError("This SSH key is missing.") }
        keys[index].name = try validName(name)
        try save(keys)
    }

    func remove(_ id: UUID, hosts: [SSHHost]) throws {
        let users = try hosts.filter { try SecureStore.credential($0).keyID == id }
        guard users.isEmpty else {
            throw CommandError("Used by \(users.map(\.name).joined(separator: ", ")). Choose another key for these hosts before deleting it.")
        }
        try save(identities().filter { $0.id != id })
    }

    private func validName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CommandError("Enter a key name of 1–100 characters on one line.")
        }
        return name
    }
    private func save(_ keys: [SSHIdentity]) throws {
        try SecureStore.set(JSONEncoder().encode(keys), for: account)
    }
}

#if os(macOS)
struct DiscoveredSSHKey: Identifiable {
    let url: URL
    let publicKey: String
    let authentication: SSHAuthenticationKind
    let encrypted: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var fingerprint: String {
        let encoded = publicKey.split(separator: " ")[1]
        return "SHA256:" + Data(SHA256.hash(data: Data(base64Encoded: String(encoded)) ?? Data()))
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

extension SSHKeyStore {
    /// Discovery reads the public envelope only. Encrypted private material is opened on selection.
    func discoverSystemKeys(in directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")) throws -> [DiscoveredSSHKey] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var seen = Set(try identities().map(\.publicKey))
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let key = try? Self.inspectSystemKey(at: url), seen.insert(key.publicKey).inserted else { return nil }
            return key
        }
    }

    func importSystemKey(_ discovered: DiscoveredSSHKey, passphrase: String) throws -> SSHIdentity {
        let text = try Self.readSystemKey(at: discovered.url)
        let current = try Self.inspectSystemKey(at: discovered.url, contents: text)
        guard current.publicKey == discovered.publicKey else {
            throw CommandError("This key file changed. Refresh SSH Keys before selecting it again.")
        }
        if let existing = try identities().first(where: { $0.publicKey == current.publicKey }) { return existing }
        return try importKey(name: current.name, privateKey: text, passphrase: passphrase)
    }

    private static func readSystemKey(at url: URL) throws -> String {
        let resolved = url.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 1_048_576 else {
            throw CommandError("Choose a regular OpenSSH private key file smaller than 1 MB.")
        }
        return try String(contentsOf: resolved, encoding: .utf8)
    }

    private static func inspectSystemKey(at url: URL, contents: String? = nil) throws -> DiscoveredSSHKey {
        let text = try contents ?? readSystemKey(at: url)
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.first == Substring(begin), lines.last == Substring(end),
              let data = Data(base64Encoded: lines.dropFirst().dropLast().joined()) else {
            throw CommandError("Not an OpenSSH private key.")
        }
        let prefix = Data("openssh-key-v1\0".utf8)
        guard data.starts(with: prefix) else { throw CommandError("Invalid OpenSSH key header.") }
        var cursor = prefix.count
        func integer() throws -> Int {
            guard cursor <= data.count - 4 else { throw CommandError("Incomplete OpenSSH key.") }
            let value = data[cursor..<cursor + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            cursor += 4
            return Int(value)
        }
        func field() throws -> Data {
            let count = try integer()
            guard count <= data.count - cursor else { throw CommandError("Incomplete OpenSSH key.") }
            defer { cursor += count }
            return Data(data[cursor..<cursor + count])
        }
        let cipher = String(decoding: try field(), as: UTF8.self)
        _ = try field() // KDF name
        _ = try field() // KDF options
        guard try integer() == 1 else { throw CommandError("Unsupported OpenSSH key count.") }
        let publicBlob = try field()
        guard !(try field()).isEmpty, publicBlob.count >= 4 else { throw CommandError("Incomplete OpenSSH key.") }
        let typeLength = publicBlob.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard typeLength <= publicBlob.count - 4 else { throw CommandError("Invalid public key.") }
        let type = String(decoding: publicBlob[4..<4 + typeLength], as: UTF8.self)
        let authentication: SSHAuthenticationKind
        switch type {
        case "ssh-ed25519": authentication = .ed25519
        case "ssh-rsa": authentication = .rsa
        default: throw CommandError("Use an Ed25519 or RSA key.")
        }
        return DiscoveredSSHKey(url: url, publicKey: type + " " + publicBlob.base64EncodedString(),
            authentication: authentication, encrypted: cipher != "none")
    }
}
#endif
