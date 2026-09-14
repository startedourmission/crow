import SwiftUI

struct GitSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var saving = false
    @State private var message: String?
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("GitHub Account") {
                    if let account = model.gitAccounts.account {
                        LabeledContent("Account", value: "@" + account.login)
                        if let name = account.name, !name.isEmpty { LabeledContent("Name", value: name) }
                        Label("Token saved on this device", systemImage: "checkmark.shield")
                            .foregroundStyle(CrowTheme.textDim)
                    } else { Text("No GitHub account saved") }
                    SecureField(model.gitAccounts.account == nil ? "Personal access token" : "Replacement token", text: $token)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .disabled(saving)
                        .accessibilityIdentifier("crow.git-token")
                    Button {
                        saving = true; message = nil; error = nil
                        let submitted = token
                        saveTask = Task { @MainActor in
                            defer { saving = false }
                            do {
                                try await model.gitAccounts.save(token: submitted)
                                token = ""; message = "Saved · @" + (model.gitAccounts.account?.login ?? "")
                            } catch {
                                guard !Task.isCancelled else { return }
                                self.error = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack {
                            Text("Verify and Save")
                            if saving { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(saving || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("crow.git-token-save")
                    if model.gitAccounts.account != nil {
                        Button("Remove Token", role: .destructive) {
                            do {
                                try model.gitAccounts.remove()
                                token = ""; error = nil; message = "Token removed"
                            } catch { self.error = error.localizedDescription }
                        }.disabled(saving)
                    }
                    if let message { Text(message).foregroundStyle(CrowTheme.accent) }
                    if let error = error ?? model.gitAccounts.storageError {
                        Text(error).foregroundStyle(CrowTheme.danger).textSelection(.enabled)
                    }
                }
                Section {
                    Link("Create a GitHub Token", destination: URL(string: "https://github.com/settings/personal-access-tokens")!)
                    Text("Choose only the repositories and permissions you need. Verifying your account does not verify access to each repository.")
                    Text("Tokens stay in this device’s Keychain. This account is used by Crow; terminal Git commands continue to use the credentials configured on the computer running Git.")
                }.font(.callout)
            }
            .formStyle(.grouped)
            .navigationTitle("Git Accounts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { model.gitAccounts.reload() }
        .onDisappear { saveTask?.cancel(); token = "" }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 480, minHeight: 420)
        #endif
    }
}
