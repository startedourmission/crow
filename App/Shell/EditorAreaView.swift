import CrowCore
import SwiftUI

struct EditorAreaView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            CrowDivider()
            if let buffer = model.selectedBuffer {
                HStack(spacing: 1) {
                    CrowEditorView(buffer: buffer).id(buffer.id)
                    if sizeClass != .compact, let splitID = model.current.snapshot.splitBufferID,
                       let split = model.buffers.first(where: { $0.id == splitID }) {
                        CrowEditorView(buffer: split).id("split-\(split.id.rawValue)")
                    }
                }
            } else {
                emptyState
            }
        }
        .background(CrowTheme.bg0)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.buffers) { buffer in
                    tab(buffer)
                }
            }
        }
        .frame(height: 36)
        .background(CrowTheme.bg1)
    }

    private func tab(_ buffer: OpenBuffer) -> some View {
        let selected = buffer.id == model.selectedBufferID
        return HStack(spacing: 8) {
            Button {
                model.selectedBufferID = buffer.id
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(buffer.isDirty ? CrowTheme.accent : Color.clear)
                        .frame(width: 6, height: 6)
                    Text(buffer.title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                    if buffer.isRemote {
                        Image(systemName: "network")
                            .font(.system(size: 9))
                            .foregroundStyle(CrowTheme.textDim)
                    }
                }
                .foregroundStyle(selected ? CrowTheme.text : CrowTheme.textDim)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if sizeClass != .compact {
                    Button("Open in Split") { model.current.snapshot.splitBufferID = buffer.id; model.schedulePersist() }
                }
            }

            Button {
                model.closeBuffer(buffer.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(CrowTheme.textDim)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(selected ? CrowTheme.bg0 : Color.clear)
        .overlay(alignment: .bottom) {
            if selected {
                Rectangle().fill(CrowTheme.accent).frame(height: 1)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(CrowTheme.textDim)
            Text("Open a file")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CrowTheme.text)
            Text("마크다운만이 아니라 txt, json, conf도 같은 에디터입니다.")
                .font(.system(size: 12))
                .foregroundStyle(CrowTheme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CrowEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let buffer: OpenBuffer
    @State private var previewMarkdown = false
    @State private var findRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(buffer.language.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CrowTheme.textDim)
                if buffer.language == .markdown {
                    Toggle("Preview", isOn: $previewMarkdown)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    Text("Preview")
                        .font(.system(size: 11))
                        .foregroundStyle(CrowTheme.textDim)
                }
                Spacer()
                Button { findRequest += 1 } label: { Image(systemName: "magnifyingglass") }.help("Find and Replace")
                if sizeClass != .compact {
                    Button { model.toggleSplit() } label: { Image(systemName: "rectangle.split.2x1") }.help("Split Editor")
                }
                Button("Save") { Task { await model.saveBuffer(buffer.id) } }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(CrowTheme.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(CrowTheme.bg0)

            if previewMarkdown, buffer.language == .markdown {
                ScrollView {
                    Text(markdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .textSelection(.enabled)
                }
            } else {
                NativeEditor(text: textBinding, fontSize: model.settings.fontSize,
                    indentWidth: model.settings.indentWidth, lineNumbers: model.settings.lineNumbers, findRequest: findRequest,
                    onSave: { Task { await model.saveBuffer(buffer.id) } })
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { model.buffers.first(where: { $0.id == buffer.id })?.text ?? buffer.text },
            set: { model.updateBufferText(buffer.id, $0) }
        )
    }

    private var markdown: AttributedString {
        (try? AttributedString(markdown: buffer.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(buffer.text)
    }
}
