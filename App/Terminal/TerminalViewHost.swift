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
    @Environment(\.crowPhoneLayout) private var phoneLayout
    let session: TerminalSession
    let fontSize: Double
    #if os(iOS)
    @Environment(\.phoneKeyboardFocus) private var keyboard
    @Environment(\.keyboardBarItems) private var keyboardBarItems
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        session.view
    }
    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        keyboard?.register(view, surface: .terminal)
        session.setFontSize(fontSize)
        let background = UIColor(CrowTheme.bg0)
        view.backgroundColor = background
        view.nativeBackgroundColor = background
        (view as? CrowIOSTerminalView)?.setPhoneAccessory(true)
        (view.inputAccessoryView as? CrowKeyboardAccessory)?.configure(keyboardBarItems)
    }
    #else
    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        session.view
    }
    func updateNSView(_ view: SwiftTerm.TerminalView, context: Context) {
        session.setFontSize(fontSize)
    }
    #endif
}

struct ImagePasteStatusView: View {
    let session: TerminalSession
    var body: some View {
        if let message = session.imagePasteMessage {
            HStack(spacing: 8) {
                if session.imagePasteInProgress { ProgressView().controlSize(.small) }
                Text(message).font(.caption).lineLimit(3).textSelection(.enabled)
                Spacer(minLength: 0)
                if !session.imagePasteInProgress {
                    Button { session.imagePasteMessage = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss image paste message")
                }
            }.padding(8).background(CrowTheme.bg1)
        }
    }
}

@MainActor extension SwiftTerm.TerminalView {
    /// Incoming output must not cancel a local drag. SwiftTerm's feed preparation
    /// clears selection whenever mouse reporting is enabled, even outside mouse mode.
    /// Suppress that feed-side policy only; mouse events keep their normal routing.
    func feedProcessOutput(_ bytes: ArraySlice<UInt8>) {
        #if os(macOS)
        let reporting = allowMouseReporting
        allowMouseReporting = false
        defer { allowMouseReporting = reporting }
        #endif
        feed(byteArray: bytes)
        #if os(macOS)
        (self as? any MarkedTextTerminal)?.composition.update(in: self)
        #endif
    }

    func pasteLiteralText(_ text: String) {
        let bracketed = getTerminal().bracketedPasteMode
        let bytes = (bracketed ? "\u{1b}[200~" : "") + text + (bracketed ? "\u{1b}[201~" : "")
        send(data: Array(bytes.utf8)[...])
    }
}

#if os(macOS)
@MainActor protocol MarkedTextTerminal: AnyObject {
    var composition: TerminalComposition { get }
}

/// SwiftTerm anchors its marked text to the last painted caret. Reposition the
/// native preview from the current buffer after each echo, and keep the block
/// caret from being reinserted above the composing syllable by output updates.
@MainActor final class TerminalComposition {
    private var caretColor: NSColor?
    private var caretTextColor: NSColor?
    private(set) var rect: NSRect?

    func update(in view: SwiftTerm.TerminalView) {
        guard view.hasMarkedText() else { clear(in: view); return }
        guard let overlay = view.subviews.compactMap({ $0 as? NSTextView }).first,
              let container = overlay.textContainer, let layout = overlay.layoutManager,
              let pixels = view.cellSizeInPixels(source: view.getTerminal()) else { return }
        if caretColor == nil {
            caretColor = view.caretColor; caretTextColor = view.caretTextColor
            view.caretColor = .clear; view.caretTextColor = .clear
        }
        let scale = view.window?.backingScaleFactor ?? 1
        let cell = NSSize(width: CGFloat(pixels.width) / scale, height: CGFloat(pixels.height) / scale)
        let terminal = view.getTerminal(), cursor = terminal.getCursorLocation()
        let wrapped = cursor.x >= terminal.cols
        let x = max(4, CGFloat(wrapped ? 0 : cursor.x) * cell.width)
        let y = view.bounds.height - CGFloat(cursor.y + (wrapped ? 2 : 1)) * cell.height
        container.exclusionPaths = x > 4
            ? [NSBezierPath(rect: NSRect(x: 0, y: 0, width: x - 4, height: cell.height + 1))] : []
        if let storage = overlay.textStorage {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: storage.length))
        }
        layout.ensureLayout(for: container)
        let height = max(cell.height, layout.usedRect(for: container).height)
        overlay.frame.origin = NSPoint(x: 4, y: y + cell.height - height)
        overlay.frame.size.height = height
        rect = NSRect(x: x, y: y, width: cell.width, height: cell.height)
        view.inputContext?.invalidateCharacterCoordinates()
    }

    func clear(in view: SwiftTerm.TerminalView) {
        if let caretColor {
            view.caretColor = caretColor; view.caretTextColor = caretTextColor
        }
        caretColor = nil; caretTextColor = nil; rect = nil
    }

    func screenRect(in view: SwiftTerm.TerminalView) -> NSRect? {
        guard let rect, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(rect, to: nil))
    }
}
#endif
