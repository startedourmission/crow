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
    }

    func pasteLiteralText(_ text: String) {
        let bracketed = getTerminal().bracketedPasteMode
        let bytes = (bracketed ? "\u{1b}[200~" : "") + text + (bracketed ? "\u{1b}[201~" : "")
        send(data: Array(bytes.utf8)[...])
    }
}
