import CrowCore
import SwiftUI

struct TerminalPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var closeTerminalID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            CrowDivider()
            if let id = model.current.snapshot.selectedTerminalID {
                HStack(spacing: 1) {
                    terminal(id)
                    if model.current.snapshot.terminalSplit, sizeClass != .compact,
                       let other = model.current.snapshot.terminalIDs.first(where: { $0 != id }) {
                        terminal(other)
                    }
                }
            } else {
                Button("New Terminal") { model.newTerminal() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if case .imeLab = model.selectedWorkspace.kind {
                IMEInspectorBar(probe: model.imeProbe)
            }
        }
        .background(CrowTheme.bg0)
        .alert("Close this terminal?", isPresented: Binding(get: { closeTerminalID != nil }, set: { if !$0 { closeTerminalID = nil } }), presenting: closeTerminalID) { id in
            Button("Close Terminal", role: .destructive) { model.closeTerminal(id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("The shell and its running commands will be terminated.") }
    }

    private func terminal(_ id: UUID) -> some View {
        let session = model.terminal(id, in: model.current)
        return VStack(spacing: 0) {
            TerminalViewHost(session: session, fontSize: model.settings.terminalFontSize)
                .id(session.instanceID)
                .onAppear { session.start() }
            Text(session.status).font(.system(size: 10)).foregroundStyle(CrowTheme.textDim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(CrowTheme.textDim)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.current.snapshot.terminalIDs.enumerated()), id: \.element) { index, id in
                        Button("\(index + 1)") { model.current.snapshot.selectedTerminalID = id; model.schedulePersist() }
                            .foregroundStyle(id == model.current.snapshot.selectedTerminalID ? CrowTheme.accent : CrowTheme.textDim)
                            .contextMenu { Button("Close Terminal…", role: .destructive) { closeTerminalID = id } }
                    }
                }
            }
            Spacer()
            if model.selectedWorkspace.isRemote {
                Menu {
                    Button("Reconnect") { model.reconnectCurrent() }
                    Button("Disconnect") { model.disconnectCurrent() }
                } label: { Image(systemName: "network") }.fixedSize()
            }
            if sizeClass != .compact {
                Button {
                    if model.current.snapshot.terminalIDs.count < 2 { model.newTerminal() }
                    model.current.snapshot.terminalSplit.toggle(); model.schedulePersist()
                }
                    label: { Image(systemName: "rectangle.split.2x1") }.help("Split Terminal")
            }
            Button { model.newTerminal() } label: { Image(systemName: "plus") }.help("New Terminal")
            Button { closeTerminalID = model.current.snapshot.selectedTerminalID } label: { Image(systemName: "xmark") }
                .help("Close Terminal")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(CrowTheme.bg1)
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
