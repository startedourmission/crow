import Foundation
import Observation
import CrowCore

/// Display-only remote metadata. Credentials embedded in a URL are never retained.
struct GitRemoteInfo: Equatable, Sendable {
    let name: String
    let host: String
    let repository: String
    let usesSSH: Bool
    let transport: String
    var displayAddress: String { host.isEmpty ? repository : host + "/" + repository }
    var isGitHub: Bool { host == "github.com" || host == "ssh.github.com" }

    init?(name: String, url: String) {
        guard !name.isEmpty, !url.isEmpty else { return nil }
        self.name = name
        if url.contains("://"), let parts = URLComponents(string: url), let host = parts.host {
            self.host = host.lowercased()
            repository = Self.cleanPath(parts.percentEncodedPath)
            usesSSH = parts.scheme?.lowercased() == "ssh"
            transport = parts.scheme?.uppercased() ?? "Remote"
        } else if let colon = url.firstIndex(of: ":"), !url.hasPrefix("/") {
            let authority = String(url[..<colon]).split(separator: "@").last.map(String.init) ?? ""
            host = authority.lowercased()
            repository = Self.cleanPath(String(url[url.index(after: colon)...]))
            usesSSH = true
            transport = "SSH"
        } else {
            host = ""
            repository = Self.cleanPath(url)
            usesSSH = false
            transport = "Local"
        }
    }

    private static func cleanPath(_ path: String) -> String {
        var result = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Query/fragment suffixes may contain credentials; do not display them.
        if let end = result.firstIndex(where: { $0 == "?" || $0 == "#" }) { result = String(result[..<end]) }
        if result.hasSuffix(".git") { result.removeLast(4) }
        return result.removingPercentEncoding ?? result
    }
}

struct GitHubAccount: Codable, Equatable, Sendable {
    let login: String
    let name: String?
}

/// Retrieved from Keychain only when a feature explicitly needs the saved credentials.
struct GitAccountCredential: Codable, Sendable {
    let account: GitHubAccount
    let token: String
}

@MainActor @Observable
final class GitAccountStore {
    private(set) var account: GitHubAccount?
    private(set) var storageError: String?
    private let key: String

    init(key: String = "git-github-account-v1") { self.key = key }

    func credential() throws -> GitAccountCredential? {
        guard let data = try SecureStore.data(for: key) else { return nil }
        return try JSONDecoder().decode(GitAccountCredential.self, from: data)
    }

    func reload() {
        do { account = try credential()?.account; storageError = nil }
        catch { account = nil; storageError = error.localizedDescription }
    }

    func save(accountID: String, token: String) throws {
        let login = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty, login.utf8.count <= 255,
              !login.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw CommandError("Enter an account ID without spaces or line breaks.")
        }
        guard !token.isEmpty, token.utf8.count <= 8192,
              token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
            throw CommandError("Enter a token without spaces or line breaks.")
        }
        let credential = GitAccountCredential(account: GitHubAccount(login: login, name: nil), token: token)
        try SecureStore.set(JSONEncoder().encode(credential), for: key)
        account = credential.account; storageError = nil
    }

    func remove() throws {
        try SecureStore.remove(key)
        account = nil; storageError = nil
    }
}
