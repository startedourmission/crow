import SwiftUI

struct GitAccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var accountID = ""
    @State private var token = ""
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        CrowSettingsSection("GitHub Credentials") {
            Text("Save an account ID and token for future use.")
                .foregroundStyle(CrowTheme.textDim)
            CrowSettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Account ID").font(.caption).foregroundStyle(CrowTheme.textDim)
                        TextField("GitHub username", text: $accountID)
                            .labelsHidden().crowSettingsInput()
                            .accessibilityIdentifier("crow.git-account-id")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Token").font(.caption).foregroundStyle(CrowTheme.textDim)
                        SecureField(model.gitAccounts.account == nil ? "Personal access token" : "New token", text: $token)
                            .labelsHidden().crowSettingsInput()
                            .accessibilityIdentifier("crow.git-token")
                    }
                    HStack {
                        if model.gitAccounts.account != nil {
                            Button("Delete Saved Credentials", role: .destructive) {
                                do {
                                    try model.gitAccounts.remove()
                                    accountID = ""; token = ""; error = nil; message = "Saved credentials deleted."
                                } catch { self.error = error.localizedDescription }
                            }
                        } else {
                            Button("Load Saved Account") {
                                do {
                                    let saved = try model.gitAccounts.credential()
                                    accountID = saved?.account.login ?? ""
                                    token = ""
                                    error = nil
                                    message = saved == nil ? "No saved GitHub account." : "Saved account loaded. The token stays in the Keychain."
                                } catch { self.error = error.localizedDescription }
                            }
                            .accessibilityIdentifier("crow.git-account-load")
                        }
                        Spacer()
                        Button("Save") {
                            do {
                                try model.gitAccounts.save(accountID: accountID, token: token)
                                accountID = model.gitAccounts.account?.login ?? accountID
                                error = nil; message = "Saved on this device."
                            } catch { self.error = error.localizedDescription }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("crow.git-token-save")
                    }
                }.padding(.vertical, 8)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            Text("Stored in this device’s Keychain. Opening Settings does not read it. The token is read only when you load, replace, or delete the account, or when a feature uses it.")
                .font(.caption).foregroundStyle(CrowTheme.textDim)
            if let message { Text(message).font(.caption).foregroundStyle(CrowTheme.accent) }
            if let error { Text(error).font(.caption).foregroundStyle(CrowTheme.danger).textSelection(.enabled) }
        }
        .onAppear {
            model.gitAccounts.reload()
            accountID = model.gitAccounts.account?.login ?? ""
            token = ""
        }
        .onDisappear { token = "" }
    }
}

struct GitSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                GitAccountSettings().padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
                .background(CrowTheme.bg0)
                .navigationTitle("Git Accounts")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 480, minHeight: 420)
        #endif
    }
}
