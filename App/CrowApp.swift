import SwiftUI
import CrowCore

@main
struct CrowApp: App {
    @State private var model = AppModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(CrowAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Scene {
        WindowGroup(id: "workspace") {
            #if os(macOS)
            CrowMacSceneView(model: model)
                .preferredColorScheme(.light)
                .onAppear { appDelegate.model = model }
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
                    model.newUntitledBuffer()
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Folder…") { model.folderImporterVisible = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save") {
                    if !NSApp.sendAction(#selector(CodeTextView.saveDocument(_:)), to: nil, from: nil) { model.saveSelectedBuffer() }
                }.keyboardShortcut("s", modifiers: .command)
                Button("Save All") { Task { await model.saveAll() } }.keyboardShortcut("s", modifiers: [.command, .option])
                Button("Close Tab") {
                    if let pane = model.current.snapshot.layout?.activePane, let tab = pane.selected {
                        model.closeTab(tab, in: pane.id)
                    }
                }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.settingsVisible = true }.keyboardShortcut(",", modifiers: .command)
                Button("SSH Keys…") { model.sshKeysVisible = true }
            }
            CommandGroup(after: .textEditing) {
                Button("Find and Replace…") {
                    model.findInCurrentDocument()
                }.keyboardShortcut("f", modifiers: .command).disabled(model.inspectedBuffer == nil)
                Button("Search Files…") { model.focusFileSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(!model.hasWorkspace)
                Button("Increase Font Size") { model.adjustFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Increase Font Size (Alternate)") { model.adjustFontSize(by: 1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") { model.adjustFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    model.sidebarVisible.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Toggle Right Sidebar") { model.inspectorVisible.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Button("Toggle Terminal") {
                    model.terminalVisible.toggle()
                }
                .keyboardShortcut("`", modifiers: .control)
                Button("New Terminal") { model.newTerminal() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Split Right") {
                    if let pane = model.current.snapshot.layout?.activePane, let tab = pane.selected {
                        model.splitTab(tab, in: pane.id, placement: .right)
                    }
                }.keyboardShortcut("\\", modifiers: .command)
                ForEach(1...9, id: \.self) { number in
                    Button("Select Tab \(number)") { model.selectNumberedTab(number) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                        .disabled((model.current.snapshot.layout?.activePane?.tabs.count ?? 0) < number)
                }
            }
        }
        #endif
        #if os(macOS)
        WindowGroup("Server Screen", id: "server-screen", for: WorkspaceID.self) { $workspaceID in
            if let workspaceID {
                RemoteScreenView(workspaceID: workspaceID)
                    .environment(model)
                    .preferredColorScheme(.light)
                    .tint(CrowTheme.accent)
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
