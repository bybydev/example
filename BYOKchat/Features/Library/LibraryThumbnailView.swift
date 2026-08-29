import AppFoundation
import BYOKchatProviderCore
import ImageIO
import SwiftUI
import UIKit

enum AttachmentThumbnailLoader {
  /// NSCache is thread-safe at runtime but not annotated Sendable; this box
  /// satisfies strict concurrency for the shared static instance.
  private struct ThumbnailCache: @unchecked Sendable {
    let storage = NSCache<NSString, UIImage>()
  }

  private static let cache = ThumbnailCache()

  /// Downsampled decode via ImageIO so a 20 MB JPEG never materializes as a
  /// full-resolution bitmap just to fill a small tile. Callers must supply a
  /// stable unique key (attachment or entry ID).
  static func downsampledImage(
    from data: Data,
    cacheKey: String,
    maxPixelSize: CGFloat
  ) -> UIImage? {
    let key = "\(cacheKey)::\(Int(maxPixelSize))" as NSString
    if let cached = cache.storage.object(forKey: key) { return cached }

    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
      return nil
    }
    let thumbnailOptions = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ] as CFDictionary
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
      return nil
    }
    let image = UIImage(cgImage: cgImage)
    cache.storage.setObject(image, forKey: key)
    return image
  }
}

/// Leading thumbnail for a library row. Loads bytes asynchronously (blob
/// files) and decodes off the main thread.
struct LibraryEntryThumbnailView: View {
  let entry: LibraryEntry
  let library: LibraryManagementModel
  var sideLength: CGFloat = 52

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: sideLength, height: sideLength)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(theme.borderColor.opacity(0.8), lineWidth: 0.75)
          )
      } else if entry.isImage {
        ProgressView()
          .frame(width: sideLength, height: sideLength)
      } else {
        Image(systemName: "doc")
          .font(.system(size: sideLength * 0.42, weight: .medium))
          .foregroundStyle(theme.secondaryForegroundColor)
          .frame(width: sideLength, height: sideLength)
          .background(
            theme.surfaceColor,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(theme.borderColor.opacity(0.8), lineWidth: 0.75)
          )
      }
    }
    .accessibilityHidden(true)
    .task(id: entry.id) {
      guard image == nil, entry.isImage else { return }
      // Downsampled bytes are served from the blob store's persisted
      // derivative when available; the full original is never loaded for a tile.
      let maxPixelSize = sideLength * displayScale
      let bytes = await library.thumbnailData(for: entry, maxPixelSize: maxPixelSize)
      guard let bytes else { return }
      image = await Task.detached(priority: .userInitiated) {
        AttachmentThumbnailLoader.downsampledImage(
          from: bytes,
          cacheKey: "entry::\(entry.id.rawValue)",
          maxPixelSize: maxPixelSize
        )
      }.value
    }
  }
}
