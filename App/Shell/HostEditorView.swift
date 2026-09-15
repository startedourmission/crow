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
            CrowSettingsCard {
                CrowSettingsRow("Font") {
                    Stepper("\(Int(model.settings.fontSize)) pt", value: $model.settings.fontSize, in: 10...32).fixedSize()
                }
                Divider()
                CrowSettingsRow("Indent") {
                    Stepper("\(model.settings.indentWidth) spaces", value: $model.settings.indentWidth, in: 1...8).fixedSize()
                }
                Divider()
                CrowSettingsRow("Line numbers") {
                    Toggle("Line numbers", isOn: $model.settings.lineNumbers).labelsHidden()
                }
                Divider()
                CrowSettingsRow("Default Markdown view") {
                    Picker("Default Markdown view", selection: $model.markdownPreviewEnabled) {
                        Text("Rendered").tag(true)
                        Text("Source").tag(false)
                    }.labelsHidden().fixedSize().accessibilityIdentifier("crow.settings.markdown-view")
                }
            }
        }
        CrowSettingsSection("Terminal & Layout") {
            CrowSettingsCard {
                CrowSettingsRow("Terminal font") {
                    Stepper("\(Int(model.settings.terminalFontSize)) pt", value: $model.settings.terminalFontSize, in: 10...32).fixedSize()
                }
                Divider()
                CrowSettingsRow("Sidebar") { Toggle("Sidebar", isOn: $model.settings.sidebarVisible).labelsHidden() }
                Divider()
                CrowSettingsRow("Terminal") { Toggle("Terminal", isOn: $model.settings.terminalVisible).labelsHidden() }
            }
        }
        CrowSettingsSection("Files") {
            CrowSettingsCard {
                CrowSettingsRow("Show hidden files") { Toggle("Show hidden files", isOn: $model.showHiddenFiles).labelsHidden() }
                Divider()
                CrowSettingsRow("Delete moves files to") {
                    Picker("Delete moves files to", selection: Binding(get: { model.settings.effectiveFileDeletionDestination }, set: { model.settings.fileDeletionDestination = $0 })) {
                        Text("Recovery Folder").tag(FileDeletionDestination.recovery)
                        Text("Trash").tag(FileDeletionDestination.trash)
                    }.labelsHidden().fixedSize().accessibilityIdentifier("crow.settings.delete-destination")
                }
            }
            Text("Recovery Folder keeps deleted items in .crow/recovery inside the workspace. Trash uses the file’s computer or storage provider. If trash is unavailable, the file stays in place.")
                .font(.caption).foregroundStyle(CrowTheme.textDim)
        }
        CrowSettingsSection("SSH") {
            CrowSettingsCard {
                CrowSettingsRow("SSH keys") {
                    Button { showingKeys = true } label: { Label("Manage Keys…", systemImage: "key") }
                }
            }
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

struct CrowSettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(CrowTheme.bg1, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CrowSettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        HStack(spacing: 16) {
            Text(title)
            Spacer(minLength: 12)
            content()
        }
        .frame(minHeight: 32).padding(.vertical, 6)
        .toggleStyle(.switch).controlSize(.small)
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
    @Environment(AppModel.self) private var model
    @State private var server = ManagedServerSettings.shared
    @State private var hostID: HostID?
    @State private var code = ""
    @State private var result: String?
    @State private var publicKeyFingerprint = ""
    @State private var serverFingerprintConfirmed = false

    var body: some View {
        CrowSettingsSection("Crow Server") {
            Text("Install on the server Mac, register an agent executable, then pair from your client Mac. Each reverse agent runs with its own isolated account.")
                .font(.caption).foregroundStyle(CrowTheme.textDim)
            CrowSettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Client Mac’s public key", text: $server.clientPublicKey).crowSettingsInput()
                        .onChange(of: server.clientPublicKey) { _, _ in server.clientFingerprintConfirmed = false }
                    if let key = server.clientKeyData {
                        Text("Client fingerprint: " + ManagedPairingEnvelope.fingerprint(key)).font(.caption.monospaced())
                        Toggle("Matches the public-key fingerprint shown on the client Mac", isOn: $server.clientFingerprintConfirmed)
                            .font(.caption)
                    }
                }.padding(.vertical, 8)
                Divider()
                CrowSettingsRow("Server on this Mac") {
                    if server.busy { ProgressView().controlSize(.small) }
                    Button(server.installed ? "Update Server…" : "Install Server…") { server.administer("install") }
                }
                if server.installed {
                    Divider()
                    CrowSettingsRow("Service") {
                        Button("Start") { server.administer("start") }
                        Button("Stop") { server.administer("stop") }
                    }
                    Divider()
                    ForEach(AgentProvider.allCases) { provider in
                        CrowSettingsRow(provider.title + " executable") {
                            Button("Choose…") { chooseExecutable(provider) }
                        }
                    }
                    Divider()
                    CrowSettingsRow("Pairing code") {
                        Button("Show…") { server.administer("pair") }
                        Button("Reset…") { server.administer("reset") }
                    }
                    if !server.pairingCode.isEmpty {
                        if let fingerprint = server.pairingFingerprint {
                            Text("Server fingerprint: " + fingerprint).font(.caption.monospaced()).padding(.top, 8)
                        }
                        HStack(spacing: 10) {
                            SecureField("Pairing code", text: .constant(server.pairingCode)).crowSettingsInput()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(server.pairingCode, forType: .string)
                            }
                            Button("Hide") { server.pairingCode = "" }
                        }.padding(.vertical, 8)
                    }
                }
            }.disabled(server.busy)
            if let message = server.message { Text(message).font(.caption).foregroundStyle(CrowTheme.textDim) }
            Text("Paste the public key copied from the client Mac below and compare fingerprints before installing. Only the intended client can decrypt the server’s registration code. Resetting pairing disconnects agents and invalidates the old code.")
                .font(.caption).foregroundStyle(CrowTheme.textDim)
        }
        CrowSettingsSection("Paired Server") {
            Text("First copy this Mac’s public key to the server’s Crow settings. After server setup, paste its encrypted code here and compare the server fingerprint on both Macs.")
                .font(.caption).foregroundStyle(CrowTheme.textDim)
            CrowSettingsCard {
                CrowSettingsRow("This Mac’s public key") {
                    Button("Copy Public Key") {
                        do {
                            let key = try AppModel.managedClientKey(create: true).publicKey.rawRepresentation
                            publicKeyFingerprint = ManagedPairingEnvelope.fingerprint(key)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(key.base64EncodedString(), forType: .string)
                        } catch { result = error.localizedDescription }
                    }
                }
                if !publicKeyFingerprint.isEmpty {
                    Text("Client fingerprint: " + publicKeyFingerprint).font(.caption.monospaced()).padding(.bottom, 8)
                }
                Divider()
                CrowSettingsRow("SSH host") {
                    Picker("SSH host", selection: $hostID) {
                        Text("Choose a host").tag(nil as HostID?)
                        ForEach(model.hosts) { host in Text(host.userAtHost).tag(Optional(host.id)) }
                    }.labelsHidden().frame(maxWidth: 300)
                }
                Divider()
                HStack(spacing: 12) {
                    SecureField("Encrypted server pairing code", text: $code).crowSettingsInput()
                        .onChange(of: code) { _, _ in serverFingerprintConfirmed = false }
                    Button("Pair") {
                        guard let hostID else { return }
                        do { try model.pairManagedServer(code, hostID: hostID); code = ""; result = "Paired. You can now open a reverse agent." }
                        catch { result = error.localizedDescription }
                    }.disabled(hostID == nil || code.isEmpty || !serverFingerprintConfirmed)
                    Button("Forget") {
                        guard let hostID else { return }
                        do {
                            AppModel.revokeManagedAgents(hostID: hostID)
                            try SecureStore.remove(AppModel.managedPairingAccount(hostID))
                            result = "Pairing removed from this Mac."
                        } catch { result = error.localizedDescription }
                    }.disabled(hostID == nil)
                }.padding(.vertical, 8)
                if let envelope = try? ManagedPairingEnvelope.decode(code) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server fingerprint: " + envelope.fingerprint).font(.caption.monospaced())
                        Toggle("Matches the fingerprint shown by Crow on the server Mac", isOn: $serverFingerprintConfirmed)
                            .font(.caption)
                    }.padding(.bottom, 8)
                }
            }
            if let result { Text(result).font(.caption).foregroundStyle(CrowTheme.textDim) }
        }
    }
    private func chooseExecutable(_ provider: AgentProvider) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.message = "Choose the standalone native " + provider.title + " executable."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        server.administer("agent", provider: provider, source: url.path)
    }
}

struct ManagedAgentSheet: View {
    let workspaceID: WorkspaceID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AgentProvider = .codex
    @State private var folder = ""
    @State private var commands = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Open Reverse Agent").font(.title2)
            Text("This agent can access the local folder you choose through crow-reverse. Other SSH logins cannot use its reverse connection.")
                .foregroundStyle(CrowTheme.textDim)
            CrowSettingsCard {
                CrowSettingsRow("Agent") {
                    Picker("Agent", selection: $provider) {
                        ForEach(AgentProvider.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }
                Divider()
                CrowSettingsRow("Local folder") {
                    Text(folder.isEmpty ? "Choose a folder" : (folder as NSString).lastPathComponent).lineLimit(1)
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                        if panel.runModal() == .OK { folder = panel.url?.path ?? "" }
                    }
                }
                Divider()
                CrowSettingsRow("Allow local commands") { Toggle("Allow local commands", isOn: $commands).labelsHidden() }
            }
            Text(commands
                 ? "Commands run as your local account and can access files outside the chosen folder. Enable only for an agent and server project you trust."
                 : "File access is limited to the chosen folder. Symbolic links are not followed. Local command execution is off.")
                .font(.caption).foregroundStyle(CrowTheme.textDim)
            Text("The server must be a paired Mac with this agent installed in Crow Server settings. The agent uses a separate home; its CLI may ask you to sign in.")
                .font(.caption).foregroundStyle(CrowTheme.textDim)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open Agent") {
                    do { try model.openManagedAgent(provider, workspaceID: workspaceID, localRoot: folder, commands: commands); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(folder.isEmpty)
            }
        }.padding(24).frame(width: 560).background(CrowTheme.bg0)
    }
}
#endif
