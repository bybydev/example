import SwiftUI
import ImageIO
import UIKit

struct ProjectArtworkView: View {
    let url: URL?
    let sourceType: ProjectSourceType
    let width: CGFloat
    let height: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary)

                    VStack(spacing: 5) {
                        Image(systemName: sourceIcon)
                            .font(.title3)
                        Text(sourceLabel)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            image = await loadImage()
        }
    }

    private var sourceIcon: String {
        switch sourceType {
        case .epub: "book.closed"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .paste: "doc.on.clipboard"
        case .article: "globe"
        }
    }

    private var sourceLabel: String {
        switch sourceType {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .document: "DOC"
        case .paste: "TEXT"
        case .article: "WEB"
        }
    }

    private func loadImage() async -> UIImage? {
        guard let url else { return nil }

        let pixelSize = min(512, max(128, Int(max(width, height) * 3)))
        let data = await ProjectArtworkThumbnail.load(at: url, maximumPixelSize: pixelSize)
        guard !Task.isCancelled, let data, !data.isEmpty else {
            return nil
        }
        return UIImage(data: data)
    }
}

// Shared by on-screen covers and Now Playing. Never decode the original cover
// into a full-size UIImage, including when a system artwork request arrives.
nonisolated enum ProjectArtworkThumbnail {
    static func load(at url: URL, maximumPixelSize: Int) async -> Data? {
        let pixelSize = min(512, max(1, maximumPixelSize))
        let task = Task.detached(priority: .utility) { () -> Data? in
            do { try ReadAloudSafety.requireMemoryHeadroom() }
            catch { return nil }
            guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  fileSize > 0, fileSize <= 16 * 1024 * 1024,
                  let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue.isFinite, height.doubleValue.isFinite,
                  width.doubleValue > 0, height.doubleValue > 0,
                  width.doubleValue * height.doubleValue <= 64_000_000,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary),
                  let output = CFDataCreateMutable(nil, 0),
                  let destination = CGImageDestinationCreateWithData(output,
                    "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination),
                  !Task.isCancelled,
                  let bytes = CFDataGetBytePtr(output) else { return nil }
            return Data(bytes: bytes, count: CFDataGetLength(output))
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

