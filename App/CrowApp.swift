import SwiftUI

@main
struct CrowApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            CrowRootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New File") {
                    model.newUntitledBuffer()
                }
                .keyboardShortcut("n", modifiers: .command)
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
            }
        }
        #endif
    }
}
