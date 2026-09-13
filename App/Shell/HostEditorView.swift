import CrowCore
import SwiftUI
import UniformTypeIdentifiers

struct HostEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host: SSHHost
    @State private var credential = HostCredential()
    @State private var importKey = false
    @State private var choosingKey = false
    @State private var keyFilename: String?
    @State private var loadedCredential = false
    @State private var error: String?
    init(host: SSHHost?) {
        _host = State(initialValue: host ?? SSHHost(name: "", hostname: "", username: "", remotePath: "~"))
    }
    var body: some View {
        NavigationStack {
            Form {
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
                Section {
                    Picker("Method", selection: $host.authentication) {
                        Text("Password").tag(SSHAuthenticationKind.password)
                        Text("SSH Key · Ed25519").tag(SSHAuthenticationKind.ed25519)
                        Text("SSH Key · RSA").tag(SSHAuthenticationKind.rsa)
                    }
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
                        Label("Save & Connect", systemImage: "network")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("crow.host.save-connect")
                    Text("Save keeps this host in Hosts for later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16).background(CrowTheme.bg1)
            }
            .navigationTitle(model.hosts.contains(where: { $0.id == host.id }) ? "Edit SSH Host" : "Add SSH Host")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(connect: false) }
                        .accessibilityIdentifier("crow.host.save")
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
    @State private var showingSnippets = false
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Button { showingKeys = true } label: { Label("SSH Keys", systemImage: "key") }
                Button { showingSnippets = true } label: { Label("Snippets", systemImage: "text.badge.plus") }
                #if os(iOS)
                NavigationLink("Keyboard Bar") { KeyboardBarSettingsView().environment(model) }
                #endif
                Stepper("Editor font: \(Int(model.settings.fontSize)) pt", value: $model.settings.fontSize, in: 10...32)
                Stepper("Terminal font: \(Int(model.settings.terminalFontSize)) pt", value: $model.settings.terminalFontSize, in: 10...32)
                Stepper("Indent: \(model.settings.indentWidth) spaces", value: $model.settings.indentWidth, in: 1...8)
                Toggle("Line numbers", isOn: $model.settings.lineNumbers)
                Toggle("Sidebar", isOn: $model.settings.sidebarVisible)
                Toggle("Terminal", isOn: $model.settings.terminalVisible)
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(isPresented: $showingKeys) { SSHKeysView().environment(model) }
        .sheet(isPresented: $showingSnippets) { SnippetsView().environment(model) }
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 440, minHeight: 340)
        #endif
    }
}
