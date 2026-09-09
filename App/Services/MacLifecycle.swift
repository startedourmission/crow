#if os(macOS)
import AppKit
import SwiftUI

@MainActor final class CrowAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard model.hasUnsavedChanges else { model.persist(); return .terminateNow }
        switch confirmDrafts() {
        case .alertFirstButtonReturn:
            Task {
                let saved = await model.saveAll()
                model.persist()
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        case .alertThirdButtonReturn: model.persist(); return .terminateNow
        default: return .terminateCancel
        }
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

@MainActor private func confirmDrafts() -> NSApplication.ModalResponse {
    let alert = NSAlert()
    alert.messageText = "You have unsaved changes"
    alert.informativeText = "Save to the original files, or keep drafts to restore the edited text next time."
    alert.addButton(withTitle: "Save All")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Keep Drafts")
    return alert.runModal()
}

struct WindowCloseGuard: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> GuardView { GuardView(model: model) }
    func updateNSView(_ view: GuardView, context: Context) {}
    final class GuardView: NSView, NSWindowDelegate {
        let model: AppModel
        // NSObject's forwarding hooks are nonisolated. AppKit invokes these
        // window-delegate hooks on the main thread, like the assignment below.
        nonisolated(unsafe) weak var previous: NSWindowDelegate?
        init(model: AppModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, window.delegate !== self { previous = window.delegate; window.delegate = self }
        }
        override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return previous?.responds(to: selector) ?? false
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previous?.responds(to: selector) == true { return previous }
            return super.forwardingTarget(for: selector)
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model.hasUnsavedChanges else { model.persist(); return previous?.windowShouldClose?(sender) ?? true }
            switch confirmDrafts() {
            case .alertFirstButtonReturn:
                Task { if await model.saveAll() { sender.performClose(nil) } }
                return false
            case .alertThirdButtonReturn: model.persist(); return true
            default: return false
            }
        }
    }
}
#endif
