import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct GitAccountSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @AppStorage(GitHubOAuth.clientIDPreference) private var customClientID = ""
    @State private var setupExpanded = GitHubOAuth.clientID == nil
    @FocusState private var clientIDFocused: Bool
    @State private var token = ""
    @State private var saving = false
    @State private var message: String?
    @State private var error: String?
    @State private var authorization: GitHubOAuth.Authorization?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Group {
            Section("GitHub Account") {
                if let account = model.gitAccounts.account {
                    LabeledContent("Account", value: "@" + account.login)
                    if let name = account.name, !name.isEmpty { LabeledContent("Name", value: name) }
                    Label("Connected on this device", systemImage: "checkmark.shield")
                        .foregroundStyle(CrowTheme.textDim)
                } else {
                    Text("Connect your GitHub account")
                    Text("Sign in through your browser and approve Crow on GitHub.")
                        .foregroundStyle(CrowTheme.textDim)
                }
                Button(model.gitAccounts.account == nil ? "Sign in with GitHub" : "Switch GitHub Account", action: signIn)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
                    .accessibilityIdentifier("crow.git-oauth")
                DisclosureGroup("OAuth App Setup", isExpanded: $setupExpanded) {
                    TextField("Client ID", text: $customClientID,
                              prompt: Text(GitHubOAuth.bundledClientID.isEmpty ? "Paste your OAuth app’s Client ID" : "Leave empty to use the app default"))
                        .crowSettingsInput().autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($clientIDFocused)
                        .accessibilityIdentifier("crow.git-client-id")
                    Text("Register a GitHub OAuth app, enable Device Flow, and paste its Client ID here. This public ID is saved on this device; no client secret is needed.")
                        .font(.caption).foregroundStyle(CrowTheme.textDim)
                    Link("Open GitHub OAuth Apps", destination: URL(string: "https://github.com/settings/developers")!)
                    if !customClientID.isEmpty {
                        Button("Clear Custom Client ID") { customClientID = ""; error = nil }
                    }
                }.disabled(saving)
                    .accessibilityIdentifier("crow.git-oauth-setup")
                if let authorization {
                    Text("Enter this code on GitHub:")
                    HStack {
                        Text(authorization.user_code).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                        Button("Copy Code") { copyCode(authorization.user_code) }
                    }
                    Link("Open GitHub", destination: authorization.verification_uri)
                    Text("Waiting for approval…").foregroundStyle(CrowTheme.textDim)
                }
                if saving {
                    HStack {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { cancel() }
                    }
                }
                if model.gitAccounts.account != nil {
                    Button("Sign Out", role: .destructive) {
                        do {
                            try model.gitAccounts.remove()
                            token = ""; error = nil; message = "Signed out on this device"
                        } catch { self.error = error.localizedDescription }
                    }.disabled(saving)
                }
                if let message { Text(message).foregroundStyle(CrowTheme.accent) }
                if let error = error ?? model.gitAccounts.storageError {
                    Text(error).foregroundStyle(CrowTheme.danger).textSelection(.enabled)
                }
                DisclosureGroup("Use a Personal Access Token") {
                    SecureField("Personal access token", text: $token)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .disabled(saving)
                        .accessibilityIdentifier("crow.git-token")
                        .crowSettingsInput()
                    Button("Verify and Save", action: saveToken)
                        .disabled(saving || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("crow.git-token-save")
                    Link("Create a GitHub Token", destination: URL(string: "https://github.com/settings/personal-access-tokens")!)
                    Text("Choose only the repositories and permissions you need. Verifying your account does not verify access to each repository.")
                        .font(.caption).foregroundStyle(CrowTheme.textDim)
                }
                Text("Credentials stay in this device’s Keychain. Terminal Git commands use the credentials configured on the computer running Git.")
                    .font(.callout).foregroundStyle(CrowTheme.textDim)
            }
        }
        .onAppear { model.gitAccounts.reload() }
        .onDisappear { cancel(); token = "" }
    }

    private func signIn() {
        guard let clientID = GitHubOAuth.configuredClientID(override: customClientID, bundled: GitHubOAuth.bundledClientID) else {
            setupExpanded = true; clientIDFocused = true
            error = "Enter your OAuth app’s Client ID below to start GitHub sign-in."
            return
        }
        clientIDFocused = false
        saving = true; message = nil; error = nil
        saveTask = Task { @MainActor in
            defer { if !Task.isCancelled { saving = false; authorization = nil } }
            do {
                let oauth = GitHubOAuth()
                let code = try await oauth.begin(clientID: clientID)
                try Task.checkCancellation()
                authorization = code
                openURL(code.verification_uri)
                let credential = try await oauth.token(clientID: clientID, authorization: code)
                try await model.gitAccounts.save(token: credential)
                token = ""; message = "Connected · @" + (model.gitAccounts.account?.login ?? "")
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
    private func saveToken() {
        saving = true; message = nil; error = nil
        let submitted = token
        saveTask = Task { @MainActor in
            defer { if !Task.isCancelled { saving = false } }
            do {
                try await model.gitAccounts.save(token: submitted)
                token = ""; message = "Connected · @" + (model.gitAccounts.account?.login ?? "")
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
    private func cancel() {
        saveTask?.cancel(); saveTask = nil; saving = false; authorization = nil
    }
    private func copyCode(_ code: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
        #else
        UIPasteboard.general.string = code
        #endif
    }
}

struct GitSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form { GitAccountSettings() }.formStyle(.grouped)
                .navigationTitle("Git Accounts")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 480, minHeight: 420)
        #endif
    }
}
