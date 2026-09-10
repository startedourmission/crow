import SwiftUI

enum CrowTheme {
    static let bg0 = Color.white
    static let bg1 = Color(white: 0.965)
    static let bg2 = Color(red: 0.94, green: 0.95, blue: 0.965)
    static let bg3 = Color(red: 0.89, green: 0.915, blue: 0.945)
    static let fileSelection = Color(white: 0.91)
    static let accent = Color(red: 0.075, green: 0.13, blue: 0.22)
    static let border = accent.opacity(0.12)
    static let text = Color(red: 0.10, green: 0.13, blue: 0.18)
    static let textDim = Color(red: 0.40, green: 0.44, blue: 0.50)
    static let danger = Color(red: 0.72, green: 0.20, blue: 0.18)
    static let ok = Color(red: 0.18, green: 0.44, blue: 0.30)

    static func hoveredForeground(_ normal: Color) -> Color {
        normal == accent ? accent.opacity(0.68) : accent
    }

    static let activityWidth: CGFloat = 48
    static let sidebarWidth: CGFloat = 260
    static let terminalMinHeight: CGFloat = 160

    static func editorFont(size: CGFloat, monospace: Bool) -> Font {
        if monospace {
            return .system(size: size, design: .monospaced)
        }
        return .system(size: size + 1, design: .default)
    }

    static func terminalFontSize(compact: Bool) -> CGFloat {
        compact ? 18 : 16
    }
}

struct CrowDivider: View {
    var body: some View {
        Rectangle()
            .fill(CrowTheme.border)
            .frame(maxWidth: .infinity, maxHeight: 1)
    }
}

/// Shared glyph sizing and hit area for pane-header actions.
struct PanelActionIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .regular))
            .crowForeground(CrowTheme.textDim)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

private struct CrowControlHoveredKey: EnvironmentKey {
    static let defaultValue = false
}
private struct CrowControlColorKey: EnvironmentKey {
    static let defaultValue = CrowTheme.text
}

extension EnvironmentValues {
    var crowControlHovered: Bool {
        get { self[CrowControlHoveredKey.self] }
        set { self[CrowControlHoveredKey.self] = newValue }
    }
    var crowControlColor: Color {
        get { self[CrowControlColorKey.self] }
        set { self[CrowControlColorKey.self] = newValue }
    }
}

/// Explicit label colors still participate in the enclosing control's hover state.
private struct CrowControlForeground: ViewModifier {
    @Environment(\.crowControlHovered) private var hovered
    let color: Color
    func body(content: Content) -> some View {
        content.foregroundStyle(hovered ? CrowTheme.hoveredForeground(color) : color).environment(\.crowControlColor, color)
    }
}

extension View {
    func crowForeground(_ color: Color) -> some View {
        modifier(CrowControlForeground(color: color))
    }

    /// Menus use the same label feedback while retaining native menu behavior.
    func crowMenuHover() -> some View { modifier(CrowControlFeedback(kind: .plain)) }
}

struct CrowButtonStyle: ButtonStyle {
    enum Kind { case plain, filled }
    var kind: Kind = .plain

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(CrowControlFeedback(kind: kind,
            pressed: configuration.isPressed, destructive: configuration.role == .destructive))
    }
}

private struct CrowControlFeedback: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.crowControlColor) private var color
    @State private var hovered = false
    let kind: CrowButtonStyle.Kind
    var pressed = false
    var destructive = false

    func body(content: Content) -> some View {
        let active = enabled && (hovered || pressed)
        content
            .environment(\.crowControlHovered, active && kind == .plain)
            .foregroundStyle(active && kind == .plain ? CrowTheme.hoveredForeground(color) : destructive ? CrowTheme.danger : color)
            .padding(.horizontal, kind == .filled ? 10 : 0)
            .padding(.vertical, kind == .filled ? 5 : 0)
            .background {
                if kind == .filled {
                    RoundedRectangle(cornerRadius: 5).fill(active ? CrowTheme.bg3 : CrowTheme.bg2)
                }
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            #if os(macOS)
            // Native tracking also covers the AppKit drag sources above file and tab labels.
            .background {
                GeometryReader { geometry in
                    CrowHoverTracking(size: geometry.size) { hovered = $0 }
                }.allowsHitTesting(false)
            }
            #else
            .onHover { hovered = $0 }
            #endif
            .onDisappear { hovered = false }
    }
}

#if os(macOS)
import AppKit

private struct CrowHoverTracking: NSViewRepresentable {
    let size: CGSize
    var onHover: (Bool) -> Void
    func makeNSView(context: Context) -> CrowHoverTrackingView { CrowHoverTrackingView() }
    func updateNSView(_ view: CrowHoverTrackingView, context: Context) {
        view.regionSize = size; view.onHover = onHover
        view.updateTrackingAreas()
    }
}

/// Tracking only: never intercept clicks, drags, focus, or the user's pointer.
final class CrowHoverTrackingView: NSView {
    var regionSize: CGSize = .zero
    var onHover: (Bool) -> Void = { _ in }
    private var hoverArea: NSTrackingArea?
    private(set) var isHovered = false
    var activeRect: NSRect { NSRect(origin: bounds.origin, size: regionSize).intersection(bounds).intersection(visibleRect) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
        CrowHoverRouter.shared.register(self)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let rect = activeRect
        if hoverArea?.rect == rect { return }
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard !rect.isEmpty, !rect.isNull else {
            Task { @MainActor [weak self] in
                guard let self, self.activeRect.isEmpty else { return }
                self.setHovered(false)
            }
            return
        }
        // Representable bounds can be larger than the SwiftUI label; don't use inVisibleRect.
        let area = NSTrackingArea(rect: rect,
            options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    func setHovered(_ value: Bool) {
        guard value != isHovered else { return }
        isHovered = value; onHover(value)
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
}

/// Window-local movement reaches labels even beneath native drag/hit-test overlays.
/// Observe only; never consume an event or read/move the desktop pointer.
@MainActor final class CrowHoverRouter {
    static let shared = CrowHoverRouter()
    private let anchors = NSHashTable<CrowHoverTrackingView>.weakObjects()
    private var monitor: Any?
    func register(_ view: CrowHoverTrackingView) {
        if let window = view.window {
            anchors.add(view)
            window.acceptsMouseMovedEvents = true
        } else { anchors.remove(view) }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.route(event) }
            return event
        }
    }
    private func route(_ event: NSEvent) {
        for anchor in anchors.allObjects {
            anchor.setHovered(event.window != nil && anchor.window === event.window &&
                !anchor.isHiddenOrHasHiddenAncestor &&
                anchor.activeRect.contains(anchor.convert(event.locationInWindow, from: nil)))
        }
    }
}

/// Find/replace is AppKit-owned, so it shares the palette without a SwiftUI wrapper.
final class CrowFindButton: NSButton {
    private(set) var isHovered = false
    private var hoverArea: NSTrackingArea?
    override var isEnabled: Bool { didSet { updateTint() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; updateTint() }
    override func mouseExited(with event: NSEvent) { isHovered = false; updateTint() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
        updateTint()
    }
    func updateTint() {
        let color = NSColor(isEnabled && isHovered ? CrowTheme.accent : CrowTheme.textDim)
            .withAlphaComponent(isEnabled ? 1 : 0.4)
        contentTintColor = color
        attributedTitle = NSAttributedString(string: title,
            attributes: [.font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: color])
    }
}
#endif
