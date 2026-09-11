import Foundation

struct FileRevision: Equatable, Sendable {
    var size: UInt64?
    var modified: Date?
    var identity: UInt64?

    static func local(_ path: String) throws -> FileRevision {
        let attributes = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnsupportedScheme) }
        return FileRevision(size: (attributes[.size] as? NSNumber)?.uint64Value,
            modified: attributes[.modificationDate] as? Date, identity: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}

struct ObservedFileRevision {
    let path: String
    let revision: FileRevision
    let checkedAt: Date
    let verifyAgain: Bool
}
