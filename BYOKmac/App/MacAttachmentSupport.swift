import AppKit
import BYOKchatProviderCore
import CoreTransferable
import Foundation
import ImageIO
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
  var loadThumbnail: ((String, CGFloat) async -> Data?)?

  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: 9) {
        ForEach(attachments) { attachment in
          MacAttachmentTile(
            attachment: attachment,
            presentation: presentation,
            remove: remove,
            loadThumbnail: loadThumbnail
          )
        }
      }
      .padding(.vertical, 2)
    }
    .scrollIndicators(.hidden)
    .frame(height: presentation.imageSize.height + 4)
  }
}

private struct MacAttachmentTile: View {
  let attachment: ChatAttachment
  let presentation: MacAttachmentPresentation
  let remove: ((String) -> Void)?
  let loadThumbnail: ((String, CGFloat) async -> Data?)?

  @Environment(\.displayScale) private var displayScale
  @State private var image: NSImage?
  @State private var unavailable = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      if attachment.isImage {
        imageTile
      } else {
        fileTile
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
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: presentation == .composer ? 11 : 13, style: .continuous)
  }

  private var imageTile: some View {
    ZStack {
      Color.primary.opacity(0.035)
      if let image {
        Image(nsImage: image)
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
    if !attachment.data.isEmpty {
      image = NSImage(data: attachment.data)
      unavailable = image == nil
      if image != nil { return }
    }
    guard let loadThumbnail else {
      unavailable = true
      return
    }
    let bytes = await loadThumbnail(
      attachment.id,
      max(presentation.imageSize.width, presentation.imageSize.height) * displayScale
    )
    guard let bytes, !bytes.isEmpty, let decoded = NSImage(data: bytes) else {
      unavailable = true
      return
    }
    image = decoded
    unavailable = false
  }
}
