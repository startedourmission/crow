import CrowCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SSHKeysView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onSelect: ((SSHIdentity) -> Void)?
    @State private var keys: [SSHIdentity] = []
    @State private var creating = false
    @State private var path: [UUID] = []
    @State private var error: String?
    @State private var loading = false
    #if os(macOS)
    @State private var systemKeys: [DiscoveredSSHKey] = []
    @State private var systemKey: DiscoveredSSHKey?
    @State private var importedSystemKey: SSHIdentity?
    @Environment(\.scenePhase) private var scenePhase
    #endif

    private var isEmpty: Bool {
        #if os(macOS)
        keys.isEmpty && systemKeys.isEmpty
        #else
        keys.isEmpty
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if isEmpty && error == nil {
                    ContentUnavailableView("No SSH Keys", systemImage: "key", description: Text("Create a key here or import an existing private key."))
                }
                ForEach(keys) { key in
                    NavigationLink(value: key.id) {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(key.name, systemImage: "key")
                            Text(key.authentication == .ed25519 ? "Ed25519" : "RSA").font(.caption).foregroundStyle(.secondary)
                            Text(key.fingerprint).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }.padding(.vertical, 4)
                    }
                }
                #if os(macOS)
                if !systemKeys.isEmpty {
                    Section {
                        ForEach(systemKeys) { key in
                            Button { systemKey = key } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Label(key.name, systemImage: key.encrypted ? "lock.fill" : "key")
                                        Text(key.authentication == .ed25519 ? "Ed25519" : "RSA")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(key.fingerprint).font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    } header: { Text("On This Mac · ~/.ssh") }
                    footer: { Text("Found automatically. Select a key to view its public key or use it in Crow.") }
                }
                #endif
                if let error {
                    Text(error).foregroundStyle(CrowTheme.danger).textSelection(.enabled)
                    Button("Retry", action: reload).disabled(loading)
                }
            }
            .navigationTitle("SSH Keys")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("Add Key", systemImage: "plus") }
                        .accessibilityIdentifier("crow.keys.add")
                }
                #if os(macOS)
                ToolbarItem {
                    Button(action: reload) { Label("Refresh Keys", systemImage: "arrow.clockwise") }
                }
                #endif
            }
            .navigationDestination(for: UUID.self) { id in
                if let key = keys.first(where: { $0.id == id }) {
                    SSHKeyDetailView(key: key, onChanged: reload, onSelect: onSelect.map { select in
                        { key in select(key); dismiss() }
                    })
                }
            }
            .sheet(isPresented: $creating) {
                SSHKeyCreateView { key in reload(); path.append(key.id) }
            }
            #if os(macOS)
            .sheet(item: $systemKey, onDismiss: {
                guard let key = importedSystemKey else { return }
                importedSystemKey = nil; reload()
                if let onSelect { onSelect(key); dismiss() }
                else { path.append(key.id) }
            }) { key in
                SystemSSHKeyView(key: key, selecting: onSelect != nil) { importedSystemKey = $0 }
            }
            #endif
        }
        .onAppear(perform: reload)
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 540, minHeight: 500)
        .onChange(of: scenePhase) { _, next in
            // Returning from a denied Keychain prompt must not immediately ask again.
            if next == .active && error == nil { reload() }
        }
        #endif
    }

    private func reload() {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var failures: [String] = []
        do {
            keys = try SSHKeyStore.shared.identities()
        } catch {
            keys = []
            let failure = error as NSError
            if failure.domain == NSOSStatusErrorDomain {
                failures.append("Could not access saved SSH keys in this device’s Keychain (\(failure.code)). Unlock the keychain and allow Crow access, then retry.")
            } else {
                failures.append("Could not load saved SSH keys: " + error.localizedDescription)
            }
        }
        #if os(macOS)
        do { systemKeys = try SSHKeyStore.shared.discoverSystemKeys(savedKeys: keys) }
        catch { systemKeys = []; failures.append("Could not list ~/.ssh keys: " + error.localizedDescription) }
        #endif
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
}

#if os(macOS)
private struct SystemSSHKeyView: View {
    @Environment(\.dismiss) private var dismiss
    let key: DiscoveredSSHKey
    let selecting: Bool
    var onImport: (SSHIdentity) -> Void
    @State private var passphrase = ""
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(key.url.path).font(.caption).textSelection(.enabled)
                    Text(key.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Section("Public Key") {
                    Text(key.publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(key.publicKey, forType: .string)
                        copied = true
                    } label: { Label(copied ? "Public Key Copied" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc") }
                }
                Section {
                    if key.encrypted { SecureField("Key passphrase", text: $passphrase) }
                    Button(selecting ? "Use This Key" : "Add to SSH Keys") {
                        do {
                            let identity = try SSHKeyStore.shared.importSystemKey(key, passphrase: passphrase)
                            onImport(identity); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(key.encrypted && passphrase.isEmpty)
                } footer: {
                    Text("Crow saves a copy in this device’s Keychain. The original file stays unchanged.")
                }
                if let error { Text(error).foregroundStyle(CrowTheme.danger) }
            }
            .formStyle(.grouped)
            .navigationTitle(key.name)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.frame(minWidth: 440, minHeight: 420)
    }
}
#endif

private struct SSHKeyCreateView: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (SSHIdentity) -> Void
    @State private var importing = false
    @State private var choosingFile = false
    @State private var name = ""
    @State private var privateKey = ""
    @State private var filename: String?
    @State private var passphrase = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Source", selection: $importing) {
                    Text("Generate New Key").tag(false)
                    Text("Import Key").tag(true)
                }.pickerStyle(.segmented)
                TextField("Key name", text: $name, prompt: Text("My server key"))
                    .accessibilityIdentifier("crow.keys.name")
                if importing {
                    Button { choosingFile = true } label: {
                        Label(filename ?? "Choose Private Key…", systemImage: "square.and.arrow.down")
                    }
                    SecureField("Key passphrase (if set)", text: $passphrase)
                    Text("Import an Ed25519 or RSA OpenSSH private key, such as id_ed25519 or id_rsa.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Type", value: "Ed25519")
                    Text("The private key stays in this device’s Keychain. After creating it, copy the public key to your server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(CrowTheme.danger) }
            }
            .formStyle(.grouped)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .navigationTitle(importing ? "Import SSH Key" : "Generate SSH Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(importing ? "Import" : "Generate") {
                        do {
                            let key = try importing
                                ? SSHKeyStore.shared.importKey(name: name, privateKey: privateKey, passphrase: passphrase)
                                : SSHKeyStore.shared.generate(name: name)
                            onSave(key); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (importing && privateKey.isEmpty))
                    .accessibilityIdentifier("crow.keys.save")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 330)
        #endif
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
                      text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") else {
                    throw CommandError("Choose an OpenSSH private key, not a .pub public key.")
                }
                privateKey = text; filename = url.lastPathComponent
                if name.isEmpty { name = url.lastPathComponent }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct SSHKeyDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: SSHIdentity
    var onChanged: () -> Void
    var onSelect: ((SSHIdentity) -> Void)?
    @State private var renaming = false
    @State private var name = ""
    @State private var deleting = false
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Type", value: key.authentication == .ed25519 ? "Ed25519" : "RSA")
                LabeledContent("Created", value: key.createdAt.formatted(date: .abbreviated, time: .omitted))
                Text(key.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section("Public Key") {
                Text(key.publicKeyLine).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key.publicKeyLine, forType: .string)
                    #else
                    UIPasteboard.general.string = key.publicKeyLine
                    #endif
                    copied = true
                } label: { Label(copied ? "Public Key Copied" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .accessibilityIdentifier("crow.keys.copy-public")
                Text("Add this public key as a line in ~/.ssh/authorized_keys on your server, or in your provider’s SSH key settings. Then choose this key in the host’s Authentication settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let onSelect {
                Section { Button("Use This Key") { onSelect(key) }.accessibilityIdentifier("crow.keys.select") }
            }
            Section {
                Button("Rename Key") { name = key.name; renaming = true }
                Button("Delete Key…", role: .destructive) { deleting = true }
            }
            if let error { Text(error).foregroundStyle(CrowTheme.danger) }
        }
        .formStyle(.grouped)
        .navigationTitle(key.name)
        .alert("Rename Key", isPresented: $renaming) {
            TextField("Key name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                do { try SSHKeyStore.shared.rename(key.id, to: name); onChanged(); error = nil; copied = false }
                catch { self.error = error.localizedDescription }
            }
        }
        .confirmationDialog("Delete \(key.name)?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Key", role: .destructive) {
                do { try SSHKeyStore.shared.remove(key.id, hosts: model.hosts); dismiss(); onChanged() }
                catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("The private key will be removed from this device. This does not remove the public key from your servers. Keys used by saved hosts cannot be deleted.")
        }
    }
}
