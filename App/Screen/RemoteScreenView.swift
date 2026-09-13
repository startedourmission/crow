import SwiftUI
import CrowCore
import WebKit

struct ScreenRequest: Identifiable { let id: WorkspaceID }

struct RemoteScreenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let workspaceID: WorkspaceID
    @State private var screen = RemoteScreenSession()
    @State private var port = "5900"
    @State private var username = ""
    @State private var password = ""
    private var workspace: WorkspaceState? { model.states.first { $0.id == workspaceID } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    if screen.active {
                        Text(screen.connected ? "Connected through SSH" : "Connecting…").font(.caption)
                        if !screen.connected { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Disconnect") { screen.stop() }
                    } else {
                        Text("VNC port").font(.caption)
                        TextField("5900", text: $port).textFieldStyle(.roundedBorder).frame(maxWidth: 100)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        Spacer()
                        Button("Connect") {
                            guard let workspace, let value = Int(port) else { return }
                            screen.connect(in: workspace, port: value)
                        }
                        .disabled(!screen.ready || workspace?.snapshot.workspace.connection != .connected || !(1...65535).contains(Int(port) ?? 0))
                        .accessibilityIdentifier("crow.screen.connect")
                    }
                }.padding(12)
                if let error = screen.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(12)
                        .accessibilityIdentifier("crow.screen.error")
                }
                ScreenWebView(screen: screen)
                    .overlay {
                        if !screen.active {
                            VStack(spacing: 12) {
                                Image(systemName: "desktopcomputer").font(.largeTitle)
                                Text("View and control this SSH server’s desktop").font(.headline)
                                Text("Enable Screen Sharing on a Mac, or a VNC server on Windows/Linux. Screen traffic uses your SSH connection. Screen sharing credentials may differ from SSH credentials.")
                                    .font(.callout)
                                Text("Touch or click to control. Use the text field below the screen to type from a phone or tablet. Turn off Fit to pan at actual size.")
                                    .font(.caption)
                            }
                            .multilineTextAlignment(.center).padding(24).frame(maxWidth: 480)
                            .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(red: 0.09, green: 0.10, blue: 0.12))
                        }
                    }
            }
            .navigationTitle(screen.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { screen.stop(); dismiss() } } }
            .alert("Screen Sharing Login", isPresented: Binding(get: { !screen.credentialTypes.isEmpty }, set: { _ in })) {
                if screen.credentialTypes.contains("username") { TextField("Server username", text: $username) }
                SecureField("Screen sharing password", text: $password)
                Button("Connect") { let value = password; password = ""; screen.authenticate(username: username, password: value) }
                Button("Cancel", role: .cancel) { password = ""; screen.stop() }
            } message: { Text("Use the screen sharing account or VNC password configured on the server.") }
        }
        #if os(macOS)
        .frame(minWidth: 800, idealWidth: 1100, minHeight: 560, idealHeight: 760)
        #endif
        .onDisappear { password = ""; screen.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { screen.stop() } }
        .onChange(of: workspace?.snapshot.workspace.connection) { _, connection in
            if connection != .connected { screen.stop() }
        }
    }
}

#if os(macOS)
private struct ScreenWebView: NSViewRepresentable {
    let screen: RemoteScreenSession
    func makeNSView(context: Context) -> WKWebView { screen.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
private struct ScreenWebView: UIViewRepresentable {
    let screen: RemoteScreenSession
    func makeUIView(context: Context) -> WKWebView { screen.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
