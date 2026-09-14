#if os(macOS)
import AppKit
import Sparkle
import SwiftUI

@MainActor final class CrowAppDelegate: NSObject, NSApplicationDelegate {
    weak var windows: WorkspaceWindowStore?
    let updaterController: SPUStandardUpdaterController?

    override init() {
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        if let publicKey, !publicKey.isEmpty, !publicKey.contains("$(") {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            // Unsigned local builds intentionally do not contact the production feed.
            updaterController = nil
        }
        super.init()
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let models = Array(windows?.models.values ?? [:].values)
        guard models.contains(where: \.hasUnsavedChanges) else {
            models.forEach { $0.persist() }; return .terminateNow
        }
        switch confirmDrafts() {
        case .alertFirstButtonReturn:
            Task {
                var saved = true
                for model in models {
                    if !(await model.saveAll()) { saved = false; break }
                    model.persist()
                }
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        case .alertThirdButtonReturn: models.forEach { $0.persist() }; return .terminateNow
        default: return .terminateCancel
        }
    }
    func applicationWillTerminate(_ notification: Notification) { windows?.shutdown() }
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
    var floating = false
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?
    func makeNSView(context: Context) -> GuardView {
        let view = GuardView(model: model); view.floating = floating
        view.onActivate = onActivate; view.onClose = onClose
        return view
    }
    func updateNSView(_ view: GuardView, context: Context) {
        view.floating = floating
        view.onActivate = onActivate; view.onClose = onClose
        // Apply after SwiftUI has updated the content's minimum size.
        Task { @MainActor [weak view] in view?.applyFloatingMode() }
    }
    final class GuardView: NSView, NSWindowDelegate {
        let model: AppModel
        var floating = false
        var onActivate: (() -> Void)?
        var onClose: (() -> Void)?
        let floatingController = FloatingWindowController()
        // NSObject's forwarding hooks are nonisolated. AppKit invokes these
        // window-delegate hooks on the main thread, like the assignment below.
        nonisolated(unsafe) weak var previous: NSWindowDelegate?
        init(model: AppModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.toolbar = nil
                window.tabbingMode = .disallowed
                window.isMovableByWindowBackground = false
                // Keep OS movement/tiling available. Tab/file gestures must never
                // disable movement for the entire window, even temporarily.
                window.isMovable = true
            }
            if let window, window.delegate !== self { previous = window.delegate; window.delegate = self }
            applyFloatingMode()
            if window?.isKeyWindow == true { onActivate?() }
        }
        func applyFloatingMode() {
            guard let window else { return }
            if floating && window.styleMask.contains(.fullScreen) {
                if !floatingController.waitingForFullscreenExit {
                    floatingController.waitingForFullscreenExit = true
                    window.toggleFullScreen(nil)
                }
                return
            }
            floatingController.apply(floating, to: window)
        }
        func windowDidExitFullScreen(_ notification: Notification) {
            floatingController.waitingForFullscreenExit = false
            applyFloatingMode()
            previous?.windowDidExitFullScreen?(notification)
        }
        func windowDidBecomeKey(_ notification: Notification) {
            onActivate?()
            previous?.windowDidBecomeKey?(notification)
        }
        func windowWillClose(_ notification: Notification) {
            onClose?()
            previous?.windowWillClose?(notification)
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

private struct CrowFloatingModeKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}
extension EnvironmentValues {
    var crowFloatingMode: Binding<Bool> {
        get { self[CrowFloatingModeKey.self] }
        set { self[CrowFloatingModeKey.self] = newValue }
    }
}

struct CrowMacSceneView: View {
    let model: AppModel
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?
    @State private var floating = false
    var body: some View {
        CrowRootView().environment(model).environment(\.crowFloatingMode, $floating)
            .frame(minWidth: floating ? 360 : 640, minHeight: floating ? 280 : 400)
            .background(WindowCloseGuard(model: model, floating: floating, onActivate: onActivate, onClose: onClose))
    }
}

@MainActor final class FloatingWindowController {
    private struct Original {
        var frame: NSRect
        var level: NSWindow.Level
        var behavior: NSWindow.CollectionBehavior
        var minimum: NSSize
        var hidesOnDeactivate: Bool
    }
    private var original: Original?
    var waitingForFullscreenExit = false

    func apply(_ floating: Bool, to window: NSWindow) {
        if floating {
            guard original == nil else { return }
            original = Original(frame: window.frame, level: window.level, behavior: window.collectionBehavior,
                minimum: window.minSize, hidesOnDeactivate: window.hidesOnDeactivate)
            window.level = .floating
            var behavior = window.collectionBehavior
            behavior.subtract([.moveToActiveSpace, .fullScreenPrimary, .fullScreenAuxiliary, .canJoinAllSpaces])
            behavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.collectionBehavior = behavior
            window.hidesOnDeactivate = false
            window.minSize = NSSize(width: 360, height: 280)
            let visible = window.screen?.visibleFrame ?? window.frame
            let size = NSSize(width: min(420, visible.width), height: min(560, visible.height))
            let frame = NSRect(x: max(visible.minX, min(window.frame.maxX - size.width, visible.maxX - size.width)),
                y: max(visible.minY, min(window.frame.maxY - size.height, visible.maxY - size.height)), width: size.width, height: size.height)
            window.setFrame(frame, display: true)
        } else if let original {
            window.level = original.level; window.collectionBehavior = original.behavior
            window.minSize = original.minimum; window.hidesOnDeactivate = original.hidesOnDeactivate
            window.setFrame(original.frame, display: true)
            self.original = nil
        }
    }
}
#endif
