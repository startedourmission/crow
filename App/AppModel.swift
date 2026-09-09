import CrowCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    var hosts: [SSHHost]
    var workspaces: [Workspace]
    var selectedWorkspaceID: WorkspaceID
    var sidebarPane: SidebarPane = .files
    var sidebarVisible: Bool = true
    var terminalVisible: Bool = true
    var compactSurface: CompactSurface = .editor
    var buffers: [OpenBuffer] = []
    var selectedBufferID: BufferID?
    var files: [FileEntry] = []
    var imeProbe: IMEProbe = .empty
    var statusMessage: String = "Ready"

    let vaultURL: URL

    init(vaultURL: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let vault = vaultURL ?? documents.appendingPathComponent("CrowVault", isDirectory: true)
        self.vaultURL = vault

        let local = Workspace(name: "Vault", kind: .local, connection: .local)
        let ime = Workspace(name: "IME Lab", kind: .imeLab, connection: .local)
        self.workspaces = [local, ime]
        self.selectedWorkspaceID = local.id
        self.hosts = [
            SSHHost(name: "home", hostname: "192.168.0.10", username: "jinwoo", remotePath: "~"),
            SSHHost(name: "vps", hostname: "example.com", username: "ubuntu", remotePath: "/var/www"),
        ]
        bootstrapVaultIfNeeded()
        refreshFiles()
        openWelcomeIfNeeded()
    }

    var selectedWorkspace: Workspace {
        workspaces.first(where: { $0.id == selectedWorkspaceID }) ?? workspaces[0]
    }

    var selectedBuffer: OpenBuffer? {
        buffers.first(where: { $0.id == selectedBufferID })
    }

    var workspaceTitle: String {
        selectedWorkspace.name
    }

    func selectWorkspace(_ id: WorkspaceID) {
        selectedWorkspaceID = id
        refreshFiles()
        statusMessage = selectedWorkspace.isRemote
            ? "Workspace \(selectedWorkspace.name)"
            : selectedWorkspace.name
        if case .imeLab = selectedWorkspace.kind {
            compactSurface = .terminal
            terminalVisible = true
        }
    }

    func connect(_ host: SSHHost) {
        if let existing = workspaces.first(where: {
            if case .remote(let hostID, _) = $0.kind { return hostID == host.id }
            return false
        }) {
            var updated = existing
            updated.connection = .connected
            replaceWorkspace(updated)
            selectWorkspace(updated.id)
            statusMessage = "Attached \(host.userAtHost) — echo until SSH ships"
            return
        }

        var workspace = Workspace(
            name: host.name,
            kind: .remote(hostID: host.id, path: host.remotePath),
            connection: .connecting
        )
        workspaces.append(workspace)
        selectWorkspace(workspace.id)
        workspace.connection = .connected
        replaceWorkspace(workspace)
        refreshFiles()
        statusMessage = "Opened \(host.userAtHost) as its own workspace"
    }

    func disconnectCurrent() {
        guard selectedWorkspace.isRemote else { return }
        var workspace = selectedWorkspace
        workspace.connection = .disconnected
        replaceWorkspace(workspace)
        statusMessage = "Disconnected \(workspace.name)"
    }

    func openFile(_ entry: FileEntry) {
        guard !entry.isDirectory else { return }
        if let existing = buffers.first(where: { $0.path == entry.path }) {
            selectedBufferID = existing.id
            compactSurface = .editor
            return
        }
        let text: String
        if entry.path.hasPrefix("remote://") {
            text = remoteStub(for: entry)
        } else {
            text = (try? String(contentsOf: URL(fileURLWithPath: entry.path), encoding: .utf8)) ?? ""
        }
        let buffer = OpenBuffer(
            title: entry.name,
            path: entry.path,
            text: text,
            language: LanguageMode.infer(filename: entry.name),
            isRemote: entry.path.hasPrefix("remote://")
        )
        buffers.append(buffer)
        selectedBufferID = buffer.id
        compactSurface = .editor
    }

    func updateBufferText(_ id: BufferID, _ text: String) {
        guard let index = buffers.firstIndex(where: { $0.id == id }) else { return }
        buffers[index].text = text
        buffers[index].isDirty = true
    }

    func saveSelectedBuffer() {
        guard let id = selectedBufferID,
              let index = buffers.firstIndex(where: { $0.id == id })
        else { return }
        let buffer = buffers[index]
        if buffer.isRemote {
            statusMessage = "Remote save waits on SFTP"
            return
        }
        do {
            try buffer.text.write(to: URL(fileURLWithPath: buffer.path), atomically: true, encoding: .utf8)
            buffers[index].isDirty = false
            statusMessage = "Saved \(buffer.title)"
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func closeBuffer(_ id: BufferID) {
        buffers.removeAll { $0.id == id }
        if selectedBufferID == id {
            selectedBufferID = buffers.last?.id
        }
    }

    func newUntitledBuffer() {
        let url = vaultURL.appendingPathComponent("untitled-\(shortID()).md")
        try? "".write(to: url, atomically: true, encoding: .utf8)
        refreshFiles()
        openFile(FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: false))
    }

    func refreshFiles() {
        switch selectedWorkspace.kind {
        case .local:
            files = localFiles()
        case .imeLab:
            files = [
                FileEntry(name: "README.md", path: vaultURL.appendingPathComponent("README.md").path, isDirectory: false),
            ]
        case .remote(_, let path):
            files = [
                FileEntry(name: path, path: "remote://\(selectedWorkspace.id.rawValue)/", isDirectory: true),
                FileEntry(name: "README.md", path: "remote://\(selectedWorkspace.id.rawValue)/README.md", isDirectory: false),
                FileEntry(name: "nginx.conf", path: "remote://\(selectedWorkspace.id.rawValue)/nginx.conf", isDirectory: false),
                FileEntry(name: "compose.yml", path: "remote://\(selectedWorkspace.id.rawValue)/compose.yml", isDirectory: false),
                FileEntry(name: "notes.txt", path: "remote://\(selectedWorkspace.id.rawValue)/notes.txt", isDirectory: false),
            ]
        }
    }

    func recordPTY(_ bytes: ArraySlice<UInt8>) {
        imeProbe = IMEProbe.from(bytes: bytes)
        if !imeProbe.isHealthyCommit {
            statusMessage = "IME forwarded jamo — that must not happen"
        }
    }

    private func replaceWorkspace(_ workspace: Workspace) {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        }
    }

    private func localFiles() -> [FileEntry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: vaultURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: isDir)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func bootstrapVaultIfNeeded() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: vaultURL.path) {
            try? fm.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        }
        writeIfMissing(
            "README.md",
            """
            # Crow vault

            로컬 워크스페이스입니다. SSH 호스트에 붙으면 그 호스트가 **별도의 워크스페이스**로 열립니다.

            - 마크다운, txt, json, yaml, conf 모두 같은 에디터에서 엽니다.
            - 위키 링크와 LSP는 없습니다.
            - 터미널 한글은 IME Lab 워크스페이스에서 먼저 검증합니다.
            """
        )
        writeIfMissing(
            "notes.txt",
            "그냥 텍스트. 옵시디언이 거부하던 파일도 여기선 파일일 뿐이다.\n"
        )
        writeIfMissing(
            "config.json",
            """
            {
              "fontSize": 17,
              "ime": "commit-only",
              "cjkWidth": 2
            }
            """
        )
    }

    private func writeIfMissing(_ name: String, _ contents: String) {
        let url = vaultURL.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func openWelcomeIfNeeded() {
        let readme = vaultURL.appendingPathComponent("README.md")
        openFile(FileEntry(name: "README.md", path: readme.path, isDirectory: false))
    }

    private func remoteStub(for entry: FileEntry) -> String {
        switch entry.name {
        case "nginx.conf":
            return "server {\n    listen 80;\n    server_name example.com;\n    root /var/www;\n}\n"
        case "compose.yml":
            return "services:\n  web:\n    image: nginx:alpine\n    ports:\n      - \"80:80\"\n"
        case "notes.txt":
            return "원격 파일은 SFTP가 붙기 전 미리보기입니다.\n"
        default:
            return "# \(selectedWorkspace.name)\n\n이 워크스페이스는 \(selectedWorkspace.name) 호스트에 묶여 있습니다.\n터미널과 파일 트리가 같은 연결을 공유합니다.\n"
        }
    }

    private func shortID() -> String {
        String(UUID().uuidString.prefix(6)).lowercased()
    }
}
