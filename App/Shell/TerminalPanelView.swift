import CrowCore
import SwiftUI

struct TerminalPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            header
            CrowDivider()
            TerminalViewHost(workspace: model.selectedWorkspace)
                .background(CrowTheme.bg0)
            if case .imeLab = model.selectedWorkspace.kind {
                IMEInspectorBar(probe: model.imeProbe)
            }
        }
        .background(CrowTheme.bg0)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(CrowTheme.textDim)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CrowTheme.text)
            Spacer()
            Text("\(Int(CrowTheme.terminalFontSize(compact: sizeClass == .compact)))pt")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(CrowTheme.textDim)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(CrowTheme.bg1)
    }

    private var title: String {
        switch model.selectedWorkspace.kind {
        case .imeLab:
            return "IME Lab · echo"
        case .local:
            return "local · echo"
        case .remote:
            return "\(model.selectedWorkspace.name) · echo until SSH"
        }
    }
}

struct IMEInspectorBar: View {
    let probe: IMEProbe

    var body: some View {
        HStack(spacing: 12) {
            Text(probe.isHealthyCommit ? "IME OK" : "JAMO LEAK")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(probe.isHealthyCommit ? CrowTheme.ok : CrowTheme.danger)
            Text(probe.lastUTF8.isEmpty ? "—" : probe.lastUTF8)
                .font(.system(size: 12))
                .foregroundStyle(CrowTheme.text)
                .lineLimit(1)
            Spacer()
            Text("cols \(probe.columns)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(CrowTheme.textDim)
            Text(probe.lastHex.isEmpty ? "" : probe.lastHex)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(CrowTheme.textDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(CrowTheme.bg1)
        .overlay(alignment: .top) {
            Rectangle().fill(CrowTheme.border).frame(height: 1)
        }
    }
}

struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Text(model.workspaceTitle)
                .font(.system(size: 11, weight: .medium))
            if let buffer = model.selectedBuffer {
                Text(buffer.language.label)
                    .foregroundStyle(CrowTheme.textDim)
                if buffer.isDirty {
                    Text("•")
                        .foregroundStyle(CrowTheme.accent)
                }
            }
            Spacer()
            Text(model.statusMessage)
                .foregroundStyle(CrowTheme.textDim)
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(CrowTheme.text)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(CrowTheme.bg1)
        .overlay(alignment: .top) {
            Rectangle().fill(CrowTheme.border).frame(height: 1)
        }
    }
}
