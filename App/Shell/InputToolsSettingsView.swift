import CrowCore
import SwiftUI

struct KeyboardBarSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    var body: some View {
        List {
            Section {
                ForEach(model.settings.effectiveKeyboardBarItems) { item in
                    Text(item.label).font(.system(.body, design: .monospaced))
                        .contextMenu { Button("Delete", role: .destructive) { model.settings.keyboardBarItems = model.settings.effectiveKeyboardBarItems.filter { $0.id != item.id } } }
                }
                .onDelete { offsets in
                    var items = model.settings.effectiveKeyboardBarItems; items.remove(atOffsets: offsets); model.settings.keyboardBarItems = items
                }
                .onMove { source, target in
                    var items = model.settings.effectiveKeyboardBarItems; items.move(fromOffsets: source, toOffset: target); model.settings.keyboardBarItems = items
                }
            } footer: { Text("The same scrolling key bar appears in Terminal and Editor. Ctrl and Shift apply to the next key.") }
            Button("Add Key or Combination…") { adding = true }
            Button("Restore Default Keys") { model.settings.keyboardBarItems = nil }
        }
        .navigationTitle("Keyboard Bar")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
        .sheet(isPresented: $adding) { KeyboardBarKeyEditor { key in model.settings.keyboardBarItems = model.settings.effectiveKeyboardBarItems + [key] } }
    }
}

private struct KeyboardBarKeyEditor: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (KeyboardBarKey) -> Void
    @State private var selected = "Tab"
    @State private var character = ""
    @State private var control = false
    @State private var shift = false
    @State private var option = false
    @State private var command = false
    var body: some View {
        NavigationStack {
            Form {
                Picker("Key", selection: $selected) {
                    ForEach(KeyboardBarKey.specialKeys, id: \.self) { Text($0).tag($0) }
                    Text("Character").tag("Character")
                }
                if selected == "Character" { TextField("Character", text: $character).autocorrectionDisabled() }
                if selected != "Control" && selected != "Shift" {
                    Toggle("Ctrl", isOn: $control)
                    Toggle("Shift", isOn: $shift)
                    Toggle("Alt / Option", isOn: $option)
                    Toggle("Command", isOn: $command)
                }
                Text("For Shift+Tab, choose Tab and enable Shift.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            .navigationTitle("Add Keyboard Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let modifierKey = selected == "Control" || selected == "Shift"
                        onSave(KeyboardBarKey(key: selected == "Character" ? character : selected,
                            control: !modifierKey && control, shift: !modifierKey && shift, option: !modifierKey && option, command: !modifierKey && command))
                        dismiss()
                    }.disabled(selected == "Character" && (character.count != 1 || character.contains(where: { $0.isNewline })))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 380)
        #endif
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
                TextEditor(text: $snippet.text).font(.system(.body, design: .monospaced)).frame(minHeight: 220)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Text("Inserts exactly this text without adding Enter.").font(.caption).foregroundStyle(.secondary)
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
        .frame(minWidth: 380, minHeight: 400)
        #endif
    }
}
