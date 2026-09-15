import SwiftUI
import CrowCore
import WebKit

struct ScreenRequest: Identifiable { let id: WorkspaceID }

struct ScreenPresentation: ViewModifier {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onChange(of: model.screenRequest?.id) { _, id in
            guard let id else { return }
            model.screenRequest = nil
            openWindow(id: "server-screen", value: ScreenWindowID(windowID: model.windowID, workspaceID: id))
        }
        #else
        content.fullScreenCover(item: Bindable(model).screenRequest) { request in
            RemoteScreenView(workspaceID: request.id).environment(model)
        }
        #endif
    }
}

struct RemoteScreenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let workspaceID: WorkspaceID
    @State private var screen = RemoteScreenSession()
    @State private var port = "5900"
    @State private var connectionOptions = false
    @State private var loginMode = ScreenLoginMode.workspaceAccount
    @State private var username = ""
    @State private var password = ""
    private var workspace: WorkspaceState? { model.states.first { $0.id == workspaceID } }
    private var host: SSHHost? {
        workspace?.snapshot.workspace.hostID.flatMap { id in model.hosts.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                                Text(instructions)
                                    .font(.caption)
                            }
                            .multilineTextAlignment(.center).padding(24).frame(maxWidth: 480)
                            .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(red: 0.09, green: 0.10, blue: 0.12))
                        }
                    }
            }
            .navigationTitle(host?.userAtHost ?? screen.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .cancellationAction) {
                    screenConnectionButton
                    screenMenu
                }
            }
            .alert("Connect to Server Screen", isPresented: $connectionOptions) {
                TextField("VNC port", text: $port)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Button("Connect") {
                    guard let workspace, let value = Int(port), (1...65535).contains(value) else { return }
                    screen.connect(in: workspace, port: value, loginMode: loginMode, username: host?.username)
                }.disabled(!(1...65535).contains(Int(port) ?? 0))
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(loginMode == .workspaceAccount
                    ? "Connect through \(host?.userAtHost ?? "this SSH workspace"). On a Mac, sign in with this account’s Mac login password."
                    : "Open the server’s shared desktop using its VNC password. This does not select the SSH account’s desktop.")
            }
            .alert(screen.credentialTypes.contains("username") ? "Screen Sharing Account" : "VNC Password",
                   isPresented: Binding(get: { !screen.credentialTypes.isEmpty }, set: { _ in })) {
                if screen.credentialTypes.contains("username") && !screen.workspaceAccountRequired {
                    TextField("Screen account name", text: $username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                SecureField(screen.credentialTypes.contains("username") ? "Account password" : "VNC password", text: $password)
                Button("Connect") {
                    let value = password; password = ""
                    screen.authenticate(username: screen.workspaceAccountRequired ? screen.requestedUsername : username, password: value)
                }
                Button("Cancel", role: .cancel) { password = ""; screen.stop() }
            } message: {
                Text(screen.workspaceAccountRequired
                    ? "Enter the Mac login password for \(screen.requestedUsername). The selected workspace determines the account."
                    : screen.credentialTypes.contains("username")
                        ? "Enter the account and password configured on this screen-sharing server."
                        : "Enter the VNC password configured on the server. On a Mac, this is set under Screen Sharing → VNC viewers may control screen with password.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 1100, minHeight: 400, idealHeight: 760)
        #endif
        .onDisappear { password = ""; screen.stop() }
        .onChange(of: screen.credentialTypes) { _, types in
            if types.contains("username") { username = screen.requestedUsername }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { screen.stop() } }
        .onChange(of: workspace?.snapshot.workspace.connection) { _, connection in
            if connection != .connected { screen.stop() }
        }
    }

    @ViewBuilder
    private var screenConnectionButton: some View {
        if screen.active {
            Button("Disconnect", systemImage: "network.slash") { screen.stop() }
                .labelStyle(.titleAndIcon)
                .help(screen.connected ? "Connected through SSH" : "Connecting…")
                .accessibilityIdentifier("crow.screen.disconnect")
        } else {
            Button("Connect…", systemImage: "network") { connectionOptions = true }
                .labelStyle(.titleAndIcon)
                .disabled(!screen.ready || workspace?.snapshot.workspace.connection != .connected)
                .accessibilityIdentifier("crow.screen.connect")
        }
    }

    private var screenMenu: some View {
        Menu {
            Picker("Screen Login", selection: $loginMode) {
                ForEach(ScreenLoginMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }.disabled(screen.active)
            Divider()
            Toggle("Fit to Window", isOn: Bindable(screen).fitToWindow)
            Toggle("View Only", isOn: Bindable(screen).viewOnly)
            #if os(macOS)
            Divider()
            Toggle("Sync Clipboard", isOn: Bindable(screen).clipboardSync)
                .disabled(screen.viewOnly)
            Toggle("Include Images (Mac Server)", isOn: Bindable(screen).includeClipboardImages)
                .disabled(screen.viewOnly || !screen.clipboardSync || !screen.nativeClipboardAvailable)
            if screen.connected && !screen.nativeClipboardAvailable {
                Text("Text clipboard uses screen sharing. Images require the same SSH and Mac screen account.")
            }
            if let error = screen.clipboardError {
                Text(error)
                Button("Retry Clipboard Sync", systemImage: "arrow.clockwise") { screen.retryClipboard() }
            }
            #endif
            Divider()
            Button("Close", systemImage: "xmark") { screen.stop(); dismiss() }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Screen Controls")
        .accessibilityIdentifier("crow.screen.menu")
    }

    private var instructions: String {
        #if os(macOS)
        "Click the screen to use your keyboard and mouse. Turn off Fit to pan at actual size."
        #else
        "Touch or click to control. Tap Keyboard to type directly on the server, or use a hardware keyboard after selecting the screen. Turn off Fit to pan at actual size."
        #endif
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
