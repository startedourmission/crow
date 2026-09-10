import Foundation

public struct GitChange: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let status: String
    public let path: String
    public let previousPath: String?
    public var isDeleted: Bool { status.contains("D") }
}

public struct GitStatus: Equatable, Sendable {
    public let branch: String
    public let changes: [GitChange]
    /// Parse porcelain v1 with -z; paths are never split on whitespace or newlines.
    public init(porcelain: Data) {
        let fields = porcelain.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var branch = "HEAD", changes: [GitChange] = [], index = 0
        while index < fields.count {
            let field = fields[index]; index += 1
            if field.hasPrefix("## ") { branch = String(field.dropFirst(3)); continue }
            guard field.utf8.count >= 4 else { continue }
            let status = String(field.prefix(2)), path = String(field.dropFirst(3))
            let renamed = status.contains("R") || status.contains("C")
            let previous = renamed && index < fields.count ? fields[index] : nil
            if renamed { index += 1 }
            changes.append(GitChange(status: status, path: path, previousPath: previous))
        }
        self.branch = branch; self.changes = changes
    }
}
