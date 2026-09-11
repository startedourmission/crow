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
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        session.view
    }
    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        keyboard?.register(view, surface: .terminal)
        session.setFontSize(fontSize)
        let background = UIColor(CrowTheme.bg0)
        view.backgroundColor = background
        view.nativeBackgroundColor = background
        (view as? CrowIOSTerminalView)?.setPhoneAccessory(phoneLayout)
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
