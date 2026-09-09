import CrowCore
import SwiftUI
import UniformTypeIdentifiers

struct HostEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host: SSHHost
    @State private var credential = HostCredential()
    @State private var importKey = false
    @State private var error: String?
    init(host: SSHHost?) {
        _host = State(initialValue: host ?? SSHHost(name: "", hostname: "", username: "", remotePath: "~"))
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $host.name)
                TextField("Hostname / IP", text: $host.hostname)
                TextField("Port", value: $host.port, format: .number.grouping(.never))
                TextField("Username", text: $host.username)
                TextField("Remote folder", text: $host.remotePath)
                Picker("Authentication", selection: $host.authentication) {
                    Text("Password").tag(SSHAuthenticationKind.password)
                    Text("Ed25519 key").tag(SSHAuthenticationKind.ed25519)
                    Text("RSA key").tag(SSHAuthenticationKind.rsa)
                }
                if host.authentication == .password {
                    SecureField("Password", text: $credential.password)
                } else {
                    Button(credential.privateKey.isEmpty ? "Import OpenSSH Private Key…" : "Replace Private Key…") { importKey = true }
                    if !credential.privateKey.isEmpty { Label("Private key loaded", systemImage: "key.fill") }
                    SecureField("Key passphrase (optional)", text: $credential.passphrase)
                }
                Text("Credentials stay in this device’s Keychain. Server identity is checked on first connection.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(CrowTheme.danger) }
            }
            .formStyle(.grouped)
            .navigationTitle("SSH Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            host.hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
                            host.username = host.username.trimmingCharacters(in: .whitespacesAndNewlines)
                            if host.name.isEmpty { host.name = host.hostname }
                            if host.remotePath.isEmpty { host.remotePath = "~" }
                            try model.storeHost(host, credential: credential); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 460, minHeight: 480)
        #endif
        .onAppear { do { credential = try SecureStore.credential(host) } catch { self.error = error.localizedDescription } }
        .fileImporter(isPresented: $importKey, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                credential.privateKey = try String(contentsOf: url, encoding: .utf8)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CrowSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
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
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 440, minHeight: 340)
        #endif
    }
}
