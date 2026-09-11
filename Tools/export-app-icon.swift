import AppKit
import ImageIO
import UniformTypeIdentifiers

// Asset packaging only: keep the reviewed master artwork; export platform sizes.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Design/AppIcon/Master.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Missing app icon master") }
let width = master.width, height = master.height
precondition(width == height, "App icon master must be square")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
let inspect = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: space, bitmapInfo: bitmapInfo)!
inspect.draw(master, in: CGRect(x: 0, y: 0, width: width, height: height))
let pixels = inspect.data!.assumingMemoryBound(to: UInt8.self)
for y in 0..<height {
    for x in 0..<width {
        precondition(pixels[(y * width + x) * 4 + 3] == 255,
            "App icon master must be full-bleed and opaque; transparent padding creates an inset macOS icon")
    }
}
print("Master: \(width)×\(height); full-bleed opaque artwork")
let asset = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
func export(_ name: String, size: Int) {
    let info = CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: space, bitmapInfo: info)!
    context.interpolationQuality = .high
    context.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(asset.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "Failed to export \(name)")
}
for size in [16, 32, 64, 128, 256, 512, 1024] {
    export("AppIcon-mac-\(size).png", size: size)
}
// The platform supplies the icon mask; never add another tile or exterior padding.
export("AppIcon.png", size: 1024)
