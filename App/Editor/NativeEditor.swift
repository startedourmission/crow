import SwiftUI
import CrowCore

#if os(macOS)
import AppKit

struct NativeEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let indentWidth: Int
    let lineNumbers: Bool
    let findRequest: Int
    var onSave: () -> Void = {}
    var focused = false
    var locationRequest: EditorLocationRequest?
    var findToggleRequest = 0
    var onFindVisibility: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.clipsToBounds = true
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = CodeTextView()
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.allowsUndo = true; editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.backgroundColor = NSColor(CrowTheme.bg0); editor.textColor = NSColor(CrowTheme.text)
        editor.insertionPointColor = NSColor(CrowTheme.accent)
        editor.string = text; editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("crow.editor")
        scroll.documentView = editor
        scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        scroll.hasVerticalRuler = true
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? CodeTextView else { return }
        context.coordinator.parent = self
        if editor.string != text, !editor.hasMarkedText() {
            let selected = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selected.location, (text as NSString).length), length: 0))
            if scroll.isFindBarVisible { editor.documentFindBar.refreshMatches() }
        }
        if editor.font?.pointSize != CGFloat(fontSize) {
            editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        editor.indentWidth = indentWidth
        editor.onSave = onSave
        editor.documentFindBar.onVisibility = onFindVisibility
        if focused && !context.coordinator.wasFocused {
            Task { @MainActor [weak editor, weak coordinator = context.coordinator] in
                await Task.yield()
                guard coordinator?.parent.focused == true, let editor else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
        context.coordinator.wasFocused = focused
        if let request = locationRequest, context.coordinator.lastLocation != request.id {
            context.coordinator.lastLocation = request.id
            Task { @MainActor [weak editor, weak coordinator = context.coordinator] in
                await Task.yield()
                guard coordinator?.parent.locationRequest?.id == request.id, let editor else { return }
                editor.unmarkText()
                let range = NSRange(location: max(0, min(request.offset, (editor.string as NSString).length)), length: 0)
                editor.setSelectedRange(range)
                editor.scrollRangeToVisible(range)
                editor.window?.makeFirstResponder(editor)
            }
        }
        if scroll.rulersVisible != lineNumbers { scroll.rulersVisible = lineNumbers }
        scroll.verticalRulerView?.needsDisplay = true
        if context.coordinator.lastFind != findRequest {
            context.coordinator.lastFind = findRequest
            let request = findRequest
            Task { @MainActor [weak editor, weak coordinator = context.coordinator] in
                await Task.yield()
                guard coordinator?.parent.findRequest == request, let editor else { return }
                editor.documentFindBar.show()
            }
        }
        if context.coordinator.lastToggle != findToggleRequest {
            context.coordinator.lastToggle = findToggleRequest
            Task { @MainActor [weak editor] in
                await Task.yield()
                editor?.documentFindBar.toggle()
            }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeEditor
        var lastFind: Int
        var wasFocused = false
        var lastLocation: UUID?
        var lastToggle: Int
        init(_ parent: NativeEditor) { self.parent = parent; lastFind = parent.findRequest; lastToggle = parent.findToggleRequest }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string; editor.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            if editor.enclosingScrollView?.isFindBarVisible == true {
                (editor as? CodeTextView)?.documentFindBar.refreshMatches()
            }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? CodeTextView,
                  editor.enclosingScrollView?.isFindBarVisible == true else { return }
            editor.documentFindBar.refreshPosition()
        }
    }
}

final class CodeTextView: NSTextView {
    lazy var documentFindBar = DocumentFindBar(editor: self)
    var indentWidth = 4
    var onSave: (() -> Void)?
    @objc func saveDocument(_ sender: Any?) { onSave?() }
    override func insertTab(_ sender: Any?) {
        let indentation = String(repeating: " ", count: indentWidth)
        if selectedRange().length == 0 { insertText(indentation, replacementRange: selectedRange()); return }
        let source = string as NSString, range = (string as NSString).lineRange(for: selectedRange())
        var lines = source.substring(with: range).components(separatedBy: "\n")
        for index in lines.indices where index < lines.count - 1 || !lines[index].isEmpty { lines[index] = indentation + lines[index] }
        let replacement = lines.joined(separator: "\n")
        insertText(replacement, replacementRange: range)
        setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
    }
    override func insertBacktab(_ sender: Any?) {
        let source = string as NSString
        let range = source.lineRange(for: selectedRange())
        let lines = source.substring(with: range).components(separatedBy: "\n")
        let replacement = lines.map { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.dropFirst(min(indentWidth, line.prefix(while: { $0 == " " }).count)))
        }.joined(separator: "\n")
        insertText(replacement, replacementRange: range)
        setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
    }
    override func insertNewline(_ sender: Any?) {
        let source = string as NSString
        let line = source.substring(with: source.lineRange(for: NSRange(location: selectedRange().location, length: 0)))
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        insertText("\n" + indent, replacementRange: selectedRange())
    }
}

/// Per-editor find/replace controls: no global find pasteboard or private AppKit UI.
final class DocumentFindBar: NSView, NSSearchFieldDelegate {
    weak var editor: CodeTextView?
    let searchField = NSSearchField()
    let replacementField = NSTextField()
    let matchCase = CrowFindButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    let countLabel = NSTextField(labelWithString: "0/0")
    private var ranges: [NSRange] = []
    private var truncated = false
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    private var replaceButton: NSButton!
    private var allButton: NSButton!
    var onVisibility: (Bool) -> Void = { _ in }

    init(editor: CodeTextView) {
        self.editor = editor
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 96))
        searchField.placeholderString = "Find in document"
        replacementField.placeholderString = "Replace with"
        searchField.setAccessibilityIdentifier("crow.document-find")
        replacementField.setAccessibilityIdentifier("crow.document-replacement")
        matchCase.setAccessibilityIdentifier("crow.document-match-case")
        searchField.delegate = self; replacementField.delegate = self
        searchField.sendsSearchStringImmediately = true
        (searchField.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        for field in [searchField as NSTextField, replacementField] {
            field.font = .systemFont(ofSize: 12)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
            let button = CrowFindButton(title: title, target: self, action: action)
            button.controlSize = .small; button.isBordered = false; button.font = .systemFont(ofSize: 11)
            if let symbol {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                button.imagePosition = .imageOnly
            }
            button.toolTip = title
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
            button.updateTint()
            return button
        }
        previousButton = button("Previous Match", #selector(previousMatch), symbol: "chevron.up")
        nextButton = button("Next Match", #selector(nextMatch), symbol: "chevron.down")
        replaceButton = button("Replace", #selector(replaceOne))
        allButton = button("All", #selector(replaceAll)); allButton.toolTip = "Replace All"
        matchCase.target = self; matchCase.action = #selector(caseChanged)
        matchCase.controlSize = .small; matchCase.font = .systemFont(ofSize: 11)
        matchCase.updateTint()
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor(CrowTheme.textDim)
        countLabel.setAccessibilityIdentifier("crow.document-match-position")
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 4; row.alignment = .centerY
            return row
        }
        let rows = [row([searchField, countLabel, previousButton, nextButton]),
                    row([replacementField, replaceButton, allButton]), row([matchCase])]
        let stack = NSStackView(views: rows); stack.orientation = .vertical; stack.spacing = 5; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        ] + rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        wantsLayer = true; layer?.backgroundColor = NSColor(CrowTheme.bg1).cgColor
        refreshMatches()
    }
    required init?(coder: NSCoder) { nil }
    func show() {
        guard let editor, let scroll = editor.enclosingScrollView else { return }
        scroll.findBarView = self; scroll.isFindBarVisible = true
        refreshMatches(); onVisibility(true)
        editor.window?.makeFirstResponder(searchField)
    }
    func toggle() {
        if editor?.enclosingScrollView?.isFindBarVisible == true { closeFind() } else { show() }
    }
    @objc func closeFind() {
        editor?.enclosingScrollView?.isFindBarVisible = false
        onVisibility(false)
        if let editor { editor.window?.makeFirstResponder(editor) }
    }
    func refreshMatches() {
        guard let editor else { return }
        let result = DocumentSearch.matches(in: editor.string, query: searchField.stringValue, matchCase: matchCase.state == .on)
        ranges = result.ranges; truncated = result.truncated
        refreshPosition()
        for button in [previousButton, nextButton, replaceButton] { button?.isEnabled = !ranges.isEmpty }
        allButton?.isEnabled = !ranges.isEmpty && !truncated
    }
    func refreshPosition() {
        let current = editor.flatMap { ranges.firstIndex(of: $0.selectedRange()) }.map { $0 + 1 } ?? 0
        countLabel.stringValue = "\(current)/\(ranges.count)\(truncated ? "+" : "")"
        countLabel.toolTip = truncated ? "More matches exist. Narrow the search to enable Replace All." : "Current match / total matches"
        countLabel.setAccessibilityValue(countLabel.stringValue)
    }
    private func select(_ range: NSRange) {
        editor?.setSelectedRange(range); editor?.scrollRangeToVisible(range)
        editor?.showFindIndicator(for: range)
        refreshPosition()
    }
    @objc func nextMatch() {
        refreshMatches()
        guard let editor, !ranges.isEmpty else { return }
        select(ranges.first { $0.location >= NSMaxRange(editor.selectedRange()) } ?? ranges[0])
    }
    @objc func previousMatch() {
        refreshMatches()
        guard let editor, !ranges.isEmpty else { return }
        select(ranges.last { $0.location < editor.selectedRange().location } ?? ranges.last!)
    }
    @objc func caseChanged() {
        refreshMatches()
        if let selected = editor?.selectedRange(), let range = ranges.first(where: { $0.location >= selected.location }) ?? ranges.first { select(range) }
    }
    @objc func replaceOne() {
        refreshMatches()
        guard let editor, !ranges.isEmpty else { return }
        guard ranges.contains(editor.selectedRange()) else { nextMatch(); return }
        do {
            _ = try DocumentSearch.replacing(editor.string, ranges: [editor.selectedRange()], with: replacementField.stringValue)
            editor.insertText(replacementField.stringValue, replacementRange: editor.selectedRange())
            nextMatch()
        } catch { showReplacementError(error) }
    }
    @objc func replaceAll() {
        refreshMatches()
        guard let editor, !ranges.isEmpty, !truncated else { return }
        do {
            let text = try DocumentSearch.replacing(editor.string, ranges: ranges, with: replacementField.stringValue)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            editor.undoManager?.setActionName("Replace All")
            refreshMatches()
        } catch { showReplacementError(error) }
    }
    private func showReplacementError(_ error: Error) {
        countLabel.stringValue = "!"
        countLabel.toolTip = error.localizedDescription
        countLabel.setAccessibilityValue(error.localizedDescription)
        NSAccessibility.post(element: countLabel, notification: .announcementRequested,
            userInfo: [.announcement: error.localizedDescription, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === searchField,
              (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        caseChanged()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { closeFind(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { previousMatch() } else { nextMatch() }
            return true
        }
        return false
    }
}

final class LineNumberRuler: NSRulerView {
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation); ruleThickness = 48
        clipsToBounds = true
    }
    required init(coder: NSCoder) { super.init(coder: coder); ruleThickness = 48 }
    // Draw only the gutter labels, not NSRulerView's default baseline.
    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor = scrollView?.documentView as? NSTextView,
              let layout = editor.layoutManager, let container = editor.textContainer else { return }
        NSColor(CrowTheme.bg1).setFill(); bounds.fill()
        let source = editor.string as NSString
        let range = layout.glyphRange(forBoundingRect: editor.visibleRect, in: container)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(CrowTheme.textDim)]
        layout.enumerateLineFragments(forGlyphRange: range) { _, used, _, glyphRange, _ in
            let character = layout.characterIndexForGlyph(at: glyphRange.location)
            if character > 0 && source.character(at: character - 1) != 10 { return }
            let number = source.substring(to: character).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let label = String(number) as NSString
            let y = self.convert(NSPoint(x: 0, y: used.minY + editor.textContainerOrigin.y), from: editor).y
            label.draw(at: NSPoint(x: self.ruleThickness - label.size(withAttributes: attributes).width - 8, y: y), withAttributes: attributes)
        }
    }
}

#else
import UIKit

/// Hands keyboard focus between the source and rendered editors once rendering is ready.
@MainActor final class EditorKeyboardFocus {
    private final class Input {
        weak var view: UIView?
        var ready: Bool
        var focus: (() -> Void)?
        init(_ view: UIView, ready: Bool, focus: (() -> Void)?) {
            self.view = view; self.ready = ready; self.focus = focus
        }
    }
    private var inputs: [Bool: Input] = [:]
    private var preview = false
    private weak var transferFrom: UIView?

    func register(_ view: UIView, preview: Bool, ready: Bool = true, focus: (() -> Void)? = nil) {
        inputs[preview] = Input(view, ready: ready, focus: focus)
        finishTransfer()
    }
    func renderedReady(_ ready: Bool) {
        inputs[true]?.ready = ready
        finishTransfer()
    }
    func selectPreview(_ next: Bool) {
        guard next != preview else { return }
        let previous = inputs[preview]?.view
        transferFrom = previous.flatMap { containsFirstResponder($0) ? $0 : nil }
        preview = next
        finishTransfer()
    }
    private func finishTransfer() {
        guard let previous = transferFrom else { return }
        guard containsFirstResponder(previous) else { transferFrom = nil; return }
        guard let input = inputs[preview], input.ready, let view = input.view, view.window != nil else { return }
        transferFrom = nil
        if let focus = input.focus { focus() }
        else { view.becomeFirstResponder() }
    }
    private func containsFirstResponder(_ view: UIView) -> Bool {
        view.isFirstResponder || view.subviews.contains(where: containsFirstResponder)
    }
}

private struct EditorKeyboardFocusKey: EnvironmentKey {
    static let defaultValue: EditorKeyboardFocus? = nil
}
private struct EditorRendererActiveKey: EnvironmentKey { static let defaultValue = true }
private struct EditorRendererPreviewKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var editorKeyboardFocus: EditorKeyboardFocus? {
        get { self[EditorKeyboardFocusKey.self] }
        set { self[EditorKeyboardFocusKey.self] = newValue }
    }
    var editorRendererActive: Bool {
        get { self[EditorRendererActiveKey.self] }
        set { self[EditorRendererActiveKey.self] = newValue }
    }
    var editorRendererPreview: Bool {
        get { self[EditorRendererPreviewKey.self] }
        set { self[EditorRendererPreviewKey.self] = newValue }
    }
}

struct NativeEditor: UIViewRepresentable {
    @Environment(\.keyboardBarItems) private var keyboardBarItems
    @Environment(\.phoneKeyboardFocus) private var keyboard
    @Environment(\.editorKeyboardFocus) private var editorKeyboard
    @Environment(\.editorRendererActive) private var rendererActive
    @Environment(\.editorRendererPreview) private var rendererPreview
    @Binding var text: String
    let fontSize: Double
    let indentWidth: Int
    let lineNumbers: Bool
    let findRequest: Int
    var onSave: () -> Void = {}
    var focused = false
    var locationRequest: EditorLocationRequest?
    var findToggleRequest = 0
    var onFindVisibility: (Bool) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> NumberedTextView {
        let editor = NumberedTextView(usingTextLayoutManager: false)
        editor.text = text; editor.delegate = context.coordinator
        editor.autocorrectionType = .no; editor.autocapitalizationType = .none
        editor.smartQuotesType = .no; editor.smartDashesType = .no; editor.smartInsertDeleteType = .no
        editor.isFindInteractionEnabled = true
        editor.backgroundColor = UIColor(CrowTheme.bg0); editor.textColor = UIColor(CrowTheme.text)
        editor.tintColor = UIColor(CrowTheme.accent); editor.accessibilityIdentifier = "crow.editor"
        updateUIView(editor, context: context)
        return editor
    }
    func updateUIView(_ editor: NumberedTextView, context: Context) {
        if editor.inputAccessoryView == nil {
            let accessory = CrowKeyboardAccessory()
            accessory.onKey = { [weak editor] key in editor?.performKeyboardKey(key) }
            editor.inputAccessoryView = accessory
        }
        (editor.inputAccessoryView as? CrowKeyboardAccessory)?.configure(keyboardBarItems)
        editorKeyboard?.register(editor, preview: rendererPreview)
        if rendererActive { keyboard?.register(editor, surface: .editor) }
        context.coordinator.parent = self
        if editor.text != text && editor.markedTextRange == nil {
            let selected = editor.selectedRange; editor.text = text
            editor.selectedRange = NSRange(location: min(selected.location, (text as NSString).length), length: 0)
        }
        editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        editor.showNumbers = lineNumbers; editor.indentWidth = indentWidth
        editor.onSave = onSave
        editor.textContainerInset = UIEdgeInsets(top: 10, left: lineNumbers ? 44 : 8, bottom: 10, right: 8)
        editor.setNeedsDisplay()
        if let request = locationRequest, context.coordinator.lastLocation != request.id {
            context.coordinator.lastLocation = request.id
            editor.unmarkText()
            editor.selectedRange = NSRange(location: max(0, min(request.offset, (editor.text as NSString).length)), length: 0)
            editor.scrollRangeToVisible(editor.selectedRange)
            editor.becomeFirstResponder()
        }
        if context.coordinator.lastFind != findRequest {
            context.coordinator.lastFind = findRequest
            editor.findInteraction?.presentFindNavigator(showingReplace: true)
        }
        if context.coordinator.lastToggle != findToggleRequest {
            context.coordinator.lastToggle = findToggleRequest
            if editor.findInteraction?.isFindNavigatorVisible == true { editor.findInteraction?.dismissFindNavigator() }
            else { editor.findInteraction?.presentFindNavigator(showingReplace: true) }
        }
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeEditor
        var lastFind: Int
        var lastLocation: UUID?
        var lastToggle = 0
        init(_ parent: NativeEditor) { self.parent = parent; lastFind = parent.findRequest }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text; textView.setNeedsDisplay() }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { scrollView.setNeedsDisplay() }
    }
}

final class NumberedTextView: UITextView, SnippetInput {
    var showNumbers = true
    var indentWidth = 4
    var onSave: (() -> Void)?
    override func insertText(_ text: String) {
        if let key = (inputAccessoryView as? CrowKeyboardAccessory)?.typedKey(text) { performKeyboardKey(key); return }
        super.insertText(text)
    }
    func insertSnippet(_ text: String) {
        (inputAccessoryView as? CrowKeyboardAccessory)?.resetModifiers()
        super.insertText(text)
    }
    func performKeyboardKey(_ key: KeyboardBarKey) {
        if key.control || key.command {
            switch key.key.lowercased() {
            case "a": selectAll(nil); return
            case "c": copy(nil); return
            case "x": cut(nil); return
            case "v": paste(nil); return
            case "z": if key.shift { undoManager?.redo() } else { undoManager?.undo() }; return
            case "s": onSave?(); return
            default: break
            }
        }
        let directions: [String: UITextLayoutDirection] = ["ArrowLeft": .left, "ArrowRight": .right, "ArrowUp": .up, "ArrowDown": .down]
        if let direction = directions[key.key], let selection = selectedTextRange {
            let start = direction == .left || direction == .up ? selection.start : selection.end
            guard let target = position(from: start, in: direction, offset: 1) else { return }
            selectedTextRange = key.shift ? textRange(from: minPosition(selection.start, target), to: maxPosition(selection.end, target)) : textRange(from: target, to: target)
            scrollRangeToVisible(selectedRange); return
        }
        switch key.key {
        case "Escape": findInteraction?.dismissFindNavigator()
        case "Tab":
            if key.shift {
                let source = text as NSString, lines = source.lineRange(for: selectedRange)
                let value = source.substring(with: lines).components(separatedBy: "\n").map { line -> String in
                    if line.hasPrefix("\t") { return String(line.dropFirst()) }
                    return String(line.dropFirst(line.prefix(indentWidth).prefix(while: { $0 == " " }).count))
                }.joined(separator: "\n")
                if let start = position(from: beginningOfDocument, offset: lines.location),
                   let end = position(from: start, offset: lines.length), let range = textRange(from: start, to: end) {
                    replace(range, withText: value); delegate?.textViewDidChange?(self)
                }
            } else { super.insertText(String(repeating: " ", count: indentWidth)) }
        case "Enter": super.insertText("\n")
        case "Backspace": deleteBackward()
        case "Delete":
            if selectedRange.length == 0, let next = position(from: selectedTextRange?.end ?? endOfDocument, offset: 1) {
                selectedTextRange = textRange(from: selectedTextRange?.start ?? endOfDocument, to: next)
            }
            if selectedRange.length > 0 { deleteBackward() }
        case "Home", "End":
            let target = key.key == "Home" ? beginningOfDocument : endOfDocument
            selectedTextRange = key.shift ? textRange(from: minPosition(selectedTextRange?.start ?? target, target), to: maxPosition(selectedTextRange?.end ?? target, target)) : textRange(from: target, to: target)
        case "PageUp", "PageDown":
            let y = contentOffset.y + (key.key == "PageUp" ? -bounds.height : bounds.height)
            setContentOffset(CGPoint(x: contentOffset.x, y: max(0, min(y, contentSize.height - bounds.height))), animated: false)
        default: if !key.control && !key.command { super.insertText(key.shift ? key.key.uppercased() : key.key) }
        }
    }
    private func minPosition(_ a: UITextPosition, _ b: UITextPosition) -> UITextPosition { compare(a, to: b) == .orderedAscending ? a : b }
    private func maxPosition(_ a: UITextPosition, _ b: UITextPosition) -> UITextPosition { compare(a, to: b) == .orderedDescending ? a : b }
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(indent)),
            UIKeyCommand(input: "s", modifierFlags: .command, action: #selector(save))]
    }
    @objc private func indent() { insertText(String(repeating: " ", count: indentWidth)) }
    @objc private func save() { onSave?() }
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard showNumbers else { return }
        let source = text as NSString
        let range = layoutManager.glyphRange(forBoundingRect: bounds, in: textContainer)
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: UIColor(CrowTheme.textDim)]
        layoutManager.enumerateLineFragments(forGlyphRange: range) { _, used, _, glyphRange, _ in
            let character = self.layoutManager.characterIndexForGlyph(at: glyphRange.location)
            if character > 0 && source.character(at: character - 1) != 10 { return }
            let number = source.substring(to: character).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            (String(number) as NSString).draw(at: CGPoint(x: self.contentOffset.x + 6, y: used.minY + self.textContainerInset.top), withAttributes: attributes)
        }
    }
}
#endif
