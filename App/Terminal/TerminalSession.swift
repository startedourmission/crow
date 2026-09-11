import CrowCore
import SwiftUI
import SwiftTerm
@preconcurrency import Citadel
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

// Citadel's immutable writer contains a thread-safe NIO Channel but does not
// declare Sendable. Its async write/resize operations are safe across executors.
private struct RemoteWriter: @unchecked Sendable {
    let value: TTYStdinWriter
}

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Observable
final class TerminalSession: NSObject, Identifiable, @preconcurrency TerminalViewDelegate {
    let id: UUID
    let instanceID = UUID()
    let view: SwiftTerm.TerminalView
    var title = "Terminal"
    var status = "Ready"
    var running = false
    @ObservationIgnored var onBytes: (([UInt8]) -> Void)?
    private let workspace: Workspace
    private let directory: String
    private let remote: RemoteConnection?
    private var started = false
    @ObservationIgnored private var appliedFontSize: Double?
    #if os(macOS)
    var systemSSH: SystemSSHSpec?
    var shellEnvironment: [String]?
    #endif
    private var shellTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var writer: RemoteWriter?

    init(id: UUID, workspace: Workspace, directory: String, remote: RemoteConnection?, fontSize: Double, useSystemSSH: Bool = false) {
        self.id = id; self.workspace = workspace; self.directory = directory; self.remote = remote
        #if os(macOS)
        if workspace.kind == .local || useSystemSSH {
            view = CrowLocalTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        } else { view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 300)) }
        #else
        view = CrowIOSTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        #endif
        super.init()
        view.optionAsMetaKey = false
        setFontSize(fontSize)
        #if os(macOS)
        view.nativeBackgroundColor = NSColor(CrowTheme.bg0)
        view.nativeForegroundColor = NSColor(CrowTheme.text)
        view.caretColor = NSColor(CrowTheme.accent)
        view.selectedTextBackgroundColor = NSColor(CrowTheme.bg3)
        if let local = view as? CrowLocalTerminalView {
            local.processDelegate = self
            local.onInput = { [weak self] in self?.onBytes?($0) }
            return
        }
        #else
        view.backgroundColor = UIColor(CrowTheme.bg0)
        view.nativeBackgroundColor = UIColor(CrowTheme.bg0)
        view.nativeForegroundColor = UIColor(CrowTheme.text)
        view.caretColor = UIColor(CrowTheme.accent)
        view.selectedTextBackgroundColor = UIColor(CrowTheme.bg3)
        #endif
        view.terminalDelegate = self
    }

    func setFontSize(_ size: Double) {
        guard appliedFontSize != size else { return }
        appliedFontSize = size
        #if os(macOS)
        view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #else
        view.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #endif
    }

    func start() {
        guard !started else { return }; started = true
        #if os(macOS)
        if let systemSSH, let local = view as? CrowLocalTerminalView {
            let args = FileManager.default.fileExists(atPath: systemSSH.socket)
                ? systemSSH.multiplexArguments : systemSSH.initialArguments
            // SwiftTerm's default environment drops SSH_AUTH_SOCK and PATH.
            // Preserve the app's inherited agent/proxy environment for OpenSSH.
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
            local.startProcess(executable: "/usr/bin/ssh", args: args,
                environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: systemSSH.directory)
            running = local.process.running; title = systemSSH.host.name; status = "SSH · authenticate in terminal"
            return
        }
        #endif
        switch workspace.kind {
        case .imeLab: break // Legacy snapshots are migrated before creating terminals.
        case .local:
            #if os(macOS)
            guard let local = view as? CrowLocalTerminalView else { return }
            local.startProcess(executable: "/bin/zsh", args: ["-l"], environment: shellEnvironment, currentDirectory: directory)
            running = local.process.running; title = "zsh"; status = running ? "Running" : "Could not start shell"
            #else
            status = "Open Hosts to connect to an SSH server."
            view.feed(text: status + "\r\n")
            #endif
        case .remote:
            guard let client = remote?.client, client.isConnected else {
                status = "Disconnected — use Reconnect to start a shell."
                view.feed(text: status + "\r\n"); return
            }
            status = "Starting SSH shell…"
            let initialDirectory = directory
            shellTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let dims = view.getTerminal().getDims()
                    try await client.withPTY(.init(wantReply: true, term: "xterm-256color",
                        terminalCharacterWidth: dims.cols, terminalRowHeight: dims.rows,
                        terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))) { @Sendable [weak self] inbound, outbound in
                        if initialDirectory != "~" && !initialDirectory.isEmpty {
                            let quoted = "'" + initialDirectory.replacingOccurrences(of: "'", with: "'\\''") + "'"
                            try await outbound.write(ByteBuffer(string: "cd -- \(quoted)\n"))
                        }
                        await self?.connected(RemoteWriter(value: outbound))
                        for try await output in inbound {
                            try Task.checkCancellation()
                            switch output {
                            case .stdout(let bytes), .stderr(let bytes): await self?.receive(Array(bytes.readableBytesView))
                            }
                        }
                    }
                    status = "Shell exited"
                } catch { if !Task.isCancelled { status = "SSH: \(error.localizedDescription)"; view.feed(text: "\r\n\(status)\r\n") } }
                writer = nil; running = false
            }
        }
    }

    func stop() {
        shellTask?.cancel(); shellTask = nil; inputTask?.cancel(); inputTask = nil; writer = nil
        #if os(macOS)
        (view as? LocalProcessTerminalView)?.terminate()
        #endif
        running = false; status = "Closed"
    }

    private func connected(_ writer: RemoteWriter) {
        self.writer = writer; running = true; status = "Connected"
    }
    private func receive(_ bytes: [UInt8]) { view.feed(byteArray: bytes[...]) }

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        onBytes?(Array(data))
        guard let writer else { return }
        let bytes = Array(data), previous = inputTask
        inputTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do { try await writer.value.write(ByteBuffer(bytes: bytes)) }
            catch { self?.status = error.localizedDescription }
        }
    }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        guard let writer else { return }
        Task { try? await writer.value.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0) }
    }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { self.title = title }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
    // Remote escape sequences must not read the system clipboard silently.
    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
}

#if os(iOS)
/// SwiftTerm repairs separately committed Korean finals, but not compound vowels.
/// Use its input buffer so UIKit's context and the PTY receive the same correction.
class CrowIOSTerminalView: SwiftTerm.TerminalView {
    private var regularAccessory: UIView?

    func setPhoneAccessory(_ enabled: Bool) {
        if enabled {
            guard !(inputAccessoryView is CrowPhoneTerminalAccessory) else { return }
            regularAccessory = inputAccessoryView
            inputAccessoryView = CrowPhoneTerminalAccessory(terminal: self)
        } else {
            guard inputAccessoryView is CrowPhoneTerminalAccessory else { return }
            inputAccessoryView = regularAccessory; regularAccessory = nil
        }
        if isFirstResponder { reloadInputViews() }
    }

    override func insertText(_ text: String) {
        guard textInputMode?.primaryLanguage?.hasPrefix("ko") == true,
              !controlModifier, !metaModifier,
              (inputAccessoryView as? TerminalAccessory)?.controlModifier != true,
              markedTextRange == nil,
              let selection = selectedTextRange, selection.isEmpty,
              compare(selection.end, to: endOfDocument) == .orderedSame,
              text.count == 1, let vowel = text.first,
              let previous = position(from: selection.start, offset: -1),
              let range = textRange(from: previous, to: selection.start),
              let base = self.text(in: range)?.last,
              let composed = HangulIME.composeCompoundVowel(base: base, following: vowel) else {
            super.insertText(text)
            return
        }

        // The base has already been committed: replace one character, not two
        // terminal cells. Super also updates UIKit's text and selection ranges.
        super.deleteBackward()
        super.insertText(String(composed))
    }
}

private final class CrowPhoneTerminalAccessory: UIInputView {
    private weak var terminal: CrowIOSTerminalView?
    private weak var controlButton: UIButton?

    init(terminal: CrowIOSTerminalView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: terminal.bounds.width, height: 44), inputViewStyle: .keyboard)
        backgroundColor = UIColor(CrowTheme.bg1)
        let row = UIStackView()
        row.axis = .horizontal; row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        func key(_ title: String, label: String, symbol: String? = nil, action: @escaping @MainActor () -> Void) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(symbol == nil ? title : nil, for: .normal)
            if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center
            button.tintColor = UIColor(CrowTheme.accent)
            button.layer.cornerRadius = 5
            button.accessibilityLabel = label
            button.accessibilityIdentifier = "crow.terminal.key.\(label)"
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            row.addArrangedSubview(button)
            return button
        }
        _ = key("esc", label: "Escape") { [weak terminal] in terminal?.send([0x1b]) }
        _ = key("tab", label: "Tab") { [weak terminal] in terminal?.send([0x09]) }
        controlButton = key("ctrl", label: "Control") { [weak self, weak terminal] in
            terminal?.controlModifier.toggle(); self?.updateControl()
        }
        _ = key("shift\ntab", label: "Shift Tab") { [weak terminal] in terminal?.send([0x1b, 0x5b, 0x5a]) }
        _ = key("◀", label: "Left") { [weak self] in self?.sendArrow(0x44) }
        _ = key("▲", label: "Up") { [weak self] in self?.sendArrow(0x41) }
        _ = key("▼", label: "Down") { [weak self] in self?.sendArrow(0x42) }
        _ = key("▶", label: "Right") { [weak self] in self?.sendArrow(0x43) }
        _ = key("%", label: "Percent") { [weak terminal] in terminal?.insertText("%") }
        _ = key("", label: "Hide Keyboard", symbol: "keyboard.chevron.compact.down") { [weak terminal] in _ = terminal?.resignFirstResponder() }
        NotificationCenter.default.addObserver(self, selector: #selector(updateControl), name: .terminalViewControlModifierReset, object: terminal)
    }

    @objc private func updateControl() {
        let active = terminal?.controlModifier == true
        controlButton?.isSelected = active
        controlButton?.backgroundColor = active ? UIColor(CrowTheme.bg3) : .clear
    }

    private func sendArrow(_ direction: UInt8) {
        guard let terminal else { return }
        terminal.send([0x1b, terminal.getTerminal().applicationCursor ? 0x4f : 0x5b, direction])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
}
#endif

#if os(macOS)
private final class CrowLocalTerminalView: LocalProcessTerminalView {
    var onInput: (@MainActor ([UInt8]) -> Void)?
    override func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { onInput?(Array(data)) }
        super.send(source: source, data: data)
    }
}

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { self.title = title }
    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        running = false; status = "Exited (\(exitCode.map(String.init) ?? "unknown"))"
    }
}
#endif
