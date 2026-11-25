import AppKit
import BYOKchatProviderCore
import CoreTransferable
import Foundation
import ImageIO
import QuickLook
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct MacDroppedImage: Transferable, Sendable {
  let data: Data

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(importedContentType: .image) { data in
      MacDroppedImage(data: data)
    }
  }
}

enum MacAttachmentImporter {
  static let maximumCount = 8
  static let maximumFileBytes = 20 * 1_024 * 1_024
  static let maximumTotalBytes = 40 * 1_024 * 1_024
  static let maximumImagePixelDimension = 4_096

  static func importURLs(_ urls: [URL]) async throws -> [ChatAttachment] {
    guard urls.count <= maximumCount else {
      throw ProviderError.invalidRequest("A message can include at most 8 attachments.")
    }

    return try await Task.detached(priority: .userInitiated) {
      var attachments: [ChatAttachment] = []
      attachments.reserveCapacity(urls.count)
      var totalBytes = 0

      for url in urls {
        let attachment = try loadURL(url)
        totalBytes += attachment.byteCount
        guard totalBytes <= maximumTotalBytes else {
          throw ProviderError.invalidRequest("Attachments in one message cannot exceed 40 MB total.")
        }
        attachments.append(attachment)
      }
      return attachments
    }.value
  }

  static func importDroppedImages(_ values: [MacDroppedImage]) async throws -> [ChatAttachment] {
    guard values.count <= maximumCount else {
      throw ProviderError.invalidRequest("A message can include at most 8 attachments.")
    }

    return try await Task.detached(priority: .userInitiated) {
      var attachments: [ChatAttachment] = []
      attachments.reserveCapacity(values.count)
      var totalBytes = 0

      for (index, value) in values.enumerated() {
        let attachment = try normalizedImageAttachment(
          data: value.data,
          suggestedName: "image-\(index + 1)"
        )
        totalBytes += attachment.byteCount
        guard totalBytes <= maximumTotalBytes else {
          throw ProviderError.invalidRequest("Attachments in one message cannot exceed 40 MB total.")
        }
        attachments.append(attachment)
      }
      return attachments
    }.value
  }

  @MainActor
  static func importPasteboard() async throws -> [ChatAttachment] {
    let pasteboard = NSPasteboard.general
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true
    ]
    if let values = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL],
      !values.isEmpty
    {
      return try await importURLs(values.map { $0 as URL })
    }

    let imageTypes = [
      NSPasteboard.PasteboardType(UTType.png.identifier),
      NSPasteboard.PasteboardType(UTType.jpeg.identifier),
      NSPasteboard.PasteboardType(UTType.tiff.identifier),
    ]
    for type in imageTypes {
      if let data = pasteboard.data(forType: type), !data.isEmpty {
        return [try normalizedImageAttachment(data: data, suggestedName: "clipboard-image")]
      }
    }

    throw ProviderError.invalidRequest("The clipboard does not contain an image or file.")
  }

  @MainActor
  static func pasteboardContainsAttachment() -> Bool {
    let pasteboard = NSPasteboard.general
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true
    ]
    if let values = pasteboard.readObjects(forClasses: [NSURL.self], options: options), !values.isEmpty {
      return true
    }
    return pasteboard.availableType(from: [
      NSPasteboard.PasteboardType(UTType.png.identifier),
      NSPasteboard.PasteboardType(UTType.jpeg.identifier),
      NSPasteboard.PasteboardType(UTType.tiff.identifier),
    ]) != nil
  }

  static func validateCombined(
    existing: [ChatAttachment],
    additions: [ChatAttachment]
  ) throws -> [ChatAttachment] {
    let combined = existing + additions
    guard combined.count <= maximumCount else {
      throw ProviderError.invalidRequest("A message can include at most 8 attachments.")
    }
    guard combined.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= maximumFileBytes }) else {
      throw ProviderError.invalidRequest("Each attachment must be non-empty and no larger than 20 MB.")
    }
    guard combined.reduce(0, { $0 + $1.byteCount }) <= maximumTotalBytes else {
      throw ProviderError.invalidRequest("Attachments in one message cannot exceed 40 MB total.")
    }
    return combined
  }

  private static func loadURL(_ url: URL) throws -> ChatAttachment {
    let access = url.startAccessingSecurityScopedResource()
    defer {
      if access { url.stopAccessingSecurityScopedResource() }
    }

    let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
    if let fileSize = values.fileSize, fileSize > maximumFileBytes {
      throw ProviderError.invalidRequest("\(url.lastPathComponent) is larger than 20 MB.")
    }

    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard !data.isEmpty else {
      throw ProviderError.invalidRequest("\(url.lastPathComponent) is empty.")
    }
    guard data.count <= maximumFileBytes else {
      throw ProviderError.invalidRequest("\(url.lastPathComponent) is larger than 20 MB.")
    }

    let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
    if type.conforms(to: .image) {
      return try normalizedImageAttachment(
        data: data,
        suggestedName: url.deletingPathExtension().lastPathComponent
      )
    }

    return ChatAttachment(
      kind: .file,
      filename: url.lastPathComponent,
      mimeType: type.preferredMIMEType ?? "application/octet-stream",
      data: data
    )
  }

  static func normalizedImageAttachment(data: Data, suggestedName: String) throws -> ChatAttachment {
    guard !data.isEmpty else {
      throw ProviderError.invalidRequest("The selected image is empty.")
    }
    guard data.count <= maximumFileBytes else {
      throw ProviderError.invalidRequest("The selected image is larger than 20 MB.")
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw ProviderError.invalidRequest("The selected image could not be read.")
    }

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumImagePixelDimension,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(
      source,
      0,
      thumbnailOptions as CFDictionary
    ) else {
      throw ProviderError.invalidRequest("The selected image could not be decoded.")
    }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else {
      throw ProviderError.invalidRequest("The selected image could not be converted.")
    }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
      throw ProviderError.invalidRequest("The selected image could not be converted.")
    }

    let jpeg = output as Data
    guard !jpeg.isEmpty, jpeg.count <= maximumFileBytes else {
      throw ProviderError.invalidRequest("The selected image is larger than 20 MB after conversion.")
    }
    let base = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
    return ChatAttachment(
      kind: .image,
      filename: (base.isEmpty ? "image" : base) + ".jpg",
      mimeType: "image/jpeg",
      data: jpeg
    )
  }
}

enum MacAttachmentPresentation {
  case composer
  case message

  var imageSize: CGSize {
    switch self {
    case .composer: CGSize(width: 96, height: 76)
    case .message: CGSize(width: 132, height: 112)
    }
  }

  var fileWidth: CGFloat {
    switch self {
    case .composer: 132
    case .message: 156
    }
  }
}

struct MacAttachmentStrip: View {
  let attachments: [ChatAttachment]
  var presentation: MacAttachmentPresentation = .message
  var remove: ((String) -> Void)?
  var addAttachment: (() -> Void)? = nil
  var maxAttachments: Int = MacAttachmentImporter.maximumCount
  var isImportingAttachments: Bool = false
  var onOpenAttachment: ((ChatAttachment) -> Void)? = nil
  var saveToLibrary: ((ChatAttachment) -> Void)? = nil
  var loadThumbnail: ((String, CGFloat) async -> Data?)?

  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: 9) {
        ForEach(attachments) { attachment in
          MacAttachmentTile(
            attachment: attachment,
            presentation: presentation,
            remove: remove,
            onOpenAttachment: onOpenAttachment,
            saveToLibrary: saveToLibrary,
            loadThumbnail: loadThumbnail
          )
        }

        if presentation == .composer,
          attachments.count < maxAttachments,
          let addAttachment
        {
          addAttachmentTile(action: addAttachment)
        }
      }
      .padding(.vertical, 2)
    }
    .scrollIndicators(.hidden)
    .frame(height: presentation.imageSize.height + 4)
  }

  private func addAttachmentTile(action: @escaping () -> Void) -> some View {
    let tileShape = RoundedRectangle(cornerRadius: 11, style: .continuous)
    return Button(action: action) {
      VStack(spacing: 6) {
        if isImportingAttachments {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "plus")
            .font(.system(size: 18, weight: .semibold))
        }
        Text(isImportingAttachments ? "Adding" : "Add")
          .font(.system(size: 11, weight: .semibold))
      }
      .foregroundStyle(.secondary)
      .frame(width: 72, height: presentation.imageSize.height)
      .background(Color.primary.opacity(0.03), in: tileShape)
      .overlay(
        tileShape.stroke(
          Color.primary.opacity(0.18),
          style: StrokeStyle(lineWidth: 0.9, dash: [5, 4])
        )
      )
      .contentShape(tileShape)
    }
    .buttonStyle(.plain)
    .disabled(isImportingAttachments)
    .help(isImportingAttachments ? "Importing attachments…" : "Add another attachment")
    .accessibilityLabel(isImportingAttachments ? "Importing attachment" : "Add another attachment")
  }
}

@MainActor
private final class MacAttachmentThumbnailCache {
  static let shared = MacAttachmentThumbnailCache()

  private let storage: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 96
    cache.totalCostLimit = 24 * 1_024 * 1_024
    return cache
  }()

  func image(forKey key: String) -> NSImage? {
    storage.object(forKey: key as NSString)
  }

  func insert(_ image: NSImage, forKey key: String, byteCost: Int) {
    storage.setObject(image, forKey: key as NSString, cost: max(1, byteCost))
  }
}

private struct MacDecodedAttachmentBitmap: @unchecked Sendable {
  let cgImage: CGImage
  let pointSize: NSSize
  let byteCost: Int
}

private struct MacAttachmentTile: View {
  let attachment: ChatAttachment
  let presentation: MacAttachmentPresentation
  let remove: ((String) -> Void)?
  let onOpenAttachment: ((ChatAttachment) -> Void)?
  let saveToLibrary: ((ChatAttachment) -> Void)?
  let loadThumbnail: ((String, CGFloat) async -> Data?)?

  @Environment(\.displayScale) private var displayScale
  @State private var image: NSImage?
  @State private var unavailable = false

  private var targetMaxPixelSize: CGFloat {
    max(64, max(presentation.imageSize.width, presentation.imageSize.height) * displayScale)
  }

  private var thumbnailCacheKey: String {
    "\(attachment.id)@\(Int(targetMaxPixelSize.rounded()))"
  }

  private var resolvedImage: NSImage? {
    image ?? MacAttachmentThumbnailCache.shared.image(forKey: thumbnailCacheKey)
  }

  private var hasContextMenu: Bool {
    if presentation == .composer {
      return remove != nil
    }
    return onOpenAttachment != nil || saveToLibrary != nil
  }

  var body: some View {
    let content = ZStack(alignment: .topTrailing) {
      if presentation == .message, let onOpenAttachment {
        Button {
          onOpenAttachment(attachment)
        } label: {
          tileBody
        }
        .buttonStyle(.plain)
        .help("Preview \(attachment.filename)")
        .accessibilityHint("Click to preview")
      } else {
        tileBody
      }

      if let remove {
        Button {
          remove(attachment.id)
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 21, height: 21)
            .background(.black.opacity(0.65), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(5)
        .accessibilityLabel("Remove \(attachment.filename)")
      }
    }
    .task(id: attachment.id) {
      await loadImageIfNeeded()
    }

    if hasContextMenu {
      content.contextMenu {
        tileContextMenu
      }
    } else {
      content
    }
  }

  @ViewBuilder
  private var tileBody: some View {
    if attachment.isImage {
      imageTile
    } else {
      fileTile
    }
  }

  @ViewBuilder
  private var tileContextMenu: some View {
    if presentation == .composer, let remove {
      Button("Remove", systemImage: "trash", role: .destructive) {
        remove(attachment.id)
      }
    } else if presentation == .message {
      if let onOpenAttachment {
        Button("Preview", systemImage: "eye") {
          onOpenAttachment(attachment)
        }
      }
      if let saveToLibrary {
        Button("Save to Library", systemImage: "books.vertical") {
          saveToLibrary(attachment)
        }
      }
    }
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: presentation == .composer ? 11 : 13, style: .continuous)
  }

  private var imageTile: some View {
    ZStack {
      Color.primary.opacity(0.035)
      if let resolvedImage {
        Image(nsImage: resolvedImage)
          .resizable()
          .scaledToFill()
      } else if unavailable {
        VStack(spacing: 5) {
          Image(systemName: "photo.badge.exclamationmark")
          Text("Unavailable")
            .font(.caption2)
        }
        .foregroundStyle(.secondary)
      } else {
        ProgressView()
          .controlSize(.small)
      }
    }
    .frame(width: presentation.imageSize.width, height: presentation.imageSize.height)
    .clipShape(shape)
    .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 1))
    .accessibilityLabel("Image attachment \(attachment.filename)")
  }

  private var fileTile: some View {
    VStack(alignment: .leading, spacing: 5) {
      Image(systemName: fileSymbol)
        .font(.system(size: presentation == .composer ? 19 : 23, weight: .semibold))
        .foregroundStyle(Color.accentColor)

      Spacer(minLength: 0)

      Text(attachment.filename)
        .font(.caption.weight(.semibold))
        .lineLimit(2)

      Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .frame(
      width: presentation.fileWidth,
      height: presentation.imageSize.height,
      alignment: .leading
    )
    .background(Color.primary.opacity(0.035), in: shape)
    .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 1))
    .accessibilityElement(children: .combine)
  }

  private var fileSymbol: String {
    let mime = attachment.mimeType.lowercased()
    if mime.contains("pdf") { return "doc.richtext.fill" }
    if mime.contains("json") || mime.contains("javascript") { return "curlybraces.square.fill" }
    if attachment.isTextLike { return "doc.text.fill" }
    return "doc.fill"
  }

  private func loadImageIfNeeded() async {
    guard attachment.isImage else { return }
    let key = thumbnailCacheKey
    if let cached = MacAttachmentThumbnailCache.shared.image(forKey: key) {
      image = cached
      unavailable = false
      return
    }

    let maxPixelSize = targetMaxPixelSize
    let sourceData: Data?
    if !attachment.data.isEmpty {
      sourceData = attachment.data
    } else if let loadThumbnail {
      sourceData = await loadThumbnail(attachment.id, maxPixelSize)
    } else {
      sourceData = nil
    }

    guard !Task.isCancelled else { return }
    guard let sourceData, !sourceData.isEmpty else {
      unavailable = true
      return
    }

    let bitmap = await Task.detached(priority: .utility) {
      Self.decodeDownsampledBitmap(from: sourceData, maxPixelSize: maxPixelSize)
    }.value

    guard !Task.isCancelled else { return }
    if let bitmap {
      let decoded = NSImage(cgImage: bitmap.cgImage, size: bitmap.pointSize)
      MacAttachmentThumbnailCache.shared.insert(decoded, forKey: key, byteCost: bitmap.byteCost)
      image = decoded
      unavailable = false
    } else {
      unavailable = true
    }
  }

  private nonisolated static func decodeDownsampledBitmap(
    from data: Data,
    maxPixelSize: CGFloat
  ) -> MacDecodedAttachmentBitmap? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maxPixelSize.rounded())),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
      ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let byteCost = max(1, cgImage.bytesPerRow * cgImage.height)
    return MacDecodedAttachmentBitmap(
      cgImage: cgImage,
      pointSize: NSSize(width: cgImage.width, height: cgImage.height),
      byteCost: byteCost
    )
  }
}

struct MacAttachmentPreviewSheet: View {
  let attachment: ChatAttachment
  let loadData: (String) async -> Data?
  var saveToLibrary: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  @State private var loadedImage: NSImage?
  @State private var quickLookURL: URL?
  @State private var tempDirectory: URL?
  @State private var errorMessage: String?
  @State private var isLoading = true
  @State private var zoomScale: CGFloat = 1.0

  private static let minZoom: CGFloat = 1.0
  private static let maxZoom: CGFloat = 5.0

  var body: some View {
    VStack(spacing: 0) {
      headerBar
      Divider()
      previewContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 720, idealWidth: 880, minHeight: 540, idealHeight: 660)
    .background(MacDesignTokens.Colors.canvas)
    .task(id: attachment.id) {
      await loadPreview()
    }
    .onDisappear {
      cleanupTempDirectory()
    }
  }

  private var headerBar: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(attachment.filename)
          .font(.headline)
          .lineLimit(1)
        Text(
          "\(attachment.mimeType) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))"
        )
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .lineLimit(1)
      }

      Spacer(minLength: 8)

      if loadedImage != nil {
        HStack(spacing: 4) {
          Button {
            withAnimation(.easeOut(duration: 0.15)) {
              zoomScale = max(Self.minZoom, zoomScale - 0.5)
            }
          } label: {
            Image(systemName: "minus.magnifyingglass")
          }
          .buttonStyle(MacIconButtonStyle())
          .disabled(zoomScale <= Self.minZoom + 0.01)
          .help("Zoom Out")
          .accessibilityLabel("Zoom out")

          Button {
            withAnimation(.easeOut(duration: 0.15)) {
              zoomScale = Self.minZoom
            }
          } label: {
            Text("\(Int((zoomScale * 100).rounded()))%")
              .font(.caption.monospacedDigit())
              .frame(minWidth: 42)
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          .disabled(abs(zoomScale - Self.minZoom) < 0.01)
          .help("Reset Zoom")
          .accessibilityLabel("Reset zoom")

          Button {
            withAnimation(.easeOut(duration: 0.15)) {
              zoomScale = min(Self.maxZoom, zoomScale + 0.5)
            }
          } label: {
            Image(systemName: "plus.magnifyingglass")
          }
          .buttonStyle(MacIconButtonStyle())
          .disabled(zoomScale >= Self.maxZoom - 0.01)
          .help("Zoom In")
          .accessibilityLabel("Zoom in")
        }
      }

      if let saveToLibrary {
        Button("Save to Library", systemImage: "books.vertical", action: saveToLibrary)
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
      }

      Button("Done") {
        dismiss()
      }
      .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
      .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 16)
    .frame(height: 54)
    .background(MacDesignTokens.Colors.surface)
  }

  @ViewBuilder
  private var previewContent: some View {
    if isLoading {
      ProgressView("Loading preview…")
        .controlSize(.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let loadedImage {
      MacZoomableImageView(
        image: loadedImage,
        scale: $zoomScale,
        minScale: Self.minZoom,
        maxScale: Self.maxZoom
      )
    } else if let quickLookURL {
      MacAttachmentQuickLookView(url: quickLookURL)
    } else {
      ContentUnavailableView(
        "Preview Unavailable",
        systemImage: "exclamationmark.triangle",
        description: Text(errorMessage ?? "The saved bytes for \(attachment.filename) are unavailable.")
      )
    }
  }

  private func loadPreview() async {
    cleanupTempDirectory()
    loadedImage = nil
    quickLookURL = nil
    errorMessage = nil
    zoomScale = Self.minZoom
    isLoading = true
    defer { isLoading = false }

    let data: Data?
    if !attachment.data.isEmpty {
      data = attachment.data
    } else {
      data = await loadData(attachment.id)
    }
    guard !Task.isCancelled else { return }

    guard let data, !data.isEmpty else {
      errorMessage = "The saved bytes for \(attachment.filename) are unavailable."
      return
    }

    if attachment.isImage, let decoded = NSImage(data: data) {
      loadedImage = decoded
      return
    }

    let safeName = Self.safeFilename(attachment.filename)
    let result: Result<(directory: URL, fileURL: URL), Error> = await Task.detached(
      priority: .userInitiated
    ) {
      do {
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent(
            "BYOKchat-attachment-preview-\(UUID().uuidString)",
            isDirectory: true
          )
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent(safeName, isDirectory: false)
        try data.write(to: fileURL, options: .atomic)
        return .success((directory, fileURL))
      } catch {
        return .failure(error)
      }
    }.value

    guard !Task.isCancelled else {
      if case .success(let created) = result {
        try? FileManager.default.removeItem(at: created.directory)
      }
      return
    }

    switch result {
    case .success(let created):
      tempDirectory = created.directory
      quickLookURL = created.fileURL
    case .failure(let error):
      MacAppAnalytics.reportError("attachment_preview_failed", component: "attachments")
      errorMessage = error.localizedDescription
    }
  }

  private func cleanupTempDirectory() {
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
      self.tempDirectory = nil
    }
    quickLookURL = nil
  }

  private static func safeFilename(_ filename: String) -> String {
    let value = filename
      .replacingOccurrences(of: "/", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "attachment" : value
  }
}

private struct MacZoomableImageView: View {
  let image: NSImage
  @Binding var scale: CGFloat
  let minScale: CGFloat
  let maxScale: CGFloat

  @State private var gestureMagnification: CGFloat = 1.0

  private var effectiveScale: CGFloat {
    min(maxScale, max(minScale, scale * gestureMagnification))
  }

  var body: some View {
    GeometryReader { geometry in
      let containerSize = geometry.size
      let baseSize = fittedSize(for: image.size, inside: containerSize)
      let scaledWidth = baseSize.width * effectiveScale
      let scaledHeight = baseSize.height * effectiveScale

      ScrollView([.horizontal, .vertical]) {
        ZStack {
          Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: scaledWidth, height: scaledHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        }
        .frame(
          minWidth: max(containerSize.width, scaledWidth + 32),
          minHeight: max(containerSize.height, scaledHeight + 32)
        )
      }
      .gesture(
        MagnifyGesture()
          .onChanged { value in
            gestureMagnification = value.magnification
          }
          .onEnded { value in
            scale = min(maxScale, max(minScale, scale * value.magnification))
            gestureMagnification = 1.0
          }
      )
      .onTapGesture(count: 2) {
        withAnimation(.easeOut(duration: 0.18)) {
          scale = abs(scale - minScale) < 0.05 ? min(2.5, maxScale) : minScale
        }
      }
    }
    .background(Color.primary.opacity(0.03))
  }

  private func fittedSize(for imageSize: CGSize, inside container: CGSize) -> CGSize {
    let availableWidth = max(1, container.width - 32)
    let availableHeight = max(1, container.height - 32)
    guard imageSize.width > 0, imageSize.height > 0 else {
      return CGSize(width: availableWidth, height: availableHeight)
    }
    let widthRatio = availableWidth / imageSize.width
    let heightRatio = availableHeight / imageSize.height
    let ratio = min(widthRatio, heightRatio)
    return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
  }
}

private final class MacAttachmentPreviewItem: NSObject, QLPreviewItem {
  let previewItemURL: URL?

  init(url: URL) {
    previewItemURL = url
  }
}

private struct MacAttachmentQuickLookView: NSViewRepresentable {
  let url: URL

  final class Coordinator {
    var item: MacAttachmentPreviewItem?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> QLPreviewView {
    let view = QLPreviewView(frame: .zero, style: .normal)!
    view.autostarts = true
    let item = MacAttachmentPreviewItem(url: url)
    context.coordinator.item = item
    view.previewItem = item
    return view
  }

  func updateNSView(_ view: QLPreviewView, context: Context) {
    guard context.coordinator.item?.previewItemURL != url else { return }
    let item = MacAttachmentPreviewItem(url: url)
    context.coordinator.item = item
    view.previewItem = item
    view.refreshPreviewItem()
  }
}
