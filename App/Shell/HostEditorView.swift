import CrowCore
import SwiftUI
import UniformTypeIdentifiers

struct HostEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let authenticationOnly: Bool
    @State private var host: SSHHost
    @State private var credential = HostCredential()
    @State private var importKey = false
    @State private var choosingKey = false
    @State private var keyFilename: String?
    @State private var loadedCredential = false
    @State private var error: String?
    init(host: SSHHost?, authenticationOnly: Bool = false) {
        self.authenticationOnly = authenticationOnly
        _host = State(initialValue: host ?? SSHHost(name: "", hostname: "", username: "", remotePath: "~"))
    }
    var body: some View {
        NavigationStack {
            Form {
                if authenticationOnly {
                    Section { Text(host.userAtHost).font(.system(.body, design: .monospaced)) }
                } else {
                    Section("Server") {
                        hostField("Hostname / IP", text: $host.hostname, prompt: "192.168.1.10")
                            .accessibilityIdentifier("crow.host.hostname")
                        hostField("Username", text: $host.username, prompt: "ubuntu")
                            .accessibilityIdentifier("crow.host.username")
                        LabeledContent("Port") {
                            TextField("Port", value: $host.port, format: .number.grouping(.never))
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                        }
                    }
                }
                Section {
                    Picker("Method", selection: $host.authentication) {
                        Text("Password").tag(SSHAuthenticationKind.password)
                        Text("SSH Key · Ed25519").tag(SSHAuthenticationKind.ed25519)
                        Text("SSH Key · RSA").tag(SSHAuthenticationKind.rsa)
                    }.accessibilityIdentifier("crow.host.authentication")
                    if host.authentication == .password {
                        SecureField("Password", text: $credential.password)
                    } else {
                        Button { choosingKey = true } label: {
                            Label(credential.keyID == nil ? "Choose or Create SSH Key…" : (keyFilename ?? "Saved SSH Key"), systemImage: "key")
                        }
                        .accessibilityIdentifier("crow.host.choose-key")
                        if credential.keyID == nil {
                            Button { importKey = true } label: {
                                Label(credential.privateKey.isEmpty ? "Import Private Key from Files…" : "Replace Private Key…", systemImage: "square.and.arrow.down")
                            }
                            .accessibilityIdentifier("crow.host.import-key")
                            if !credential.privateKey.isEmpty {
                                Label(keyFilename ?? "Saved private key", systemImage: "key.fill")
                                    .foregroundStyle(CrowTheme.ok)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            SecureField("Key passphrase (if set)", text: $credential.passphrase)
                        } else {
                            Button("Use a Different Private Key File…") { importKey = true }
                        }
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text(host.authentication == .password
                        ? "Credentials are saved in this device’s Keychain."
                        : "Choose a saved key, create one, or import a private key file. Private keys stay in this device’s Keychain.")
                    #if os(macOS)
                    if credential.keyID != nil && host.commandArguments != nil {
                        Text("This key connects directly to the hostname and port above. Saved SSH command options will be replaced.")
                    }
                    #endif
                }
                if !authenticationOnly {
                    Section("Optional") {
                        hostField("Display name", text: $host.name, prompt: "My server")
                        hostField("Remote folder", text: $host.remotePath, prompt: "~")
                    }
                    #if os(iOS)
                    Section {
                        Toggle("WSL default shell", isOn: $host.usesWSL)
                            .accessibilityIdentifier("crow.host.wsl")
                    } footer: {
                        Text("Enable for a Windows SSH server configured to open WSL as its default shell. Terminals start in the selected remote project folder. When off, they start in Remote folder (~ means home). Reconnect after changing this setting.")
                    }
                    #endif
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(CrowTheme.danger)
                            .accessibilityIdentifier("crow.host.error")
                    }
                }
            }
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button { save(connect: true) } label: {
                        Label(authenticationOnly ? "Connect" : "Save & Connect", systemImage: "network")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("crow.host.save-connect")
                    if !authenticationOnly {
                        Text("Save keeps this host in Workspaces for later.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16).background(CrowTheme.bg1)
            }
            .navigationTitle(authenticationOnly ? "SSH Authentication" : model.hosts.contains(where: { $0.id == host.id }) ? "Edit SSH Host" : "Add SSH Host")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if !authenticationOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save(connect: false) }
                            .accessibilityIdentifier("crow.host.save")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 480, minHeight: 620)
        #endif
        .onAppear {
            guard !loadedCredential else { return }
            loadedCredential = true
            do {
                credential = try SecureStore.credential(host)
                if let id = credential.keyID { keyFilename = try SSHKeyStore.shared.identity(id).name }
            } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $choosingKey, onDismiss: {
            if let id = credential.keyID {
                do { keyFilename = try SSHKeyStore.shared.identity(id).name }
                catch { self.error = error.localizedDescription }
            }
        }) {
            SSHKeysView { key in
                host.authentication = key.authentication
                credential = HostCredential(keyID: key.id)
                keyFilename = key.name; error = nil
            }.environment(model)
        }
        .onChange(of: host.authentication) { _, next in
            if let id = credential.keyID, (try? SSHKeyStore.shared.identity(id).authentication) != next {
                credential.keyID = nil; keyFilename = nil
            }
        }
        .fileImporter(isPresented: $importKey, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let key = try String(contentsOf: url, encoding: .utf8)
                guard key.contains("-----BEGIN OPENSSH PRIVATE KEY-----") else {
                    throw CommandError("Choose an OpenSSH private key such as id_ed25519 or id_rsa, not the .pub public key.")
                }
                credential.privateKey = key
                credential.keyID = nil
                keyFilename = url.lastPathComponent
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save(connect: Bool) {
        do {
            try model.saveHostFromEditor(host, credential: credential, connectAfterSaving: connect)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func hostField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt)).multilineTextAlignment(.trailing)
        }
    }
}

struct CrowSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingKeys = false
    var body: some View {
        NavigationStack {
            #if os(macOS)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) { settingsContent }
                    .padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(CrowTheme.bg0)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            #else
            Form { settingsContent; KeyboardBarSettingsContent() }
                .formStyle(.grouped)
                .navigationTitle("Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            #endif
        }
        .sheet(isPresented: $showingKeys) { SSHKeysView().environment(model) }
        #if os(macOS)
        .frame(minWidth: 700, idealWidth: 880, minHeight: 600, idealHeight: 740)
        #endif
    }

    @ViewBuilder private var settingsContent: some View {
        @Bindable var model = model
        CrowSettingsSection("Editor") {
            Stepper("Font: \(Int(model.settings.fontSize)) pt", value: $model.settings.fontSize, in: 10...32)
            Stepper("Indent: \(model.settings.indentWidth) spaces", value: $model.settings.indentWidth, in: 1...8)
            Toggle("Line numbers", isOn: $model.settings.lineNumbers)
            Picker("Default Markdown view", selection: $model.markdownPreviewEnabled) {
                Text("Rendered").tag(true)
                Text("Source").tag(false)
            }.accessibilityIdentifier("crow.settings.markdown-view")
        }
        CrowSettingsSection("Terminal & Layout") {
            Stepper("Terminal font: \(Int(model.settings.terminalFontSize)) pt", value: $model.settings.terminalFontSize, in: 10...32)
            Toggle("Sidebar", isOn: $model.settings.sidebarVisible)
            Toggle("Terminal", isOn: $model.settings.terminalVisible)
        }
        CrowSettingsSection("Files") {
            Toggle("Show hidden files", isOn: $model.showHiddenFiles)
            Picker("Delete moves files to", selection: Binding(get: { model.settings.effectiveFileDeletionDestination }, set: { model.settings.fileDeletionDestination = $0 })) {
                Text("Recovery Folder").tag(FileDeletionDestination.recovery)
                Text("Trash").tag(FileDeletionDestination.trash)
            }.accessibilityIdentifier("crow.settings.delete-destination")
            Text("Recovery Folder keeps deleted items in .crow/recovery inside the workspace. Trash uses the file’s computer or storage provider. If trash is unavailable, the file stays in place.")
                .font(.caption).foregroundStyle(CrowTheme.textDim)
        }
        CrowSettingsSection("SSH") {
            Button { showingKeys = true } label: { Label("Manage SSH Keys…", systemImage: "key") }
        }
        #if os(macOS)
        ReverseSSHPasswordSettings()
        #endif
        GitAccountSettings()
    }
}

struct CrowSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

extension View {
    func crowSettingsInput() -> some View {
        self.textFieldStyle(.plain)
            .padding(9)
            .background(CrowTheme.bg0, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(CrowTheme.textDim.opacity(0.35), lineWidth: 1) }
    }
}

#if os(macOS)
private struct ReverseSSHPasswordSettings: View {
    private let access = ReverseSSHAccessSettings.shared
    @State private var password = ""
    @State private var confirmation = ""
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        CrowSettingsSection("Reverse SSH") {
            Text(access.hasPassword ? "Access password is set" : "Set a password before enabling Reverse SSH")
                .font(.callout)
            SecureField("New access password", text: $password)
                .accessibilityIdentifier("crow.reverse-ssh.password")
                .crowSettingsInput()
            SecureField("Confirm password", text: $confirmation)
                .accessibilityIdentifier("crow.reverse-ssh.password-confirmation")
                .crowSettingsInput()
            Button(access.hasPassword ? "Change Password" : "Set Password") {
                do {
                    guard password == confirmation else { throw CommandError("The passwords do not match.") }
                    try access.save(password)
                    password = ""; confirmation = ""; failed = false
                    message = "Saved. Turn Reverse SSH on for the hosts you want to access."
                } catch { failed = true; message = error.localizedDescription }
            }.disabled(password.isEmpty || confirmation.isEmpty)
                .accessibilityIdentifier("crow.reverse-ssh.password-save")
            if let message { Text(message).font(.caption).foregroundStyle(failed ? Color.red : CrowTheme.textDim) }
            Text("Enter this password when connecting from a server. It is stored in this Mac’s Keychain. Changing it disconnects all current reverse SSH sessions.")
                .font(.caption).foregroundStyle(CrowTheme.textDim)
        }.onAppear {
            do { _ = try access.password() }
            catch { failed = true; message = error.localizedDescription }
        }
    }
}
#endif
