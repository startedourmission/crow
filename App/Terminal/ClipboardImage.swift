import Foundation
import CrowCore
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ClipboardImage {
    static let sizeLimit = 20 * 1024 * 1024

    @MainActor static func png() throws -> Data? {
        #if os(macOS)
        return try png(from: .general)
        #else
        guard let image = UIPasteboard.general.image else { return nil }
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        guard pixels <= 40_000_000, let png = image.pngData() else {
            throw CommandError("Could not read this clipboard image (maximum 40 megapixels).")
        }
        try validate(png)
        return png
        #endif
    }

    #if os(macOS)
    @MainActor static func png(from pasteboard: NSPasteboard) throws -> Data? {
        guard let source = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return nil }
        guard source.count <= sizeLimit else { throw CommandError("Clipboard image exceeds 20 MB.") }
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height,
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw CommandError("Could not read this clipboard image (maximum 40 megapixels).")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw CommandError("Could not encode the clipboard image.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CommandError("Could not encode the clipboard image.") }
        let png = output as Data
        try validate(png)
        return png
    }
    #endif

    static func validate(_ data: Data) throws {
        guard data.count <= sizeLimit else { throw CommandError("Clipboard image exceeds 20 MB.") }
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw CommandError("Clipboard image is not PNG data.") }
    }

    static func pastedPath(_ path: String) -> String {
        // No newline or command execution. Shell quoting also handles server paths containing spaces.
        if path.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }) {
            return path + " "
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' "
    }
}

@MainActor protocol ImagePasteTerminal: AnyObject {
    var onImagePaste: (() -> Bool)? { get set }
}
