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
