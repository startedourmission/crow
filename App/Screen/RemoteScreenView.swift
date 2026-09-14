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
            openWindow(id: "server-screen", value: id)
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
                    #if os(macOS)
                    Toggle("Fit", isOn: Bindable(screen).fitToWindow).toggleStyle(.checkbox)
                        .help("Fit the remote screen to this window")
                    Toggle("View Only", isOn: Bindable(screen).viewOnly).toggleStyle(.checkbox)
                        .help("View without sending keyboard or mouse input")
                    Menu {
                        Toggle("Sync Clipboard", isOn: Bindable(screen).clipboardSync)
                        Toggle("Include Images (Mac Server)", isOn: Bindable(screen).includeClipboardImages)
                            .disabled(!screen.clipboardSync)
                    } label: {
                        Label("Clipboard", systemImage: screen.clipboardSync ? "checkmark.square" : "square")
                    }
                    .disabled(screen.viewOnly)
                    .help("Sync the client clipboard; image support uses the Mac SSH account’s desktop clipboard")
                    #endif
                }.padding(12)
                if let error = screen.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(12)
                        .accessibilityIdentifier("crow.screen.error")
                }
                #if os(macOS)
                if let error = screen.clipboardError {
                    HStack {
                        Text(error + " Text clipboard remains available.").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Button("Retry") { screen.retryClipboard() }
                    }.padding(.horizontal, 12)
                }
                #endif
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
            .navigationTitle(screen.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { screen.stop(); dismiss() } } }
            .alert(screen.credentialTypes.contains("username") ? "Screen Sharing Account" : "VNC Password",
                   isPresented: Binding(get: { !screen.credentialTypes.isEmpty }, set: { _ in })) {
                if screen.credentialTypes.contains("username") {
                    TextField("Server account name", text: $username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                SecureField(screen.credentialTypes.contains("username") ? "Account password" : "VNC password", text: $password)
                Button("Connect") { let value = password; password = ""; screen.authenticate(username: username, password: value) }
                Button("Cancel", role: .cancel) { password = ""; screen.stop() }
            } message: {
                Text(screen.credentialTypes.contains("username")
                    ? "Use an account allowed to share the server’s screen. On a Mac, enter the short account name and its login password."
                    : "Enter the VNC password configured on the server. On a Mac, this is set under Screen Sharing → VNC viewers may control screen with password.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 1100, minHeight: 400, idealHeight: 760)
        #endif
        .onDisappear { password = ""; screen.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { screen.stop() } }
        .onChange(of: workspace?.snapshot.workspace.connection) { _, connection in
            if connection != .connected { screen.stop() }
        }
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
