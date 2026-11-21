import AppFoundation
import BYOKchatProviderCore
import ImageIO
import SwiftUI
import UIKit

private actor ThumbnailDecodeLimiter {
  private let limit: Int
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func acquire() async {
    if active < limit {
      active += 1
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    if !waiters.isEmpty {
      let next = waiters.removeFirst()
      next.resume()
    } else {
      active = max(0, active - 1)
    }
  }
}

nonisolated enum AttachmentThumbnailLoader {
  /// NSCache is thread-safe at runtime but not annotated Sendable; this box
  /// satisfies strict concurrency for the shared static instance.
  private struct ThumbnailCache: @unchecked Sendable {
    let storage: NSCache<NSString, UIImage> = {
      let cache = NSCache<NSString, UIImage>()
      cache.countLimit = 256
      cache.totalCostLimit = 32 * 1_024 * 1_024
      return cache
    }()
  }

  private static let cache = ThumbnailCache()
  private static let decodeLimiter = ThumbnailDecodeLimiter(limit: 4)

  private static func storageKey(cacheKey: String, maxPixelSize: CGFloat) -> NSString {
    "\(cacheKey)::\(Int(maxPixelSize.rounded(.up)))" as NSString
  }

  private static func imageCost(_ image: UIImage) -> Int {
    if let cgImage = image.cgImage {
      return cgImage.bytesPerRow * cgImage.height
    }
    let scale = max(image.scale, 1)
    return Int(image.size.width * scale * image.size.height * scale * 4)
  }

  static func cachedImage(cacheKey: String, maxPixelSize: CGFloat) -> UIImage? {
    cache.storage.object(forKey: storageKey(cacheKey: cacheKey, maxPixelSize: maxPixelSize))
  }

  /// Bounded-concurrency async decode at `.utility` priority so a burst of
  /// image tiles never starves main-thread animations (e.g., sidebar close).
  /// When `alreadyDownsampled` is true (derived thumbnail bytes from the blob
  /// store), decodes directly with `preparingForDisplay()` without running a
  /// second ImageIO thumbnail pass.
  static func decodeImage(
    from data: Data,
    cacheKey: String,
    maxPixelSize: CGFloat,
    alreadyDownsampled: Bool = false
  ) async -> UIImage? {
    if let cached = cachedImage(cacheKey: cacheKey, maxPixelSize: maxPixelSize) {
      return cached
    }
    guard !Task.isCancelled else { return nil }
    await decodeLimiter.acquire()
    if Task.isCancelled {
      await decodeLimiter.release()
      return nil
    }
    let decoded = await Task.detached(priority: .utility) {
      if alreadyDownsampled {
        return Self.decodedDerivedImage(
          from: data,
          cacheKey: cacheKey,
          maxPixelSize: maxPixelSize
        )
      }
      return Self.downsampledImage(
        from: data,
        cacheKey: cacheKey,
        maxPixelSize: maxPixelSize
      )
    }.value
    await decodeLimiter.release()
    return decoded
  }

  /// Fast path for already-downsampled derived thumbnails: decodes once and
  /// prepares a GPU-ready display bitmap off the main thread. Falls back to
  /// ImageIO downsampling if the payload is larger than `maxPixelSize`.
  static func decodedDerivedImage(
    from data: Data,
    cacheKey: String,
    maxPixelSize: CGFloat
  ) -> UIImage? {
    let key = storageKey(cacheKey: cacheKey, maxPixelSize: maxPixelSize)
    if let cached = cache.storage.object(forKey: key) { return cached }

    if let raw = UIImage(data: data) {
      let maxSide = max(raw.size.width * raw.scale, raw.size.height * raw.scale)
      if maxSide > 0, maxSide <= maxPixelSize * 1.25 {
        let displayReady = raw.preparingForDisplay() ?? raw
        cache.storage.setObject(displayReady, forKey: key, cost: imageCost(displayReady))
        return displayReady
      }
    }
    return downsampledImage(from: data, cacheKey: cacheKey, maxPixelSize: maxPixelSize)
  }

  /// Downsampled decode via ImageIO so a 20 MB JPEG never materializes as a
  /// full-resolution bitmap just to fill a small tile. Callers must supply a
  /// stable unique key (attachment or entry ID).
  static func downsampledImage(
    from data: Data,
    cacheKey: String,
    maxPixelSize: CGFloat
  ) -> UIImage? {
    let key = storageKey(cacheKey: cacheKey, maxPixelSize: maxPixelSize)
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
    let raw = UIImage(cgImage: cgImage)
    let displayReady = raw.preparingForDisplay() ?? raw
    cache.storage.setObject(displayReady, forKey: key, cost: imageCost(displayReady))
    return displayReady
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
  @State private var loadFailed = false

  var body: some View {
    let maxPixelSize = sideLength * displayScale
    let cacheKey = "entry::\(entry.id.rawValue)"
    let resolvedImage = entry.isImage
      ? (image ?? AttachmentThumbnailLoader.cachedImage(cacheKey: cacheKey, maxPixelSize: maxPixelSize))
      : nil

    ZStack {
      if let resolvedImage {
        Image(uiImage: resolvedImage)
          .resizable()
          .scaledToFill()
          .frame(width: sideLength, height: sideLength)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(theme.borderColor.opacity(0.8), lineWidth: 0.75)
          )
      } else if entry.isImage && !loadFailed {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(theme.surfaceColor)
          .frame(width: sideLength, height: sideLength)
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(theme.borderColor.opacity(0.8), lineWidth: 0.75)
          )
          .overlay {
            Image(systemName: "photo")
              .font(.system(size: sideLength * 0.34, weight: .medium))
              .foregroundStyle(theme.secondaryForegroundColor.opacity(0.32))
          }
      } else {
        Image(systemName: entry.isImage ? "photo" : Self.fileSymbolName(for: entry))
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
      guard entry.isImage else {
        image = nil
        loadFailed = false
        return
      }
      if AttachmentThumbnailLoader.cachedImage(
        cacheKey: cacheKey,
        maxPixelSize: maxPixelSize
      ) != nil {
        return
      }
      image = nil
      loadFailed = false
      // Downsampled bytes are served from the blob store's persisted
      // derivative when available; the full original is never loaded for a tile.
      guard let bytes = await library.thumbnailData(for: entry, maxPixelSize: maxPixelSize) else {
        if !Task.isCancelled { loadFailed = true }
        return
      }
      let decoded = await AttachmentThumbnailLoader.decodeImage(
        from: bytes,
        cacheKey: cacheKey,
        maxPixelSize: maxPixelSize,
        alreadyDownsampled: true
      )
      guard !Task.isCancelled else { return }
      if let decoded {
        image = decoded
      } else {
        loadFailed = true
      }
    }
  }

  static func fileSymbolName(for entry: LibraryEntry) -> String {
    let mime = entry.mimeType.lowercased()
    let ext = (entry.filename as NSString).pathExtension.lowercased()

    if mime == "application/pdf" || ext == "pdf" {
      return "doc.richtext"
    }
    if mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "aac", "flac"].contains(ext) {
      return "waveform"
    }
    if mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "webm"].contains(ext) {
      return "film"
    }
    if mime == "text/csv" || mime.contains("spreadsheet") || ["csv", "tsv", "xls", "xlsx"].contains(ext) {
      return "tablecells"
    }
    if mime.contains("zip") || mime.contains("gzip") || mime.contains("tar") || ["zip", "gz", "tar", "7z"].contains(ext) {
      return "doc.zipper"
    }
    if mime == "application/json" || mime.contains("xml") || mime.contains("javascript")
      || ["json", "xml", "yaml", "yml", "swift", "py", "js", "ts", "tsx", "jsx", "html", "css", "sh", "sql"].contains(ext)
    {
      return "chevron.left.forwardslash.chevron.right"
    }
    if mime.hasPrefix("text/") || ["md", "markdown", "txt", "rtf", "log"].contains(ext) {
      return "doc.text"
    }
    return "doc"
  }
}
