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
    let session: TerminalSession
    let fontSize: Double
    #if os(iOS)
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        session.view
    }
    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        session.setFontSize(fontSize)
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
