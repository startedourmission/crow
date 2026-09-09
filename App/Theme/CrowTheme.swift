import SwiftUI

enum CrowTheme {
    static let bg0 = Color.white
    static let bg1 = Color(red: 0.97, green: 0.975, blue: 0.985)
    static let bg2 = Color(red: 0.94, green: 0.95, blue: 0.965)
    static let bg3 = Color(red: 0.89, green: 0.915, blue: 0.945)
    static let accent = Color(red: 0.075, green: 0.13, blue: 0.22)
    static let border = accent.opacity(0.12)
    static let text = Color(red: 0.10, green: 0.13, blue: 0.18)
    static let textDim = Color(red: 0.40, green: 0.44, blue: 0.50)
    static let danger = Color(red: 0.72, green: 0.20, blue: 0.18)
    static let ok = Color(red: 0.18, green: 0.44, blue: 0.30)

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
