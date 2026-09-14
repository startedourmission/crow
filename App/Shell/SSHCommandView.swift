import SwiftUI
import CrowCore

struct SSHCommandView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var command = "ssh "
    @State private var error: String?
    @State private var connecting = false
    @State private var authentication = "auto"
    @State private var password = ""
    @State private var identities: [SSHIdentity] = []
    @State private var selectedKey: UUID?
    @State private var choosingKey = false
    @State private var identityPath = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("ssh user@host -p 2222", text: $command)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(connect)
                Picker("Authentication", selection: $authentication) {
                    Text("Automatic · SSH config / saved credentials").tag("auto")
                    Text("Password").tag("password")
                    Text("Saved SSH Key").tag("key")
                    #if os(macOS)
                    Text("Private Key File").tag("file")
                    #endif
                }.pickerStyle(.menu).accessibilityIdentifier("crow.ssh.authentication")
                if authentication == "key" {
                    HStack {
                        Picker("SSH Key", selection: $selectedKey) {
                            Text("Select a key").tag(nil as UUID?)
                            ForEach(identities) { key in Text(key.name).tag(Optional(key.id)) }
                        }.pickerStyle(.menu)
                        Button("Manage Keys…") { choosingKey = true }
                    }
                }
                #if os(macOS)
                if authentication == "file" {
                    TextField("Private key path · ~/.ssh/id_ed25519", text: $identityPath).textFieldStyle(.roundedBorder)
                    Button("Choose Key File…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                        panel.begin { response in if response == .OK, let url = panel.url { identityPath = url.path } }
                    }
                }
                #else
                if authentication == "password" { SecureField("Password", text: $password).textFieldStyle(.roundedBorder) }
                #endif
                #if os(macOS)
                Text("Uses your OpenSSH config, keys and agent. Password and server verification prompts appear in the terminal.")
                    .font(.caption).foregroundStyle(.secondary)
                #else
                Text("Saved hosts reuse their credentials. For a new connection, choose a password or SSH key on the next screen.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                if let error { Text(error).foregroundStyle(CrowTheme.danger).font(.caption) }
            }
            .padding(20)
            .navigationTitle("SSH")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Connect", action: connect).disabled(connecting) }
            }
        }
        #if os(macOS)
        .frame(width: 580, height: 330)
        #endif
        .onAppear { focused = true; loadKeys() }
        .sheet(isPresented: $choosingKey, onDismiss: loadKeys) {
            SSHKeysView(onSelect: { key in selectedKey = key.id; choosingKey = false }).environment(model)
        }
    }
    private func loadKeys() { do { identities = try SSHKeyStore.shared.identities() } catch { self.error = error.localizedDescription } }
    private func connect() {
        guard !connecting else { return }; connecting = true
        Task {
            do {
                if authentication == "key" {
                    guard let selectedKey else { throw CommandError("Choose an SSH key.") }
                    let key = try SSHKeyStore.shared.identity(selectedKey)
                    let (parsed, _) = try SSHCommand(command).portableHost(defaultUsername: "")
                    var host = model.hosts.first { $0.hostname == parsed.hostname && $0.port == parsed.port && $0.username == parsed.username } ?? parsed
                    host.authentication = key.authentication; host.commandArguments = nil; host.commandDirectory = nil
                    var credential = HostCredential(); credential.keyID = key.id
                    try model.storeHost(host, credential: credential); model.connect(host)
                } else {
                    #if os(macOS)
                    let line = try Self.connectionCommand(command, authentication: authentication, identityPath: identityPath)
                    try await model.connectCommand(line)
                    #else
                    if authentication == "password" {
                        guard !password.isEmpty else { throw CommandError("Enter the SSH password.") }
                        let (parsed, _) = try SSHCommand(command).portableHost(defaultUsername: "")
                        var host = model.hosts.first { $0.hostname == parsed.hostname && $0.port == parsed.port && $0.username == parsed.username } ?? parsed
                        host.authentication = .password; host.commandArguments = nil
                        try model.storeHost(host, credential: HostCredential(password: password)); model.connect(host)
                    } else { try await model.connectCommand(command) }
                    #endif
                }
                dismiss()
            }
            catch { self.error = error.localizedDescription }
            connecting = false
        }
    }

    static func connectionCommand(_ command: String, authentication: String, identityPath: String) throws -> String {
        let parsed = try SSHCommand(command)
        var options: [String] = []
        if authentication == "password" {
            options = ["-o", "PreferredAuthentications=keyboard-interactive,password", "-o", "PubkeyAuthentication=no"]
        } else if authentication == "file" {
            let path = (identityPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { throw CommandError("Choose an existing private key file.") }
            options = ["-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey", "-i", path]
        }
        return (["ssh"] + options + parsed.arguments).map(TerminalCommand.quote).joined(separator: " ")
    }
}
