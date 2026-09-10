import SwiftUI

@main
struct CrowApp: App {
    @State private var model = AppModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(CrowAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            CrowRootView()
                .environment(model)
                .preferredColorScheme(.light)
                #if os(macOS)
                .frame(minWidth: 640, minHeight: 400)
                .background(WindowCloseGuard(model: model))
                .onAppear { appDelegate.model = model }
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
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
            }
            CommandGroup(after: .textEditing) {
                Button("Find and Replace…") {
                    let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: nil, from: item)
                }.keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    model.sidebarVisible.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)
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
            }
        }
        #endif
    }
}
