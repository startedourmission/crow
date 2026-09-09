import SwiftUI

#if os(macOS)
import AppKit

struct NativeEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let indentWidth: Int
    let lineNumbers: Bool
    let findRequest: Int
    var onSave: () -> Void = {}

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
        }
        editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        editor.indentWidth = indentWidth
        editor.onSave = onSave
        scroll.rulersVisible = lineNumbers
        scroll.verticalRulerView?.needsDisplay = true
        if context.coordinator.lastFind != findRequest {
            context.coordinator.lastFind = findRequest
            let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
            editor.performTextFinderAction(item)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeEditor
        var lastFind: Int
        init(_ parent: NativeEditor) { self.parent = parent; lastFind = parent.findRequest }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string; editor.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

final class CodeTextView: NSTextView {
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

struct NativeEditor: UIViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let indentWidth: Int
    let lineNumbers: Bool
    let findRequest: Int
    var onSave: () -> Void = {}
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
        if context.coordinator.lastFind != findRequest {
            context.coordinator.lastFind = findRequest
            editor.findInteraction?.presentFindNavigator(showingReplace: true)
        }
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeEditor
        var lastFind: Int
        init(_ parent: NativeEditor) { self.parent = parent; lastFind = parent.findRequest }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text; textView.setNeedsDisplay() }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { scrollView.setNeedsDisplay() }
    }
}

final class NumberedTextView: UITextView {
    var showNumbers = true
    var indentWidth = 4
    var onSave: (() -> Void)?
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
