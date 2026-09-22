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

enum TerminalInputCapture {
    /// The program that turned tracking on has exited back to a local shell.
    static let applicationRelease = "\u{1b}[?9l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?1004l\u{1b}[?1l\u{1b}[>0s\u{1b}[=0;1u\u{1b}[<100u"
    /// Any-motion tracking only. Button tracking (tmux) stays in place.
    static let hoverRelease = "\u{1b}[?1003l\u{1b}[?1004l"

    enum Action: Equatable { case none, hover, application }

    enum Foreground: Equatable { case shell, child, unknown }

    static func action(mouse: SwiftTerm.Terminal.MouseMode, foreground: Foreground, prompted: Bool) -> Action {
        if mouse != .off, foreground == .shell { return .application }
        // A remote prompt cannot see the process group. A local child still
        // owns the terminal, so its own directory report must not cancel tracking.
        if mouse == .anyEvent, prompted, foreground != .child { return .hover }
        return .none
    }
}

@MainActor @Observable
final class TerminalSession: NSObject, Identifiable, @preconcurrency TerminalViewDelegate {
    let id: UUID
    let instanceID = UUID()
    let view: SwiftTerm.TerminalView
    var title = "Terminal"
    var status = "Ready"
    var running = false
    var launchCommand: String?
    var startupUnavailableMessage: String?
    @ObservationIgnored var onStop: (() -> Void)?
    var tmuxLocation: TmuxLocation? {
        didSet { if oldValue != tmuxLocation { tmuxCurrentDirectory = nil } }
    }
    var tmuxCurrentDirectory: String?
    var tmuxReverseAgents: [String: AgentTerminal] = [:]
    var tmuxAgentLaunching = false
    var workingDirectory: String { currentDirectory ?? directory }
    var agentProvider: AgentProvider?
    var agentConversationTitle: String?
    @ObservationIgnored var onAgentTitle: ((String) -> Void)?
    @ObservationIgnored var onFirstAgentPrompt: ((String) -> Void)?
    @ObservationIgnored private var submittedFirstAgentPrompt = false
    private(set) var agentActivity: AgentActivity = .unknown
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var lastAgentOutput = Date.distantPast
    @ObservationIgnored private var agentOutputChanged = false
    @ObservationIgnored private var activityNeedsSettledFrame = false
    @ObservationIgnored private var activityScreenHash: Int?
    private(set) var currentDirectory: String?
    private(set) var shellWorking = false
    var isWorking: Bool {
        guard running else { return false }
        if agentProvider != nil { return agentActivity == .working }
        // Closing an attached tmux client leaves the server's jobs running.
        if tmuxLocation != nil { return false }
        #if os(macOS)
        if !workspace.isRemote, let process = (view as? CrowLocalTerminalView)?.process, process.running {
            let foreground = tcgetpgrp(process.childfd)
            return foreground > 0 && foreground != getpgid(process.shellPid)
        }
        #endif
        return shellWorking
    }
    var imagePasteMessage: String?
    var imagePasteInProgress = false
    @ObservationIgnored var imagePasteContext: (() -> String?)?
    @ObservationIgnored var uploadImage: ((Data, String) async throws -> String)?
    @ObservationIgnored private var imagePasteTask: Task<Void, Never>?
    @ObservationIgnored var onFileDropFocus: (() -> Void)?
    @ObservationIgnored var onBytes: (([UInt8]) -> Void)?
    private let workspace: Workspace
    private let directory: String
    private let remote: RemoteConnection?
    private var started = false
    @ObservationIgnored private var appliedFontSize: Double?
    #if os(macOS)
    var systemSSH: SystemSSHSpec?
    var shellEnvironment: [String]?
    @ObservationIgnored private var imageKeyMonitor: Any?
    @ObservationIgnored private var inputCaptureMonitor: Any?
    private var shellPrompted = false
    @ObservationIgnored private var awaitingTmuxCommand = false
    @ObservationIgnored private var pendingPTYSize: (Int, Int)?
    @ObservationIgnored private var liveResizeObserver: NSObjectProtocol?
    private var stoppingProcessID: pid_t?
    #endif
    private var shellTask: Task<Void, Never>?
    private var remoteShellFinished = true
    private var inputTask: Task<Void, Never>?
    private var writer: RemoteWriter?

    init(id: UUID, workspace: Workspace, directory: String, remote: RemoteConnection?, fontSize: Double, useSystemSSH: Bool = false) {
        self.id = id; self.workspace = workspace; self.directory = directory; self.remote = remote
        #if os(macOS)
        if workspace.kind == .local || useSystemSSH {
            view = CrowLocalTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        } else { view = CrowMacTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 300)) }
        #else
        view = CrowIOSTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        #endif
        super.init()
        (view as? any ImagePasteTerminal)?.onImagePaste = { [weak self] in self?.pasteClipboardImage() ?? false }
        #if os(macOS)
        view.registerForDraggedTypes(TerminalFileDrop.types)
        (view as? any FileDropTerminal)?.onFileDrop = { [weak self] pasteboard in
            guard let self, self.dropFiles(from: pasteboard) else { return false }
            self.onFileDropFocus?(); return true
        }
        #endif
        view.optionAsMetaKey = false
        setFontSize(fontSize)
        #if os(macOS)
        view.nativeBackgroundColor = NSColor(CrowTheme.bg0)
        view.nativeForegroundColor = NSColor(CrowTheme.text)
        view.caretColor = NSColor(CrowTheme.accent)
        view.selectedTextBackgroundColor = NSColor(CrowTheme.bg3)
        if let local = view as? CrowLocalTerminalView {
            local.processDelegate = self
            local.onInput = { [weak self] in self?.receivedInput($0) }
            local.onOutput = { [weak self] in
                self?.releaseAbandonedInputCapture()
                self?.agentDidReceiveOutput()
            }
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

    #if os(macOS)
    /// Control chords must not disappear when charactersIgnoringModifiers is Hangul.
    @discardableResult func handleTerminalKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        let key = MacTerminalKeys.character(event)
        if flags == .control, key?.lowercased() == "v", pasteClipboardImage() { return true }
        if tmuxLocation != nil, flags == .control, key?.lowercased() == "b" {
            view.send(data: [2][...]); awaitingTmuxCommand.toggle(); return true
        }
        if awaitingTmuxCommand {
            awaitingTmuxCommand = false
            if flags.isSubset(of: [.shift]), let key {
                view.send(txt: key); return true
            }
        }
        if flags.contains(.control), !flags.contains(.command), !flags.contains(.option),
           event.charactersIgnoringModifiers?.utf8.count != 1,
           let byte = key?.lowercased().utf8.first, (97...122).contains(byte) {
            view.send(data: [byte - 96][...]); return true
        }
        // SwiftUI focus navigation can consume modified arrows before keyDown
        // reaches the embedded NSView. Deliver them here while preserving the
        // keyboard protocol negotiated by Codex/tmux (including Kitty events).
        if !flags.contains(.command), !flags.isEmpty, [UInt16(123), 124, 125, 126].contains(event.keyCode) {
            view.keyDown(with: event); return true
        }
        return false
    }
    #endif

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
        if let startupUnavailableMessage {
            status = startupUnavailableMessage
            view.feed(text: status + "\r\n"); return
        }
        startActivityTracking()
        #if os(macOS)
        imageKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.view.window?.firstResponder === self.view else { return event }
            return self.handleTerminalKey(event) ? nil : event
        }
        // Pointer motion is delivered before the view, so a dead session cannot
        // turn the first move into text.
        inputCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel
        ]) { [weak self] event in
            guard let self, self.view.getTerminal().mouseMode != .off else { return event }
            self.releaseAbandonedInputCapture()
            return event
        }
        if let systemSSH, let local = view as? CrowLocalTerminalView {
            let args: [String]
            if let launchCommand {
                args = ["-tt"] + systemSSH.multiplexArguments + ["sh -lc " + TerminalCommand.quote(TerminalCommand.utf8Environment + launchCommand)]
            } else if FileManager.default.fileExists(atPath: systemSSH.socket) {
                let command = TerminalCommand.utf8Environment + SSHCommand.interactiveShellCommand(directory: directory)
                args = ["-tt"] + systemSSH.multiplexArguments + ["sh -c " + TerminalCommand.quote(command)]
            } else {
                // The authentication terminal stays interactive until the master is established.
                let command = TerminalCommand.utf8Environment + SSHCommand.interactiveShellCommand(directory: directory)
                args = ["-tt"] + systemSSH.initialArguments + ["sh -c " + TerminalCommand.quote(command)]
            }
            // SwiftTerm's default environment drops SSH_AUTH_SOCK and PATH.
            // Preserve the app's inherited agent/proxy environment for OpenSSH.
            let environment = TerminalCommand.utf8Environment(ProcessInfo.processInfo.environment)
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
            var inherited = ProcessInfo.processInfo.environment
            if let shellEnvironment {
                inherited = [:]
                for entry in shellEnvironment {
                    let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if pair.count == 2 { inherited[String(pair[0])] = String(pair[1]) }
                }
            }
            var environment = TerminalCommand.utf8Environment(inherited).map { "\($0.key)=\($0.value)" }
            environment.removeAll { $0.hasPrefix("CROW_TERMINAL_ID=") }
            environment.append("CROW_TERMINAL_ID=\(id.uuidString)")
            local.startProcess(executable: "/bin/zsh", args: launchCommand.map { ["-lic", $0] } ?? ["-l"], environment: environment, currentDirectory: directory)
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
            let initialCommand = TerminalCommand.utf8Environment + "\n" + (launchCommand.map { "exec sh -lc " + TerminalCommand.quote($0) + "\n" }
                ?? (SSHCommand.remoteDirectoryCommand(directory) + "\n" + SSHCommand.directoryTrackingCommand + "\n"))
            let startup = SSHStartupOutput()
            remoteShellFinished = false
            shellTask = Task { [weak self] in
                guard let self else { return }
                defer { remoteShellFinished = true }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, !self.running else { return }
                    self.status = "SSH shell initialization timed out. Reconnect to try again."
                    self.view.feed(text: self.status + "\r\n")
                    self.shellTask?.cancel()
                }
                defer { timeout.cancel() }
                do {
                    let dims = view.getTerminal().getDims()
                    try await client.withPTY(.init(wantReply: true, term: "xterm-256color",
                        terminalCharacterWidth: dims.cols, terminalRowHeight: dims.rows,
                        terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))) { @Sendable [weak self] inbound, outbound in
                        var startup = startup
                        try await outbound.write(ByteBuffer(string: startup.command(initialCommand)))
                        for try await output in inbound {
                            try Task.checkCancellation()
                            switch output {
                            case .stdout(let bytes), .stderr(let bytes):
                                let wasReady = startup.isReady
                                let visible = startup.receive(Array(bytes.readableBytesView))
                                if !wasReady && startup.isReady { await self?.connected(RemoteWriter(value: outbound)) }
                                if !visible.isEmpty { await self?.receive(visible) }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    if !running { view.feed(text: "SSH shell closed before initialization completed.\r\n") }
                    status = "Shell exited"
                } catch { if !Task.isCancelled { status = "SSH: \(error.localizedDescription)"; view.feed(text: "\r\n\(status)\r\n") } }
                writer = nil; running = false
                releaseAbandonedInputCapture(force: true)
            }
        }
    }

    func stop() {
        let cleanup = onStop; onStop = nil; cleanup?()
        activityTask?.cancel(); activityTask = nil; agentActivity = .unknown
        imagePasteTask?.cancel(); imagePasteTask = nil; imagePasteInProgress = false
        #if os(macOS)
        if let imageKeyMonitor { NSEvent.removeMonitor(imageKeyMonitor); self.imageKeyMonitor = nil }
        if let inputCaptureMonitor { NSEvent.removeMonitor(inputCaptureMonitor); self.inputCaptureMonitor = nil }
        if let liveResizeObserver { NotificationCenter.default.removeObserver(liveResizeObserver); self.liveResizeObserver = nil }
        pendingPTYSize = nil
        #endif
        shellTask?.cancel(); shellTask = nil; inputTask?.cancel(); inputTask = nil; writer = nil
        #if os(macOS)
        if let local = view as? LocalProcessTerminalView {
            if local.process.running, local.process.shellPid > 0 { stoppingProcessID = local.process.shellPid }
            local.terminate()
        }
        #endif
        running = false; shellWorking = false; status = "Closed"
    }

    private func connected(_ writer: RemoteWriter) {
        self.writer = writer; running = true; status = "Connected"
    }
    func waitUntilStopped() async throws {
        for _ in 0..<100 {
            #if os(macOS)
            if let local = view as? LocalProcessTerminalView {
                // SwiftTerm clears `running` when sending SIGTERM, before exit.
                if let pid = stoppingProcessID {
                    var exitStatus: Int32 = 0
                    let reaped = waitpid(pid, &exitStatus, WNOHANG)
                    if reaped == pid || (reaped == -1 && errno == ECHILD) { return }
                } else if !local.process.running { return }
            } else if remoteShellFinished { return }
            #else
            if remoteShellFinished { return }
            #endif
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CommandError("The agent is still stopping. Retry deleting its saved session in a moment.")
    }
    private func receive(_ bytes: [UInt8]) {
        view.feedProcessOutput(bytes[...])
        releaseAbandonedInputCapture()
        agentDidReceiveOutput()
    }

    private func agentDidReceiveOutput() {
        guard agentProvider != nil else { return }
        agentOutputChanged = true
    }

    private func startActivityTracking() {
        guard agentProvider != nil else { return }
        activityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                // Read at most twice per second while output changes, plus one
                // settled frame. No extra process, SSH command or history storage.
                if self.agentOutputChanged || self.activityNeedsSettledFrame { self.updateAgentActivity() }
                if !self.running && self.status != "Starting SSH shell…" { return }
            }
        }
    }

    func updateAgentActivity(outputIsRecent: Bool? = nil) {
        guard let provider = agentProvider, running else { agentActivity = .unknown; return }
        let terminal = view.getTerminal()
        let lines = agentScreenLines()
        let cursorRow = terminal.getCursorLocation().y
        var hasher = Hasher()
        for (row, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Typing a draft changes the composer, not the agent's activity.
            if row == cursorRow && ["❯", "›", ">"].contains(where: { trimmed == $0 || trimmed.hasPrefix($0 + " ") }) {
                hasher.combine("agent-composer")
            } else { hasher.combine(line) }
        }
        let fingerprint = hasher.finalize()
        if activityScreenHash != fingerprint { activityScreenHash = fingerprint; lastAgentOutput = Date() }
        let recent = outputIsRecent ?? (Date().timeIntervalSince(lastAgentOutput) < 1.5)
        agentOutputChanged = false; activityNeedsSettledFrame = recent
        agentActivity = AgentActivityDetector.detect(provider: provider, lines: lines,
            cursorRow: cursorRow, outputIsRecent: recent)
    }

    private func agentScreenLines() -> [String] {
        let terminal = view.getTerminal()
        // SwiftTerm exposes indexed buffer access but no active-screen origin.
        // Find the live tail without reading scrollback or moving the viewport.
        var lower = 0, upper = max(1, terminal.rows)
        while terminal.bufferLine(atRow: upper) != nil { lower = upper; upper *= 2 }
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if terminal.bufferLine(atRow: middle) == nil { upper = middle } else { lower = middle + 1 }
        }
        let screenStart = max(0, lower - terminal.rows)
        return (0..<terminal.rows).map { row in
            terminal.bufferLine(atRow: screenStart + row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
                characterProvider: terminal.getCharacter(for:)) ?? ""
        }
    }

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        receivedInput(Array(data))
        guard let writer else { return }
        let bytes = Array(data), previous = inputTask
        inputTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do { try await writer.value.write(ByteBuffer(bytes: bytes)) }
            catch { self?.status = error.localizedDescription }
        }
    }

    private func receivedInput(_ bytes: [UInt8]) {
        onBytes?(bytes)
        // Use the submitted composer, not raw keystrokes (which may include
        // password entry, terminal shortcuts, or edits to an unfinished draft).
        if running, let provider = agentProvider, !submittedFirstAgentPrompt,
           bytes == [13] || bytes == [10] {
            let lines = agentScreenLines(), cursor = view.getTerminal().getCursorLocation()
            if lines.indices.contains(cursor.y), cursor.x > 2 {
                let line = lines[cursor.y].trimmingCharacters(in: .whitespaces)
                let prompt = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if ["❯ ", "› ", "> "].contains(where: { line.hasPrefix($0) }),
                   !prompt.isEmpty, !prompt.hasPrefix("/"),
                   AgentActivityDetector.detect(provider: provider, lines: lines, cursorRow: cursor.y, outputIsRecent: false) == .idle {
                    submittedFirstAgentPrompt = true
                    if agentConversationTitle == nil { recordAgentTitle(prompt) }
                    onFirstAgentPrompt?(prompt)
                }
            }
        }
        if running, agentProvider == nil, currentDirectory != nil, bytes.contains(13) || bytes.contains(10) {
            shellWorking = true
        }
    }

    @discardableResult func pasteClipboardImage() -> Bool {
        guard imagePasteContext?() != nil else { return false }
        do {
            guard let data = try ClipboardImage.png() else { return false }
            return pasteImage(data)
        } catch { imagePasteMessage = error.localizedDescription; return true }
    }

    #if os(macOS)
    @discardableResult func dropFiles(from pasteboard: NSPasteboard) -> Bool {
        guard TerminalFileDrop.accepts(pasteboard) else { return false }
        guard running else { imagePasteMessage = "Wait for the terminal to connect before dropping files."; return false }
        guard !imagePasteInProgress else { imagePasteMessage = "Wait for the current attachment to finish."; return false }
        let files = TerminalFileDrop.files(from: pasteboard)
        if files.isEmpty {
            do { return try ClipboardImage.png(from: pasteboard).map { pasteImage($0) } ?? false }
            catch { imagePasteMessage = error.localizedDescription; return false }
        }
        guard !files.contains(where: { $0.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            imagePasteMessage = "A filename contains control characters and cannot be inserted into the terminal."; return false
        }
        guard files.contains(where: TerminalFileDrop.isImage) else {
            view.pasteLiteralText(files.map { ClipboardImage.pastedPath($0.path) }.joined()); return true
        }
        guard let context = imagePasteContext?(), let uploadImage else {
            imagePasteMessage = "Connect the terminal before attaching images."; return false
        }
        let targetPane = tmuxLocation
        imagePasteInProgress = true; imagePasteMessage = "Preparing dropped images…"
        imagePasteTask = Task { [weak self] in
            defer { self?.imagePasteInProgress = false; self?.imagePasteTask = nil }
            do {
                var paths: [String] = []
                for file in files {
                    try Task.checkCancellation()
                    if TerminalFileDrop.isImage(file) {
                        let data = try await Task.detached(priority: .userInitiated) { try TerminalFileDrop.readImage(file) }.value
                        try Task.checkCancellation()
                        paths.append(try await uploadImage(data, context))
                    } else { paths.append(file.path) }
                }
                guard !Task.isCancelled, let self, self.running else { return }
                guard self.imagePasteContext?() == context, self.tmuxLocation == targetPane else {
                    self.imagePasteMessage = "The connection or terminal pane changed. Dropped files were not inserted."; return
                }
                self.view.pasteLiteralText(paths.map(ClipboardImage.pastedPath).joined())
                self.imagePasteMessage = "Attached \(files.count) dropped file\(files.count == 1 ? "" : "s")."
            } catch {
                if !Task.isCancelled { self?.imagePasteMessage = "File drop failed: " + error.localizedDescription }
            }
        }
        return true
    }
    #endif

    @discardableResult func pasteImage(_ data: Data) -> Bool {
        guard let context = imagePasteContext?(), let uploadImage else { return false }
        guard !imagePasteInProgress else { return true }
        guard running else { imagePasteMessage = "Wait for the terminal to connect before pasting an image."; return true }
        imagePasteInProgress = true; imagePasteMessage = "Saving clipboard image…"
        imagePasteTask = Task { [weak self] in
            defer { self?.imagePasteInProgress = false; self?.imagePasteTask = nil }
            do {
                try ClipboardImage.validate(data)
                let path = try await uploadImage(data, context)
                guard !Task.isCancelled, let self, self.running else { return }
                guard self.imagePasteContext?() == context else {
                    self.imagePasteMessage = "Connection changed. The image was uploaded to \(path), but its path was not pasted."
                    return
                }
                self.view.pasteLiteralText(ClipboardImage.pastedPath(path))
                self.imagePasteMessage = "Image ready: \(path)"
            } catch {
                if !Task.isCancelled { self?.imagePasteMessage = "Image paste failed: \(error.localizedDescription)" }
            }
        }
        return true
    }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        guard let writer else { return }
        #if os(macOS)
        if source.window?.inLiveResize == true {
            pendingPTYSize = (newCols, newRows)
            if liveResizeObserver == nil {
                liveResizeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didEndLiveResizeNotification, object: source.window, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.flushPendingPTYSize() }
                }
            }
            return
        }
        #endif
        Task { try? await writer.value.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0) }
    }
    #if os(macOS)
    private func flushPendingPTYSize() {
        if let observer = liveResizeObserver {
            NotificationCenter.default.removeObserver(observer)
            liveResizeObserver = nil
        }
        guard let writer, let size = pendingPTYSize else { return }
        pendingPTYSize = nil
        Task { try? await writer.value.changeSize(cols: size.0, rows: size.1, pixelWidth: 0, pixelHeight: 0) }
    }
    #endif
    private func recordAgentTitle(_ value: String) {
        let value = String(value.split(whereSeparator: { $0.isNewline }).joined(separator: " ").prefix(150))
        guard !value.isEmpty, agentConversationTitle != value else { return }
        agentConversationTitle = value
        onAgentTitle?(value)
    }
    private func receiveTerminalTitle(_ value: String) {
        title = value
        guard let provider = agentProvider else { return }
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "✳✻✽✶✢·⠂⠐⠒⠲⠴⠦⠖⠆⠄● "))
        for prefix in [provider.title + ": ", provider.title + " - ", provider.title + " — "] {
            if name.lowercased().hasPrefix(prefix.lowercased()) { name = String(name.dropFirst(prefix.count)) }
        }
        for suffix in [" | " + provider.title, " - " + provider.title, " — " + provider.title] {
            if name.lowercased().hasSuffix(suffix.lowercased()) { name = String(name.dropLast(suffix.count)) }
        }
        guard !["terminal", "zsh", "bash", "sh", "claude code", provider.rawValue].contains(name.lowercased()),
              !name.lowercased().hasPrefix(provider.rawValue + " --"),
              name != workspace.name, name != directory, !name.isEmpty else { return }
        recordAgentTitle(name)
    }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { receiveTerminalTitle(title) }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        // OSC 7 is the shell prompt hook. A full-screen program does not emit it.
        shellPrompted = true
        currentDirectory = SSHCommand.terminalDirectory(directory)
        if currentDirectory != nil { shellWorking = false }
    }

    /// Drop mouse and focus tracking left behind when a program dies with the SSH
    /// session. Otherwise pointer motion is typed into the shell as `35;x;yM`.
    func releaseAbandonedInputCapture(force: Bool = false) {
        let terminal = view.getTerminal()
        let prompted = shellPrompted
        shellPrompted = false
        if !force, terminal.mouseMode == .off { return }
        let action: TerminalInputCapture.Action
        if force {
            let owned = terminal.mouseMode != .off || terminal.applicationCursor || terminal.mouseShiftCapture
                || !terminal.keyboardEnhancementFlags.isEmpty
            action = owned ? .application : .none
        } else {
            action = TerminalInputCapture.action(mouse: terminal.mouseMode, foreground: foregroundOwner, prompted: prompted)
        }
        switch action {
        case .none: return
        case .hover: view.feedProcessOutput(Array(TerminalInputCapture.hoverRelease.utf8)[...])
        case .application: view.feedProcessOutput(Array(TerminalInputCapture.applicationRelease.utf8)[...])
        }
    }

    private var foregroundOwner: TerminalInputCapture.Foreground {
        #if os(macOS)
        // An SSH process is the session itself: its process group stays put while
        // the remote program exits, so only the remote shell's prompt can tell.
        guard systemSSH == nil, let process = (view as? CrowLocalTerminalView)?.process, process.running,
              process.shellPid > 0, process.childfd >= 0 else { return .unknown }
        let foreground = tcgetpgrp(process.childfd), shell = getpgid(process.shellPid)
        guard foreground > 0, shell > 0 else { return .unknown }
        return foreground == shell ? .shell : .child
        #else
        return .unknown
        #endif
    }
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
class CrowIOSTerminalView: SwiftTerm.TerminalView, ImagePasteTerminal, SnippetInput {
    func insertSnippet(_ text: String) {
        (inputAccessoryView as? CrowKeyboardAccessory)?.resetModifiers()
        pasteLiteralText(text)
    }
    var onImagePaste: (() -> Bool)?
    override func paste(_ sender: Any?) {
        if onImagePaste?() == true { return }
        super.paste(sender)
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.count == 1, let key = presses.first?.key,
           key.modifierFlags.intersection([.control, .alternate, .command, .shift]) == .control,
           key.charactersIgnoringModifiers.lowercased() == "v", onImagePaste?() == true { return }
        super.pressesBegan(presses, with: event)
    }
    private var regularAccessory: UIView?

    func setPhoneAccessory(_ enabled: Bool) {
        if enabled {
            guard !(inputAccessoryView is CrowKeyboardAccessory) else { return }
            regularAccessory = inputAccessoryView
            let accessory = CrowKeyboardAccessory()
            accessory.onKey = { [weak self] key in self?.performKeyboardKey(key) }
            accessory.onModifiersChanged = { [weak self] control, _ in self?.controlModifier = control }
            inputAccessoryView = accessory
        } else {
            guard inputAccessoryView is CrowKeyboardAccessory else { return }
            inputAccessoryView = regularAccessory; regularAccessory = nil
        }
        if isFirstResponder { reloadInputViews() }
    }

    private func performKeyboardKey(_ key: KeyboardBarKey) {
        if key.control, key.key.lowercased() == "v", onImagePaste?() == true { return }
        send(txt: key.terminalText(applicationCursor: getTerminal().applicationCursor))
    }

    override func insertText(_ text: String) {
        if let key = (inputAccessoryView as? CrowKeyboardAccessory)?.typedKey(text) { performKeyboardKey(key); return }
        if controlModifier, text.lowercased() == "v", onImagePaste?() == true { controlModifier = false; return }
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


#endif

#if os(macOS)
private enum TerminalWindowChrome {
    static let resizeInset: CGFloat = 5
    static func claimsPoint(_ point: NSPoint, in view: NSView) -> Bool {
        guard let window = view.window, window.styleMask.contains(.resizable), !window.styleMask.contains(.fullScreen),
              let content = window.contentView else { return true }
        if window.inLiveResize { return false }
        let p = view.convert(point, to: content), b = content.bounds, inset = resizeInset
        return p.x > inset && p.y > inset && p.x < b.maxX - inset && p.y < b.maxY - inset
    }
}

private final class CrowMacTerminalView: SwiftTerm.TerminalView, ImagePasteTerminal, FileDropTerminal, MarkedTextTerminal {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func hitTest(_ point: NSPoint) -> NSView? { TerminalWindowChrome.claimsPoint(point, in: self) ? super.hitTest(point) : nil }
    override func viewWillStartLiveResize() { window?.disableCursorRects(); super.viewWillStartLiveResize() }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); window?.enableCursorRects(); window?.resetCursorRects() }
    var onFileDrop: ((NSPasteboard) -> Bool)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TerminalFileDrop.accepts(sender.draggingPasteboard) ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { TerminalFileDrop.accepts(sender.draggingPasteboard) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard onFileDrop?(sender.draggingPasteboard) == true else { return false }
        window?.makeFirstResponder(self); return true
    }

    let composition = TerminalComposition()
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        composition.update(in: self)
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        composition.clear(in: self)
        super.insertText(string, replacementRange: replacementRange)
    }
    override func unmarkText() {
        composition.clear(in: self); super.unmarkText()
    }
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        if let rect = composition.screenRect(in: self) { actualRange?.pointee = range; return rect }
        return super.firstRect(forCharacterRange: range, actualRange: actualRange)
    }

    var onImagePaste: (() -> Bool)?
    override func paste(_ sender: Any) {
        if onImagePaste?() == true { return }
        super.paste(sender)
    }
}

private final class CrowLocalTerminalView: LocalProcessTerminalView, ImagePasteTerminal, FileDropTerminal, MarkedTextTerminal {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func hitTest(_ point: NSPoint) -> NSView? { TerminalWindowChrome.claimsPoint(point, in: self) ? super.hitTest(point) : nil }
    override func viewWillStartLiveResize() { window?.disableCursorRects(); super.viewWillStartLiveResize() }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); window?.enableCursorRects(); window?.resetCursorRects() }
    var onFileDrop: ((NSPasteboard) -> Bool)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TerminalFileDrop.accepts(sender.draggingPasteboard) ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { TerminalFileDrop.accepts(sender.draggingPasteboard) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard onFileDrop?(sender.draggingPasteboard) == true else { return false }
        window?.makeFirstResponder(self); return true
    }

    let composition = TerminalComposition()
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        composition.update(in: self)
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        composition.clear(in: self)
        super.insertText(string, replacementRange: replacementRange)
    }
    override func unmarkText() {
        composition.clear(in: self); super.unmarkText()
    }
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        if let rect = composition.screenRect(in: self) { actualRange?.pointee = range; return rect }
        return super.firstRect(forCharacterRange: range, actualRange: actualRange)
    }

    var onImagePaste: (() -> Bool)?
    override func paste(_ sender: Any) {
        if onImagePaste?() == true { return }
        super.paste(sender)
    }
    var onInput: (@MainActor ([UInt8]) -> Void)?
    var onOutput: (@MainActor () -> Void)?
    override func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            feedProcessOutput(slice)
            onOutput?()
        }
    }
    override func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { onInput?(Array(data)) }
        super.send(source: source, data: data)
    }
}

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { receiveTerminalTitle(title) }
    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        running = false; status = "Exited (\(exitCode.map(String.init) ?? "unknown"))"
        releaseAbandonedInputCapture(force: true)
    }
}
#endif
