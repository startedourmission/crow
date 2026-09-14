import SwiftUI
import CrowCore

@main
struct CrowApp: App {
    #if os(macOS)
    @State private var windows = WorkspaceWindowStore()
    @FocusedValue(\.crowWindowModel) private var focusedModel
    private var model: AppModel? { focusedModel ?? windows.activeModel }
    @NSApplicationDelegateAdaptor(CrowAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    #else
    @State private var model = AppModel()
    #endif

    var body: some Scene {
        WindowGroup(id: "workspace") {
            #if os(macOS)
            CrowWorkspaceWindow(windows: windows)
                .preferredColorScheme(.light)
                .onAppear { appDelegate.windows = windows }
            #else
            CrowRootView()
                .environment(model)
                .preferredColorScheme(.light)
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { appDelegate.checkForUpdates() }
                    .disabled(appDelegate.updaterController == nil)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Window") { openWindow(id: "workspace") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New File") {
                    model?.newUntitledBuffer()
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Folder…") { model?.folderImporterVisible = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save") {
                    if !NSApp.sendAction(#selector(CodeTextView.saveDocument(_:)), to: nil, from: nil) { model?.saveSelectedBuffer() }
                }.keyboardShortcut("s", modifiers: .command)
                    .disabled(model?.inspectedBuffer == nil || model?.inspectedBuffer?.isImage == true)
                Button("Save All") { Task { await model?.saveAll() } }.keyboardShortcut("s", modifiers: [.command, .option])
                Button("Close Tab") {
                    if let pane = model?.current.snapshot.layout?.activePane, let tab = pane.selected {
                        model?.closeTab(tab, in: pane.id)
                    }
                }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model?.settingsVisible = true }.keyboardShortcut(",", modifiers: .command)
                Button("SSH Keys…") { model?.sshKeysVisible = true }
            }
            CommandGroup(after: .textEditing) {
                Button("Find and Replace…") {
                    model?.findInCurrentDocument()
                }.keyboardShortcut("f", modifiers: .command).disabled(model?.inspectedBuffer == nil || model?.inspectedBuffer?.isImage == true)
                Button("Search Files…") { model?.focusFileSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(model?.hasWorkspace != true)
                Button("Increase Font Size") { model?.adjustFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Increase Font Size (Alternate)") { model?.adjustFontSize(by: 1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") { model?.adjustFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    if let model { model.sidebarVisible.toggle() }
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Toggle Right Sidebar") { if let model { model.inspectorVisible.toggle() } }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Button("Toggle Terminal") {
                    if let model { model.terminalVisible.toggle() }
                }
                .keyboardShortcut("`", modifiers: .control)
                Button("New Terminal") { model?.newTerminal() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Split Right") {
                    if let pane = model?.current.snapshot.layout?.activePane, let tab = pane.selected {
                        model?.splitTab(tab, in: pane.id, placement: .right)
                    }
                }.keyboardShortcut("\\", modifiers: .command)
                ForEach(1...9, id: \.self) { number in
                    Button("Select Tab \(number)") { model?.selectNumberedTab(number) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                        .disabled((model?.current.snapshot.layout?.activePane?.tabs.count ?? 0) < number)
                }
            }
        }
        #endif
        #if os(macOS)
        WindowGroup("Server Screen", id: "server-screen", for: ScreenWindowID.self) { $screenID in
            if let screenID, let owner = windows.model(for: screenID.windowID) {
                RemoteScreenView(workspaceID: screenID.workspaceID)
                    .environment(owner)
                    .focusedSceneValue(\.crowWindowModel, owner)
                    .preferredColorScheme(.light)
                    .tint(CrowTheme.accent)
            } else {
                ContentUnavailableView("Workspace Window Closed", systemImage: "desktopcomputer",
                    description: Text("Open screen sharing from a connected SSH workspace."))
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
