import SwiftUI
import CrowCore

struct SSHCommandView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var command = "ssh "
    @State private var error: String?
    @State private var connecting = false
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
                #if os(macOS)
                Text("Uses your OpenSSH config, keys and agent. Password and server verification prompts appear in the terminal.")
                    .font(.caption).foregroundStyle(.secondary)
                #else
                Text("Enter the command. A password is requested only if needed.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Import key / Advanced…") { dismiss(); model.editHost() }.font(.caption)
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
        .frame(width: 520, height: 210)
        #endif
        .onAppear { focused = true }
    }
    private func connect() {
        guard !connecting else { return }; connecting = true
        Task {
            do { try await model.connectCommand(command); dismiss() }
            catch { self.error = error.localizedDescription }
            connecting = false
        }
    }
}

struct SSHPasswordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: SSHHost
    @State private var password = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(host.userAtHost).font(.system(.body, design: .monospaced))
                SecureField("Password", text: $password).onSubmit(connect)
                if let error { Text(error).foregroundStyle(CrowTheme.danger) }
            }.padding(20)
            .navigationTitle("SSH Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Connect", action: connect) }
            }
        }
    }
    private func connect() {
        do { try model.storeHost(host, credential: HostCredential(password: password)); dismiss(); model.connect(host) }
        catch { self.error = error.localizedDescription }
    }
}
