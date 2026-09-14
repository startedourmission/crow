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

private struct SavedGitHubAccount: Codable {
    let account: GitHubAccount
    let token: String
}

/// Tokens only go to GitHub's fixed API endpoint, never a repository-provided URL.
final class GitAccountAPI: NSObject, URLSessionTaskDelegate, Sendable {
    static func request(token: String) throws -> URLRequest {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 8192,
              token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
            throw CommandError("Enter a valid GitHub personal access token.")
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.timeoutInterval = 20
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Crow", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func account(data: Data, status: Int) throws -> GitHubAccount {
        guard status == 200 else {
            switch status {
            case 401: throw CommandError("GitHub rejected this token. It may be invalid or expired.")
            case 403, 429: throw CommandError("GitHub denied this request. Check token access or try again after the rate limit resets.")
            default: throw CommandError("Could not verify the GitHub account (HTTP \(status)). Try again.")
            }
        }
        guard data.count < 1_048_576,
              let account = try? JSONDecoder().decode(GitHubAccount.self, from: data),
              !account.login.isEmpty else { throw CommandError("GitHub returned an invalid account response.") }
        return account
    }

    func verify(token: String) async throws -> GitHubAccount {
        let request = try Self.request(token: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw CommandError("No response from GitHub.") }
        return try Self.account(data: data, status: response.statusCode)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor @Observable
final class GitAccountStore {
    private(set) var account: GitHubAccount?
    private(set) var storageError: String?
    private let key: String

    init(key: String = "git-github-account-v1") { self.key = key }

    func reload() {
        do {
            if let data = try SecureStore.data(for: key) {
                account = try JSONDecoder().decode(SavedGitHubAccount.self, from: data).account
            } else { account = nil }
            storageError = nil
        } catch { account = nil; storageError = error.localizedDescription }
    }

    func save(token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let verified = try await GitAccountAPI().verify(token: token)
        try Task.checkCancellation()
        try store(verified, token: token)
    }

    func store(_ verified: GitHubAccount, token: String) throws {
        try SecureStore.set(JSONEncoder().encode(SavedGitHubAccount(account: verified, token: token)), for: key)
        account = verified; storageError = nil
    }

    func remove() throws {
        try SecureStore.remove(key)
        account = nil; storageError = nil
    }
}
