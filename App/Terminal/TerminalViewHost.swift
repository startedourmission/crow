import CrowCore
import SwiftTerm
import SwiftUI

#if os(iOS)
import UIKit
private typealias PlatformTerminalViewRepresentable = UIViewRepresentable
#elseif os(macOS)
import AppKit
private typealias PlatformTerminalViewRepresentable = NSViewRepresentable
#endif

struct TerminalViewHost: PlatformTerminalViewRepresentable {
    @Environment(AppModel.self) private var model
    let workspace: Workspace

    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator()
    }

    #if os(iOS)
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let font = UIFont.monospacedSystemFont(
            ofSize: CrowTheme.terminalFontSize(compact: true),
            weight: .regular
        )
        let view = SwiftTerm.TerminalView(frame: .zero, font: font)
        configure(view, context: context)
        return view
    }

    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        update(view, context: context)
    }
    #else
    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let font = NSFont.monospacedSystemFont(
            ofSize: CrowTheme.terminalFontSize(compact: false),
            weight: .regular
        )
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.font = font
        configure(view, context: context)
        return view
    }

    func updateNSView(_ view: SwiftTerm.TerminalView, context: Context) {
        update(view, context: context)
    }
    #endif

    private func configure(_ view: SwiftTerm.TerminalView, context: Context) {
        view.terminalDelegate = context.coordinator
        view.optionAsMetaKey = false
        #if os(iOS)
        view.backgroundColor = UIColor(CrowTheme.bg0)
        view.nativeForegroundColor = UIColor(CrowTheme.text)
        view.nativeBackgroundColor = UIColor(CrowTheme.bg0)
        #else
        view.nativeForegroundColor = NSColor(CrowTheme.text)
        view.nativeBackgroundColor = NSColor(CrowTheme.bg0)
        #endif
        context.coordinator.onBytes = { bytes in
            Task { @MainActor in
                model.recordPTY(bytes[...])
            }
        }
        context.coordinator.reset(on: view, workspace: workspace)
    }

    private func update(_ view: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.onBytes = { bytes in
            Task { @MainActor in
                model.recordPTY(bytes[...])
            }
        }
        if context.coordinator.workspaceID != workspace.id {
            context.coordinator.reset(on: view, workspace: workspace)
        }
    }
}

final class TerminalCoordinator: NSObject, TerminalViewDelegate {
    var workspaceID: WorkspaceID?
    var onBytes: (([UInt8]) -> Void)?

    func reset(on view: SwiftTerm.TerminalView, workspace: Workspace) {
        workspaceID = workspace.id
        view.feed(text: "\u{001b}[2J\u{001b}[H" + Self.bannerText(workspace))
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        onBytes?(Array(data))
        source.feed(byteArray: data)
    }

    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    func bell(source: SwiftTerm.TerminalView) {}

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        #if os(iOS)
        if let text = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = text
        }
        #else
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        #endif
    }

    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

    static func bannerText(_ workspace: Workspace) -> String {
        switch workspace.kind {
        case .imeLab:
            return "Crow IME Lab\r\nHangul composition must not reach the PTY.\r\nInspector shows committed UTF-8 only.\r\n\r\n> "
        case .local:
            return "Crow · local echo\r\n\r\n$ "
        case .remote:
            return "Crow · \(workspace.name)\r\nThis workspace is bound to the host. Transport is next.\r\n\r\n$ "
        }
    }
}
