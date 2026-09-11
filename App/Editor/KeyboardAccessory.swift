#if os(iOS)
import CrowCore
import UIKit
import WebKit
import SwiftUI

@MainActor protocol SnippetInput: AnyObject { func insertSnippet(_ text: String) }

private struct KeyboardBarItemsKey: EnvironmentKey {
    static let defaultValue = KeyboardBarKey.defaults
}
extension EnvironmentValues {
    var keyboardBarItems: [KeyboardBarKey] {
        get { self[KeyboardBarItemsKey.self] }
        set { self[KeyboardBarItemsKey.self] = newValue }
    }
}

final class CrowKeyboardAccessory: UIInputView {
    private let scroll = UIScrollView()
    private let row = UIStackView()
    private var items: [KeyboardBarKey] = []
    private var buttons: [UIButton] = []
    private(set) var control = false
    private(set) var shift = false
    var onKey: ((KeyboardBarKey) -> Void)?
    var onModifiersChanged: ((Bool, Bool) -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 44), inputViewStyle: .keyboard)
        backgroundColor = UIColor(CrowTheme.bg1)
        scroll.showsHorizontalScrollIndicator = false; scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        row.axis = .horizontal; row.spacing = 2; row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        configure(KeyboardBarKey.defaults)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ keys: [KeyboardBarKey]) {
        guard items != keys else { return }
        items = keys
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }; buttons = []
        for key in keys {
            let button = UIButton(type: .system)
            button.setTitle(key.label, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            button.tintColor = UIColor(CrowTheme.accent); button.layer.cornerRadius = 5
            button.widthAnchor.constraint(equalToConstant: max(42, CGFloat(key.label.count) * 7 + 12)).isActive = true
            button.accessibilityLabel = key.label
            button.accessibilityIdentifier = "crow.keyboard.key.\(key.label)"
            button.addAction(UIAction { [weak self] _ in self?.press(key) }, for: .touchUpInside)
            row.addArrangedSubview(button); buttons.append(button)
        }
        updateHighlights()
    }
    func press(_ key: KeyboardBarKey) {
        if key.key == "Control" { control.toggle(); updateHighlights(); onModifiersChanged?(control, shift); return }
        if key.key == "Shift" { shift.toggle(); updateHighlights(); onModifiersChanged?(control, shift); return }
        var combined = key; combined.control = key.control || control; combined.shift = key.shift || shift
        resetModifiers(); onKey?(combined)
    }
    func typedKey(_ text: String) -> KeyboardBarKey? {
        guard control || shift else { return nil }
        let key = KeyboardBarKey(key: text, control: control, shift: shift)
        resetModifiers(); return key
    }
    func resetModifiers() {
        control = false; shift = false; updateHighlights(); onModifiersChanged?(false, false)
    }
    private func updateHighlights() {
        for (index, button) in buttons.enumerated() {
            let selected = (items[index].key == "Control" && control) || (items[index].key == "Shift" && shift)
            button.isSelected = selected; button.backgroundColor = selected ? UIColor(CrowTheme.bg3) : .clear
        }
    }
}

final class CrowMarkdownWebView: WKWebView, SnippetInput {
    let keyboardAccessory = CrowKeyboardAccessory()
    override var inputAccessoryView: UIView? { keyboardAccessory }
    func configureKeyboard(_ items: [KeyboardBarKey]) {
        keyboardAccessory.configure(items)
        keyboardAccessory.onKey = { [weak self] in self?.performKeyboardKey($0) }
        keyboardAccessory.onModifiersChanged = { [weak self] control, shift in
            self?.callAsyncJavaScript("window.crowMarkdown.setModifiers(control, shift)", arguments: ["control": control, "shift": shift], in: nil, in: .defaultClient)
        }
    }
    func insertSnippet(_ text: String) {
        keyboardAccessory.resetModifiers()
        callAsyncJavaScript("window.crowMarkdown.insertText(text)", arguments: ["text": text], in: nil, in: .defaultClient)
    }
    private func performKeyboardKey(_ key: KeyboardBarKey) {
        if (key.control || key.command), key.key.lowercased() == "v" {
            if let text = UIPasteboard.general.string { insertSnippet(text) }
            return
        }
        if (key.control || key.command), ["c", "x"].contains(key.key.lowercased()) {
            callAsyncJavaScript("window.getSelection().toString()", in: nil, in: .defaultClient) { [weak self] result in
                if case .success(let value) = result, let text = value as? String { UIPasteboard.general.string = text }
                if key.key.lowercased() == "x" { self?.sendKey(KeyboardBarKey(key: "Backspace")) }
            }
            return
        }
        sendKey(key)
    }
    private func sendKey(_ key: KeyboardBarKey) {
        callAsyncJavaScript("window.crowMarkdown.key(key)", arguments: ["key": ["key": key.key,
            "control": key.control, "shift": key.shift, "option": key.option, "command": key.command]], in: nil, in: .defaultClient)
    }
}
#endif
