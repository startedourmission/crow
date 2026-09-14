import CrowCore
import SwiftUI

struct AgentProviderIcon: View {
    let provider: AgentProvider
    var size: CGFloat = 18
    var body: some View {
        Image("Agent-" + provider.rawValue).resizable().renderingMode(.template).scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(provider == .claude ? Color(red: 0.78, green: 0.42, blue: 0.30) : CrowTheme.text)
            .accessibilityLabel(provider == .codex ? "OpenAI Codex" : provider.title)
    }
}
