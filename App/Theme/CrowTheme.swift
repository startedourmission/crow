import SwiftUI

enum CrowTheme {
    static let bg0 = Color(red: 0.09, green: 0.09, blue: 0.095)
    static let bg1 = Color(red: 0.125, green: 0.125, blue: 0.13)
    static let bg2 = Color(red: 0.16, green: 0.16, blue: 0.165)
    static let bg3 = Color(red: 0.20, green: 0.20, blue: 0.205)
    static let border = Color.white.opacity(0.08)
    static let accent = Color(red: 0.90, green: 0.62, blue: 0.28)
    static let text = Color(red: 0.93, green: 0.92, blue: 0.90)
    static let textDim = Color(red: 0.58, green: 0.57, blue: 0.55)
    static let danger = Color(red: 0.86, green: 0.38, blue: 0.32)
    static let ok = Color(red: 0.45, green: 0.72, blue: 0.48)

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
