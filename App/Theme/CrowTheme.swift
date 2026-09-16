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
    static let sidebarWidth: CGFloat = 300
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

/// Shared layout for action popovers, with room for status and inline controls.
struct CrowPopupPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(CrowTheme.textDim)
                .lineLimit(1).truncationMode(.middle).padding(.horizontal, 8).padding(.vertical, 5)
            content
        }.padding(5).frame(width: 240).background(CrowTheme.bg0)
            .foregroundStyle(CrowTheme.text).clipShape(RoundedRectangle(cornerRadius: 12))
            .windowDragExcluded().presentationCompactAdaptation(.popover)
    }
}

struct CrowPopupAction: View {
    let title: String
    let symbol: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(role == .destructive ? CrowTheme.danger : CrowTheme.textDim)
                Text(title)
                Spacer(minLength: 0)
            }
        }.buttonStyle(CrowPopupButtonStyle())
    }
}

struct CrowPopupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PopupButtonBody(configuration: configuration)
    }

    private struct PopupButtonBody: View {
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label.font(.system(size: 12))
                .foregroundStyle(configuration.role == .destructive ? CrowTheme.danger : CrowTheme.text)
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4)
                .background(enabled && (hovered || configuration.isPressed) ? CrowTheme.bg2 : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? 1 : 0.4).contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

private struct CrowMenuDismissKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var crowMenuDismiss: (@MainActor () -> Void)? {
        get { self[CrowMenuDismissKey.self] }
        set { self[CrowMenuDismissKey.self] = newValue }
    }
}

/// Action menus share the compact popover appearance, including nested menus.
struct CrowMenu<Label: View, Content: View>: View {
    @Environment(\.crowMenuDismiss) private var dismissParent
    @State private var presented = false
    private let content: Content
    private let label: Label

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content(); self.label = label()
    }

    init(_ title: String, @ViewBuilder content: () -> Content) where Label == Text {
        self.content = content(); self.label = Text(title)
    }

    var body: some View {
        Group {
            if dismissParent != nil {
                Button { presented.toggle() } label: {
                    HStack(spacing: 8) {
                        label
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 9))
                    }
                }.buttonStyle(CrowPopupButtonStyle())
            } else {
                Button { presented.toggle() } label: { label }.buttonStyle(CrowButtonStyle())
            }
        }
        .popover(isPresented: $presented, arrowEdge: dismissParent == nil ? .bottom : .trailing) {
            CrowActionMenuContent {
                presented = false; dismissParent?()
            } content: { content }
        }
        .windowDragExcluded()
    }
}

struct CrowActionMenuContent<Content: View>: View {
    let dismiss: @MainActor () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        ViewThatFits(in: .vertical) {
            rows
            ScrollView { rows }
        }
        .frame(width: 240).frame(maxHeight: 440).fixedSize(horizontal: false, vertical: true)
        .background(CrowTheme.bg0).foregroundStyle(CrowTheme.text)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .environment(\.crowMenuDismiss, dismiss)
        .buttonStyle(CrowMenuActionStyle())
        .toggleStyle(CrowMenuToggleStyle())
        .labelStyle(.titleAndIcon).font(.system(size: 12))
        .presentationCompactAdaptation(.popover)
        #if os(macOS)
        .onExitCommand(perform: dismiss)
        #else
        .onKeyPress(.escape) { dismiss(); return .handled }
        #endif
        .windowDragExcluded()
    }
    private var rows: some View {
        VStack(alignment: .leading, spacing: 1) { content }.padding(5)
    }
}

struct CrowChoiceMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [(String, Value)]
    var showTitle = true
    @Environment(\.crowMenuDismiss) private var dismissParent

    var body: some View {
        CrowMenu {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                Button { selection = choice.1 } label: {
                    HStack(spacing: 8) {
                        Text(choice.0)
                        Spacer(minLength: 0)
                        if selection == choice.1 { Image(systemName: "checkmark").font(.system(size: 10)) }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if showTitle { Text(title).foregroundStyle(CrowTheme.textDim) }
                Text(choices.first { $0.1 == selection }?.0 ?? "Select…").lineLimit(1)
                if dismissParent == nil { Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)) }
            }.padding(.vertical, 3).contentShape(Rectangle())
        }.accessibilityLabel(title)
    }
}

/// Closing before triggering also dismisses the parent of a submenu action.
private struct CrowMenuActionStyle: PrimitiveButtonStyle {
    @Environment(\.crowMenuDismiss) private var dismiss
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            dismiss?(); configuration.trigger()
        } label: { configuration.label }
        .buttonStyle(CrowPopupButtonStyle())
    }
}

private struct CrowMenuToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Spacer(minLength: 0)
            Toggle(isOn: configuration.$isOn) { configuration.label }.labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }.padding(.horizontal, 8).padding(.vertical, 4)
    }
}

extension View {
    func crowContextMenu<MenuContent: View>(@ViewBuilder content: () -> MenuContent) -> some View {
        modifier(CrowContextMenuModifier(menu: content()))
    }
}

private struct CrowContextMenuModifier<MenuContent: View>: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var presented = false
    @State private var location: CGPoint = .zero
    let menu: MenuContent
    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .background {
                GeometryReader { geometry in
                    CrowContextMenuAnchor(size: geometry.size, enabled: enabled) { point in
                        location = point; presented = true
                    }
                }.allowsHitTesting(false)
            }
            #else
            .onLongPressGesture { if enabled { presented = true } }
            #endif
            .accessibilityAction(named: Text("Show actions")) { if enabled { presented = true } }
            .popover(isPresented: $presented, attachmentAnchor: .rect(.rect(CGRect(origin: location, size: CGSize(width: 1, height: 1)))), arrowEdge: .bottom) {
                CrowActionMenuContent(dismiss: { presented = false }) { menu }
            }
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

private struct CrowContextMenuAnchor: NSViewRepresentable {
    let size: CGSize
    let enabled: Bool
    let present: (CGPoint) -> Void
    func makeNSView(context: Context) -> CrowContextMenuAnchorView { CrowContextMenuAnchorView() }
    func updateNSView(_ view: CrowContextMenuAnchorView, context: Context) {
        view.regionSize = size; view.menuEnabled = enabled; view.present = present
    }
}

final class CrowContextMenuAnchorView: NSView {
    var regionSize: CGSize = .zero
    var menuEnabled = true
    var present: (CGPoint) -> Void = { _ in }
    override var isFlipped: Bool { true }
    var activeRect: NSRect { NSRect(origin: bounds.origin, size: regionSize).intersection(bounds).intersection(visibleRect) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        CrowContextMenuRouter.shared.register(self)
    }
}

/// Local secondary clicks only. Native file/tab drag overlays keep normal clicks
/// and drags; a row's context menu wins over its enclosing list's menu.
@MainActor final class CrowContextMenuRouter {
    static let shared = CrowContextMenuRouter()
    private let anchors = NSHashTable<CrowContextMenuAnchorView>.weakObjects()
    private var monitor: Any?
    func register(_ view: CrowContextMenuAnchorView) {
        if view.window != nil { anchors.add(view) } else { anchors.remove(view) }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.route(event) == true }
            return consumed ? nil : event
        }
    }
    @discardableResult func route(_ event: NSEvent) -> Bool {
        guard event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
              let window = event.window, window.attachedSheet == nil else { return false }
        let candidates = anchors.allObjects.filter {
            $0.window === window && $0.menuEnabled && !$0.isHiddenOrHasHiddenAncestor &&
                $0.activeRect.contains($0.convert(event.locationInWindow, from: nil))
        }
        guard let anchor = candidates.min(by: { $0.activeRect.width * $0.activeRect.height < $1.activeRect.width * $1.activeRect.height }) else { return false }
        anchor.present(anchor.convert(event.locationInWindow, from: nil))
        return true
    }
}

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
