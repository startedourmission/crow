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

    static func saveLocally(_ data: Data) throws -> String {
        try validate(data)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crow-clipboard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("image.png")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file.path
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

#if os(macOS)
enum MacTerminalKeys {
    static func character(_ event: NSEvent) -> String? {
        if let text = event.charactersIgnoringModifiers, text.utf8.count == 1,
           let byte = text.utf8.first, (32...126).contains(byte) { return text }
        // ANSI physical positions for non-Latin input sources (including Korean).
        let keys: [UInt16: String] = [0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",
            12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",
            24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"o",32:"u",33:"[",34:"i",35:"p",
            37:"l",38:"j",39:"'",40:"k",41:";",42:"\\",43:",",44:"/",45:"n",46:"m",47:".",49:" ",50:"`"]
        guard let key = keys[event.keyCode] else { return nil }
        guard event.modifierFlags.contains(.shift) else { return key }
        let shifted = ["1":"!","2":"@","3":"#","4":"$","5":"%","6":"^","7":"&","8":"*","9":"(","0":")",
            "-":"_","=":"+","[":"{","]":"}",";":":","'":"\"",",":"<",".":">","/":"?","\\":"|","`":"~"]
        return shifted[key] ?? key.uppercased()
    }
}
#endif
