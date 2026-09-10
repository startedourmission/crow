import SwiftUI

extension View {
    @ViewBuilder func windowDragExcluded() -> some View {
        #if os(macOS)
        background { WindowDragExclusion() }
        #else
        self
        #endif
    }
    @ViewBuilder func windowDragBackground() -> some View {
        #if os(macOS)
        background { WindowDragRegion() }
        #else
        self
        #endif
    }
}

#if os(macOS)
import AppKit

/// Explicit blank SwiftUI regions register geometry, but do not intercept mouse events.
struct WindowDragRegion: View {
    var body: some View {
        GeometryReader { geometry in
            WindowMoveAnchor(size: geometry.size)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
    }
}

/// Controls inside an otherwise draggable strip opt out with their actual geometry.
/// This includes the whole tab (close button and padding), not just its drag source.
struct WindowDragExclusion: View {
    var body: some View {
        GeometryReader { geometry in
            WindowMoveAnchor(size: geometry.size, excludesMovement: true)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
    }
}

private struct WindowMoveAnchor: NSViewRepresentable {
    let size: NSSize
    var excludesMovement = false
    func makeNSView(context: Context) -> WindowMoveAnchorView { WindowMoveAnchorView() }
    func updateNSView(_ view: WindowMoveAnchorView, context: Context) {
        view.regionSize = size
        view.excludesMovement = excludesMovement
        view.register()
    }
}

final class WindowMoveAnchorView: NSView {
    var regionSize: NSSize = .zero
    var excludesMovement = false
    private weak var surface: WindowMoveSurface?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { surface?.unregister(self); surface = nil }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); register() }
    func register() {
        guard let content = window?.contentView, let frame = content.superview else { return }
        if let surface, surface.superview === frame, surface.window === window { return }
        surface?.unregister(self)
        let surface = frame.subviews.compactMap { $0 as? WindowMoveSurface }.first ?? {
            let view = WindowMoveSurface(frame: content.convert(content.bounds, to: frame))
            view.autoresizingMask = [.width, .height]
            // SwiftUI's own hit-test graph otherwise swallows transparent NSView overlays.
            frame.addSubview(view, positioned: .above, relativeTo: content)
            return view
        }()
        surface.register(self); self.surface = surface
    }
    var activeRect: NSRect {
        NSRect(origin: bounds.origin, size: regionSize).intersection(bounds).intersection(visibleRect)
    }
}

/// A native sibling of NSHostingView, transparent to hit testing everywhere except
/// registered blank rectangles. No event monitors, no window-wide gesture, no global cursor reads.
final class WindowMoveSurface: NSView {
    private let anchors = NSHashTable<WindowMoveAnchorView>.weakObjects()
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func register(_ anchor: WindowMoveAnchorView) { anchors.add(anchor) }
    func unregister(_ anchor: WindowMoveAnchorView) {
        anchors.remove(anchor)
        if anchors.allObjects.isEmpty { removeFromSuperview() }
    }
    func containsRegion(_ point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        if let content = window?.contentView {
            // A sidebar's blank area is draggable, but its native scrollbars and
            // editable fields remain controls even when their geometry changes.
            var target = content.hitTest(convert(point, to: content.superview))
            while let view = target, view !== content {
                if view is NSScroller || view is NSTextView || view is NSTextField || view is NSButton { return false }
                target = view.superview
            }
        }
        let matching = anchors.allObjects.filter { anchor in
            anchor.window === window && !anchor.isHiddenOrHasHiddenAncestor &&
                !anchor.activeRect.isEmpty && anchor.activeRect.contains(anchor.convert(point, from: self))
        }
        // Full-height content can overlap the native traffic-light controls.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window?.standardWindowButton(kind), !button.isHiddenOrHasHiddenAncestor,
               button.bounds.contains(button.convert(point, from: self)) { return false }
        }
        return matching.contains { !$0.excludesMovement } && !matching.contains { $0.excludesMovement }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSApp.currentEvent?.type == .rightMouseDown || NSApp.currentEvent?.modifierFlags.contains(.control) == true { return nil }
        guard !isHidden, containsRegion(convert(point, from: superview)) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control), let window,
              containsRegion(convert(event.locationInWindow, from: nil)) else { return }
        // Let AppKit/Window Server track the drag, snap and move across displays.
        // Manual setFrameOrigin loops only proved programmatic movement in tests
        // and required a window-wide lock that broke native OS window commands.
        window.performDrag(with: event)
    }
}
#endif
