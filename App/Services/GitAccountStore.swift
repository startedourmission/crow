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

/// Public-client OAuth: no client secret or callback server is embedded in Crow.
struct GitHubOAuth: Sendable {
    struct Authorization: Decodable, Sendable {
        let device_code: String
        let user_code: String
        let verification_uri: URL
        let expires_in: Int
        let interval: Int
    }
    enum PollResult: Equatable { case pending, slowDown, token(String) }
    private struct Response: Decodable {
        let access_token: String?
        let token_type: String?
        let error: String?
    }

    static let clientIDPreference = "crow.githubOAuthClientID"
    static var bundledClientID: String { Bundle.main.object(forInfoDictionaryKey: "CrowGitHubClientID") as? String ?? "" }
    static var clientID: String? {
        configuredClientID(override: UserDefaults.standard.string(forKey: clientIDPreference) ?? "", bundled: bundledClientID)
    }
    static func configuredClientID(override: String, bundled: String) -> String? {
        let custom = override.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = custom.isEmpty ? bundled.trimmingCharacters(in: .whitespacesAndNewlines) : custom
        return validClientID(value) ? value : nil
    }
    private static func validClientID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 46
        }
    }
    static func request(clientID: String, deviceCode: String? = nil) throws -> URLRequest {
        guard validClientID(clientID) else { throw CommandError("Enter a valid GitHub OAuth Client ID in Settings → GitHub Account → OAuth App Setup.") }
        var fields = ["client_id": clientID]
        let path: String
        if let deviceCode {
            path = "/login/oauth/access_token"
            fields["device_code"] = deviceCode
            fields["grant_type"] = "urn:ietf:params:oauth:grant-type:device_code"
        } else {
            path = "/login/device/code"
            fields["scope"] = "read:user"
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var request = URLRequest(url: URL(string: "https://github.com" + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Crow", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            $0.key + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        return request
    }
    static func authorization(_ data: Data) throws -> Authorization {
        if let response = try? JSONDecoder().decode(Response.self, from: data) {
            switch response.error {
            case "incorrect_client_credentials": throw CommandError("GitHub did not recognize this Client ID. Check OAuth App Setup and try again.")
            case "device_flow_disabled": throw CommandError("Enable Device Flow in this OAuth app’s GitHub settings, then try again.")
            default: break
            }
        }
        guard let value = try? JSONDecoder().decode(Authorization.self, from: data),
              !value.device_code.isEmpty, value.device_code.count <= 1024,
              !value.user_code.isEmpty, value.user_code.count <= 32,
              value.verification_uri.absoluteString == "https://github.com/login/device",
              (1...3600).contains(value.expires_in), (1...300).contains(value.interval) else {
            throw CommandError("Could not start GitHub sign-in. Check the OAuth app’s Device Flow setting and try again.")
        }
        return value
    }
    static func pollResult(_ data: Data) throws -> PollResult {
        guard let value = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CommandError("GitHub returned an invalid sign-in response.")
        }
        switch value.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": throw CommandError("GitHub sign-in was declined. You can try again.")
        case "expired_token": throw CommandError("The GitHub sign-in code expired. Start sign-in again.")
        case .some: throw CommandError("GitHub could not complete sign-in. Check the OAuth app configuration and try again.")
        case nil:
            guard let token = value.access_token, value.token_type?.lowercased() == "bearer" else {
                throw CommandError("GitHub returned an invalid sign-in response.")
            }
            _ = try GitAccountAPI.request(token: token)
            return .token(token)
        }
    }
    static func checkedResponse(_ data: Data, status: Int) throws -> Data {
        guard data.count < 1_048_576 else { throw CommandError("GitHub returned an oversized sign-in response.") }
        if status == 200 { return data }
        let code = (try? JSONDecoder().decode(Response.self, from: data))?.error
        switch code {
        case "incorrect_client_credentials", "invalid_client", "Not Found":
            throw CommandError("GitHub could not find this OAuth app (HTTP \(status)). Copy the Client ID from GitHub → Settings → Developer settings → OAuth Apps.")
        case "device_flow_disabled":
            throw CommandError("Enable Device Flow in this OAuth app’s GitHub settings, then try again.")
        default: break
        }
        switch status {
        case 404:
            throw CommandError("GitHub could not find this OAuth app (HTTP 404). Check the Client ID in OAuth App Setup.")
        case 401:
            throw CommandError("GitHub rejected the OAuth app credentials (HTTP 401). Check the Client ID in OAuth App Setup.")
        case 403, 429:
            throw CommandError("GitHub blocked or rate-limited sign-in (HTTP \(status)). Wait before trying again and check your network access.")
        case 500...599:
            throw CommandError("GitHub sign-in is temporarily unavailable (HTTP \(status)). Try again later.")
        default:
            throw CommandError("GitHub could not start sign-in (HTTP \(status)). Check the OAuth app’s Client ID and Device Flow setting.")
        }
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: GitAccountAPI(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw CommandError("No HTTP response from GitHub.") }
        return try Self.checkedResponse(data, status: response.statusCode)
    }
    func begin(clientID: String) async throws -> Authorization {
        try Self.authorization(await fetch(Self.request(clientID: clientID)))
    }
    func token(clientID: String, authorization: Authorization) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(authorization.expires_in))
        var interval = authorization.interval
        while clock.now < deadline {
            try await Task.sleep(for: .seconds(interval))
            guard clock.now < deadline else { break }
            let result = try Self.pollResult(await fetch(Self.request(clientID: clientID, deviceCode: authorization.device_code)))
            switch result {
            case .pending: break
            case .slowDown: interval += 5
            case .token(let token): return token
            }
        }
        throw CommandError("The GitHub sign-in code expired. Start sign-in again.")
    }
}
