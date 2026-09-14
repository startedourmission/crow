import CrowCore
import SwiftUI
#if os(iOS)
import UIKit
import WebKit

@MainActor final class IOSSnippetTarget {
    private weak var view: UIView?
    private var selection: NSRange?

    init?(responder: UIView?) {
        var current = responder
        while let candidate = current {
            if candidate is any SnippetInput {
                view = candidate
                selection = (candidate as? UITextView)?.selectedRange
                return
            }
            current = candidate.superview
        }
        return nil
    }

    static func capture(in root: UIView) -> IOSSnippetTarget? {
        if root.isFirstResponder { return IOSSnippetTarget(responder: root) }
        for child in root.subviews {
            if let target = capture(in: child) { return target }
        }
        return nil
    }

    var available: Bool { view?.window != nil }

    func insert(_ text: String) {
        guard let view, view.window != nil, let input = view as? any SnippetInput else { return }
        if let editor = view as? UITextView, let selection {
            let count = (editor.text as NSString).length
            let start = min(selection.location, count)
            editor.selectedRange = NSRange(location: start, length: min(selection.length, count - start))
        }
        input.insertSnippet(text)
    }

    func restoreFocus() {
        guard let view, view.window != nil else { return }
        view.becomeFirstResponder()
        if let web = view as? WKWebView {
            web.evaluateJavaScript("document.querySelector('[contenteditable=true]')?.focus()", in: nil, in: .defaultClient)
        }
    }
}

private struct SnippetWindowAnchor: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view.isUserInteractionEnabled = false; return view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct IPadSnippetButton: View {
    @Environment(AppModel.self) private var model
    @State private var anchor = UIView()
    @State private var showing = false
    @State private var target: IOSSnippetTarget?

    var body: some View {
        Button {
            target = anchor.window.flatMap { IOSSnippetTarget.capture(in: $0) }
            showing = true
        } label: {
            Image(systemName: "text.badge.plus").font(.system(size: 18))
                .crowForeground(CrowTheme.textDim).frame(width: CrowTheme.activityWidth, height: 40)
        }
        .buttonStyle(CrowButtonStyle())
        .background(SnippetWindowAnchor(view: anchor))
        .help("Snippets").accessibilityLabel("Snippets").accessibilityIdentifier("crow.ipad.snippets")
        .popover(isPresented: $showing) {
            SnippetsView(onInsert: target?.available == true ? { target?.insert($0) } : nil)
                .environment(model).frame(width: 380, height: 440)
        }
        .onChange(of: showing) { _, visible in
            if !visible { target?.restoreFocus(); target = nil }
        }
    }
}
#endif
#if os(macOS)
import AppKit
import SwiftTerm
import WebKit

@MainActor final class MacSnippetTarget {
    private weak var view: NSView?
    private var selection: NSRange?
    init?(responder: NSResponder?) {
        var current = responder
        while let candidate = current {
            if let editor = candidate as? CodeTextView {
                view = editor; selection = editor.selectedRange(); return
            }
            if let terminal = candidate as? SwiftTerm.TerminalView { view = terminal; return }
            if let web = candidate as? WKWebView { view = web; return }
            current = candidate.nextResponder
        }
        return nil
    }
    var available: Bool { view?.window != nil }
    func insert(_ text: String) {
        guard let view, view.window != nil else { return }
        if let editor = view as? CodeTextView, let selection {
            let count = (editor.string as NSString).length
            let start = min(selection.location, count)
            editor.insertText(text, replacementRange: NSRange(location: start, length: min(selection.length, count - start)))
        } else if let terminal = view as? SwiftTerm.TerminalView {
            terminal.pasteLiteralText(text)
        } else if let web = view as? WKWebView {
            web.callAsyncJavaScript("window.crowMarkdown.insertText(text)", arguments: ["text": text], in: nil, in: .defaultClient)
        }
    }
    func restoreFocus() {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
        if let web = view as? WKWebView {
            web.evaluateJavaScript("document.querySelector('[contenteditable=true]')?.focus()", in: nil, in: .defaultClient)
        }
    }
}

struct MacSnippetButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.crowFloatingMode) private var floating
    @State private var showing = false
    @State private var target: MacSnippetTarget?
    var width: CGFloat = 32
    var height: CGFloat = 36
    var body: some View {
        Button {
            target = floating.wrappedValue && (model.compactSurface == .files || model.compactSurface == .hosts)
                ? nil : MacSnippetTarget(responder: NSApp.keyWindow?.firstResponder)
            showing = true
        } label: {
            Image(systemName: "text.badge.plus").font(.system(size: 18))
                .crowForeground(CrowTheme.textDim).frame(width: width, height: height)
        }
        .buttonStyle(CrowButtonStyle()).windowDragExcluded()
        .help("Snippets").accessibilityLabel("Snippets").accessibilityIdentifier("crow.mac.snippets")
        .popover(isPresented: $showing) {
            SnippetsView(onInsert: target?.available == true ? { target?.insert($0) } : nil)
                .environment(model).frame(width: 380, height: 440)
        }
        .onChange(of: showing) { _, visible in
            if !visible { target?.restoreFocus(); target = nil }
        }
    }
}
#endif

struct KeyboardBarDraft {
    var key: String?
    var character = ""
    var control = false
    var shift = false
    var option = false
    var command = false

    mutating func tap(_ name: String) {
        switch name {
        case "Control": control.toggle()
        case "Shift": shift.toggle()
        case "Alt": option.toggle()
        case "Command": command.toggle()
        default: key = key == name ? nil : name
        }
    }
    func selected(_ name: String) -> Bool {
        switch name {
        case "Control": control
        case "Shift": shift
        case "Alt": option
        case "Command": command
        default: key == name
        }
    }
    var item: KeyboardBarKey? {
        if let key {
            let value = key == "Character" ? character : key
            guard key != "Character" || (value.count == 1 && !value.contains(where: { $0.isNewline })) else { return nil }
            return KeyboardBarKey(key: value, control: control, shift: shift, option: option, command: command)
        }
        if control && !shift && !option && !command { return KeyboardBarKey(key: "Control") }
        if shift && !control && !option && !command { return KeyboardBarKey(key: "Shift") }
        return nil
    }
    var preview: String {
        if let item { return item.label }
        let modifiers = [(control, "ctrl"), (shift, "shift"), (option, "alt"), (command, "cmd")]
            .filter { $0.0 }.map { $0.1 }
        return modifiers.isEmpty ? "Choose keys below" : modifiers.joined(separator: "+") + "+…"
    }
}

struct KeyboardBarSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = KeyboardBarDraft()
    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 8)]
    var body: some View {
        List {
            Section("Current Keys") {
                if model.settings.effectiveKeyboardBarItems.isEmpty {
                    Text("No keys added").foregroundStyle(.secondary)
                }
                ForEach(model.settings.effectiveKeyboardBarItems) { item in
                    HStack {
                        Text(item.label).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            model.settings.keyboardBarItems = model.settings.effectiveKeyboardBarItems.filter { $0.id != item.id }
                        } label: { Image(systemName: "minus.circle.fill").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel("Delete " + item.label)
                            .accessibilityIdentifier("crow.keyboard.delete." + item.id.uuidString)
                    }
                }
                .onMove { source, target in
                    var items = model.settings.effectiveKeyboardBarItems
                    items.move(fromOffsets: source, toOffset: target); model.settings.keyboardBarItems = items
                }
            }
            Section {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(["Control", "Shift", "Alt", "Command"], id: \.self) { keyButton($0) }
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(KeyboardBarKey.specialKeys.filter { $0 != "Control" && $0 != "Shift" } + ["Character"], id: \.self) { keyButton($0) }
                }
                if draft.key == "Character" {
                    TextField("Character", text: $draft.character).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                HStack {
                    Text(draft.preview).font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("crow.keyboard.combination")
                    Spacer()
                    Button("Add") {
                        guard let item = draft.item else { return }
                        model.settings.keyboardBarItems = model.settings.effectiveKeyboardBarItems + [item]
                        draft = KeyboardBarDraft()
                    }.buttonStyle(CrowButtonStyle(kind: .filled)).disabled(draft.item == nil)
                        .accessibilityIdentifier("crow.keyboard.add")
                }
            } header: { Text("Add Key or Combination") }
              footer: { Text("Tap Shift, then Tab, then Add for Shift+Tab. Add Ctrl or Shift alone to use it with the next key. The same bar appears in Terminal and Editor.") }
            Button("Restore Default Keys") { model.settings.keyboardBarItems = nil }
        }
        .navigationTitle("Keyboard Bar")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }
    private func keyButton(_ name: String) -> some View {
        let selected = draft.selected(name)
        let label = name == "Character" ? "abc" : name == "Alt" ? "alt" : name == "Command" ? "cmd" : KeyboardBarKey(key: name).label
        return Button { draft.tap(name) } label: {
            Text(label).font(.system(size: 14, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? CrowTheme.accent : CrowTheme.text)
                .background(selected ? CrowTheme.bg3 : CrowTheme.bg2, in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? CrowTheme.accent : .clear, lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityLabel(name)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("crow.keyboard.choose." + name)
    }
}

struct SnippetsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onInsert: ((String) -> Void)?
    @State private var editing: TextSnippet?
    var body: some View {
        NavigationStack {
            List {
                if (model.settings.textSnippets ?? []).isEmpty {
                    ContentUnavailableView("No Snippets", systemImage: "text.badge.plus", description: Text("Save text here, then tap it to insert at the cursor. No Enter is added."))
                }
                ForEach(model.settings.textSnippets ?? []) { snippet in
                    HStack {
                        Button {
                            if let onInsert { onInsert(snippet.text); dismiss() } else { editing = snippet }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snippet.name).fontWeight(.medium)
                                Text(snippet.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu {
                            Button("Edit") { editing = snippet }
                            Button("Delete", role: .destructive) { model.settings.textSnippets?.removeAll { $0.id == snippet.id } }
                        } label: { Image(systemName: "ellipsis").frame(width: 36, height: 44) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden)
                            .buttonStyle(.plain).fixedSize()
                            .accessibilityLabel("Options for " + snippet.name)
                    }
                }
                .onDelete { offsets in model.settings.textSnippets?.remove(atOffsets: offsets) }
                .onMove { source, target in model.settings.textSnippets?.move(fromOffsets: source, toOffset: target) }
            }
            .navigationTitle("Snippets")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { editing = TextSnippet(name: "", text: "") } label: { Label("Add Snippet", systemImage: "plus") } }
            }
            .sheet(item: $editing) { snippet in
                SnippetEditor(snippet: snippet) { updated in
                    var snippets = model.settings.textSnippets ?? []
                    if let index = snippets.firstIndex(where: { $0.id == updated.id }) { snippets[index] = updated } else { snippets.append(updated) }
                    model.settings.textSnippets = snippets
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}

private struct SnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var snippet: TextSnippet
    var onSave: (TextSnippet) -> Void
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $snippet.name)
                Section {
                    TextEditor(text: $snippet.text).font(.system(.body, design: .monospaced)).frame(minHeight: 220)
                        .autocorrectionDisabled().accessibilityLabel("Snippet Text")
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: { Text("Text") }
                  footer: { Text("Inserts exactly this text without adding Enter.") }
                Section {
                    TextEditor(text: $snippet.memo).font(.body).frame(minHeight: 100)
                        .accessibilityLabel("Memo").accessibilityIdentifier("crow.snippet.memo")
                } header: { Text("Memo") }
                  footer: { Text("Notes for this snippet. Not included when inserting text.") }
            }.formStyle(.grouped)
            .navigationTitle("Edit Snippet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { snippet.name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines); onSave(snippet); dismiss() }
                        .disabled(snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || snippet.text.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 520)
        #endif
    }
}

#if os(iOS)
struct WorkspaceTabsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Documents", count: model.buffers.count)
                    if model.buffers.isEmpty { Text("No Open Documents").font(.callout).foregroundStyle(CrowTheme.textDim) }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.buffers) { buffer in
                            Button {
                                model.selectedBufferID = buffer.id; model.compactSurface = .editor; dismiss()
                            } label: {
                                card(title: buffer.title, subtitle: buffer.isDirty ? "Unsaved changes" : buffer.language.label,
                                    symbol: "doc.text", selected: model.compactSurface == .editor && model.selectedBufferID == buffer.id,
                                    dirty: buffer.isDirty)
                            }.accessibilityIdentifier("crow.tabs.document." + buffer.id.rawValue.uuidString)
                        }
                    }
                    sectionTitle("Terminals", count: model.current.snapshot.terminalIDs.count).padding(.top, 12)
                    if model.current.snapshot.terminalIDs.isEmpty { Text("No Open Terminals").font(.callout).foregroundStyle(CrowTheme.textDim) }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(model.current.snapshot.terminalIDs.enumerated()), id: \.element) { index, id in
                            Button {
                                model.current.snapshot.selectedTerminalID = id; model.compactSurface = .terminal
                                model.schedulePersist(); dismiss()
                            } label: {
                                card(title: "Terminal \(index + 1)", subtitle: model.current.terminals[id]?.title ?? model.workspaceTitle,
                                    symbol: "terminal", selected: model.compactSurface == .terminal && model.current.snapshot.selectedTerminalID == id)
                            }.accessibilityIdentifier("crow.tabs.terminal." + id.uuidString)
                        }
                    }
                }.padding(16)
            }
            .background(CrowTheme.bg0).buttonStyle(.plain)
            .navigationTitle("Open Tabs").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(CrowTheme.text)
            Text(String(count)).font(.subheadline).foregroundStyle(CrowTheme.textDim)
        }
    }
    private func card(title: String, subtitle: String, symbol: String, selected: Bool, dirty: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(CrowTheme.accent)
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(CrowTheme.accent) }
                else if dirty { Circle().fill(CrowTheme.accent).frame(width: 6, height: 6) }
            }
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(CrowTheme.text).lineLimit(2)
            Text(subtitle).font(.caption).foregroundStyle(CrowTheme.textDim).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading).padding(12)
        .background(CrowTheme.bg1, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? CrowTheme.accent : CrowTheme.border, lineWidth: 1) }
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
#endif
