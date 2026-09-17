import CrowCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ImagePreview: Sendable {
    static let sizeLimit = 50 * 1_024 * 1_024
    private static let supportedTypes = Set(CGImageSourceCopyTypeIdentifiers() as! [String])
    let image: CGImage
    let width: Int
    let height: Int
    let byteCount: Int
    let format: String

    static func supports(_ path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension), type.conforms(to: .image) else { return false }
        return supportedTypes.contains(type.identifier)
    }

    static func read(_ path: String) throws -> ImagePreview {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        // Bound the actual read too, in case the file grows after its metadata was checked.
        guard try file.seekToEnd() <= sizeLimit else { throw Failure.tooLarge }
        try file.seek(toOffset: 0)
        return try decode(file.read(upToCount: sizeLimit + 1) ?? Data())
    }

    static func decode(_ data: Data, maximumDimension: Int = 4096) throws -> ImagePreview {
        guard data.count <= sizeLimit else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { throw Failure.invalid }
        // Decode off the main thread and bound decoded memory for large photos.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(1, maximumDimension),
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.invalid }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        return ImagePreview(image: image, width: rotated ? height : width, height: rotated ? width : height,
            byteCount: data.count, format: type?.preferredFilenameExtension?.uppercased() ?? "Image")
    }

    /// Small, compressed Canvas previews. Encoding stays off the main actor too.
    static func canvasThumbnail(_ data: Data) throws -> String {
        let preview = try decode(data, maximumDimension: 768)
        let transparent = [CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast].contains(preview.image.alphaInfo)
        let type = transparent ? UTType.png : UTType.jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { throw Failure.invalid }
        CGImageDestinationAddImage(destination, preview.image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalid }
        return "data:" + (type.preferredMIMEType ?? "image/png") + ";base64," + (output as Data).base64EncodedString()
    }

    enum Failure: LocalizedError {
        case tooLarge, invalid
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Image previews support files up to 50 MB."
            case .invalid: "This image is damaged or its format is not supported."
            }
        }
    }
}

struct CrowImagePreviewView: View {
    @Environment(AppModel.self) private var model
    let buffer: OpenBuffer
    @State private var zoom: CGFloat? // nil fits the available viewport
    @GestureState private var magnification: CGFloat = 1
    private var preview: ImagePreview? { model.imagePreviews[buffer.id] }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    toolbar(viewport: geometry.size, details: true)
                    toolbar(viewport: geometry.size, details: false)
                }
                CrowDivider()
                if let error = model.externalFileErrors[buffer.id] {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(CrowTheme.danger)
                        Spacer(minLength: 4)
                        Button("Retry") { Task { await model.refreshBufferFromSource(buffer.id, force: true) } }
                    }.padding(8).background(CrowTheme.bg1)
                }
                if let preview {
                    GeometryReader { viewport in
                        let scale = min(8, max(0.01, (zoom ?? fitScale(preview, in: viewport.size)) * magnification))
                        ScrollView([.horizontal, .vertical]) {
                            Image(decorative: preview.image, scale: 1)
                                .resizable().interpolation(.high)
                                .frame(width: CGFloat(preview.width) * scale, height: CGFloat(preview.height) * scale)
                                .padding(16)
                                .frame(minWidth: viewport.size.width, minHeight: viewport.size.height)
                        }
                        .background { checkerboard }
                        .simultaneousGesture(MagnifyGesture()
                            .updating($magnification) { value, state, _ in state = value.magnification }
                            .onEnded { value in
                                zoom = min(8, max(0.01, (zoom ?? fitScale(preview, in: viewport.size)) * value.magnification))
                            })
                        .accessibilityLabel("Image preview: \(buffer.title), \(preview.width) by \(preview.height) pixels")
                        .accessibilityIdentifier("crow.image-preview")
                    }
                } else if buffer.isRemote, model.locate(buffer.id)?.0.remote?.isConnected != true {
                    VStack(spacing: 10) {
                        Image(systemName: "network.slash").font(.title2)
                        Text("Connect to this SSH host to load the image.").font(.caption)
                    }.foregroundStyle(CrowTheme.textDim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.externalFileErrors[buffer.id] == nil {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(buffer.isRemote ? "Loading image over SSH…" : "Loading image…")
                            .font(.caption).foregroundStyle(CrowTheme.textDim)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: "photo").font(.system(size: 36, weight: .light))
                        .foregroundStyle(CrowTheme.textDim).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(CrowTheme.bg0)
        .task(id: buffer.path) { await model.observeBuffer(buffer.id) }
    }

    private func toolbar(viewport: CGSize, details: Bool) -> some View {
        HStack(spacing: 12) {
            if let preview, details {
                Text("\(preview.format) · \(preview.width) × \(preview.height) · \(ByteCountFormatter.string(fromByteCount: Int64(preview.byteCount), countStyle: .file))")
                    .font(.system(size: 11)).foregroundStyle(CrowTheme.textDim).lineLimit(1).fixedSize()
            } else {
                Image(systemName: "photo").foregroundStyle(CrowTheme.textDim)
            }
            Spacer(minLength: 4)
            Group {
                Button { zoom = nil } label: { Text("Fit").foregroundStyle(zoom == nil ? CrowTheme.accent : CrowTheme.textDim) }
                    .help("Fit Image to Window").accessibilityLabel("Fit Image to Window")
                Button("100%") { zoom = 1 }.help("Actual Size")
                Button { changeZoom(by: 1 / 1.25, viewport: viewport) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("Zoom Out")
                Button { changeZoom(by: 1.25, viewport: viewport) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("Zoom In")
            }.disabled(preview == nil)
            EditorFileMenu(buffer: buffer)
        }
        .font(.system(size: 12)).buttonStyle(CrowButtonStyle())
        .padding(.horizontal, 12).frame(height: 32)
        .windowDragExcluded()
    }

    private func fitScale(_ preview: ImagePreview, in size: CGSize) -> CGFloat {
        min(1, max(0.01, min((size.width - 32) / CGFloat(preview.width), (size.height - 32) / CGFloat(preview.height))))
    }
    private func changeZoom(by factor: CGFloat, viewport: CGSize) {
        guard let preview else { return }
        zoom = min(8, max(0.01, (zoom ?? fitScale(preview, in: CGSize(width: viewport.width, height: viewport.height - 33))) * factor))
    }
    private var checkerboard: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let tile: CGFloat = 12
            for row in 0..<Int(ceil(size.height / tile)) {
                for column in 0..<Int(ceil(size.width / tile)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)),
                        with: .color(Color(white: 0.91)))
                }
            }
        }.clipped()
    }
}
