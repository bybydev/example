import AppKit
import BYOKchatProviderCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum MacProjectAccentOption: String, CaseIterable, Identifiable {
  case blue, indigo, purple, pink, orange, teal, green

  var id: String { rawValue }
  var title: String { rawValue.capitalized }

  var color: Color {
    switch self {
    case .blue: .blue
    case .indigo: .indigo
    case .purple: .purple
    case .pink: .pink
    case .orange: .orange
    case .teal: .teal
    case .green: .green
    }
  }
}

/// Nonisolated helpers for project reference-file metadata, previews, and
/// off-main-thread file import validation and image normalization.
enum MacProjectFileImportSupport {
  private static let explicitTextMIMETypes: Set<String> = [
    "application/json",
    "application/ld+json",
    "application/xml",
    "application/xhtml+xml",
    "application/javascript",
    "application/ecmascript",
    "application/typescript",
    "application/x-yaml",
    "application/yaml",
    "application/toml",
    "application/sql",
    "application/csv",
    "application/x-sh",
    "application/x-python-code",
    "application/rtf",
  ]

  static func isImageMIMEType(_ mimeType: String) -> Bool {
    mimeType.lowercased().hasPrefix("image/")
  }

  static func isTextLikeMIMEType(_ mimeType: String) -> Bool {
    let normalized = mimeType
      .split(separator: ";", maxSplits: 1)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    guard !normalized.isEmpty else { return false }
    if normalized.hasPrefix("text/") { return true }
    if explicitTextMIMETypes.contains(normalized) { return true }
    if normalized.hasSuffix("+json") || normalized.hasSuffix("+xml") { return true }
    if let type = UTType(mimeType: normalized), type.conforms(to: .text) { return true }
    return false
  }

  static func safePreviewFilename(_ filename: String) -> String {
    let sanitized = filename
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: "\0", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
      return "file"
    }
    return sanitized
  }

  /// Reads and validates security-scoped files off `@MainActor`, rejecting
  /// directories/non-regular files, empty files, and >40 MB totals upfront,
  /// and normalizing unsupported image formats (such as HEIC, HEIF, WebP, or
  /// TIFF) to JPEG via AppKit.
  static func importFiles(
    from urls: [URL],
    existingCount: Int,
    existingBytes: Int
  ) throws -> [ProjectFile] {
    guard urls.count <= ProjectWorkspaceStore.maxFileCount - existingCount else {
      throw ProjectWorkspaceError.tooManyFiles
    }
    let maximumFileBytes = ProjectWorkspaceStore.maxFileBytes
    let maximumTotalBytes = ProjectWorkspaceStore.maxTotalFileBytes
    guard existingBytes <= maximumTotalBytes else {
      throw ProjectWorkspaceError.filesTooLarge
    }

    var accessedURLs: [URL] = []
    defer { for url in accessedURLs { url.stopAccessingSecurityScopedResource() } }

    var inspected: [(url: URL, type: UTType)] = []
    var preflightBytes = existingBytes
    for url in urls {
      if url.startAccessingSecurityScopedResource() { accessedURLs.append(url) }
      let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
      guard values.isRegularFile == true else {
        throw ProviderError.invalidRequest("\(url.lastPathComponent) is not a readable regular file.")
      }
      guard let fileSize = values.fileSize, fileSize >= 0 else {
        throw ProviderError.invalidRequest(
          "The size of \(url.lastPathComponent) is unavailable. Download it locally and try again."
        )
      }
      guard fileSize > 0 else {
        throw ProjectWorkspaceError.emptyFile(url.lastPathComponent)
      }
      guard fileSize <= maximumFileBytes else {
        throw ProjectWorkspaceError.fileTooLarge(url.lastPathComponent)
      }
      guard fileSize <= maximumTotalBytes - preflightBytes else {
        throw ProjectWorkspaceError.filesTooLarge
      }
      preflightBytes += fileSize
      let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
      inspected.append((url, type))
    }

    var additions: [ProjectFile] = []
    var actualBytes = existingBytes
    for (url, type) in inspected {
      let rawData = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard !rawData.isEmpty else {
        throw ProjectWorkspaceError.emptyFile(url.lastPathComponent)
      }

      let prepared = try preparedFile(
        url: url,
        type: type,
        rawData: rawData,
        maxBytes: maximumFileBytes
      )
      guard !prepared.data.isEmpty else {
        throw ProjectWorkspaceError.emptyFile(prepared.filename)
      }
      guard prepared.data.count <= maximumFileBytes else {
        throw ProjectWorkspaceError.fileTooLarge(prepared.filename)
      }
      guard prepared.data.count <= maximumTotalBytes - actualBytes else {
        throw ProjectWorkspaceError.filesTooLarge
      }
      actualBytes += prepared.data.count
      additions.append(
        ProjectFile(
          filename: prepared.filename,
          mimeType: prepared.mimeType,
          data: prepared.data
        )
      )
    }
    return additions
  }

  static func normalizedJPEG(from data: Data) -> Data? {
    if let image = NSImage(data: data),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    {
      let bitmap = NSBitmapImageRep(cgImage: cgImage)
      if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]),
        !jpeg.isEmpty
      {
        return jpeg
      }
    }
    if let bitmap = NSBitmapImageRep(data: data),
      let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]),
      !jpeg.isEmpty
    {
      return jpeg
    }
    return nil
  }

  private static func preparedFile(
    url: URL,
    type: UTType,
    rawData: Data,
    maxBytes: Int
  ) throws -> (filename: String, mimeType: String, data: Data) {
    if type.conforms(to: .image) {
      let preservesOriginal = (type == .png || type == .jpeg || type == .gif)
        && rawData.count <= maxBytes
      if preservesOriginal {
        return (
          filename: url.lastPathComponent,
          mimeType: type.preferredMIMEType ?? "image/jpeg",
          data: rawData
        )
      }
      guard let jpeg = normalizedJPEG(from: rawData) else {
        throw ProviderError.invalidRequest(
          "The image '\(url.lastPathComponent)' could not be converted to a supported format."
        )
      }
      let stem = url.deletingPathExtension().lastPathComponent
      let base = stem.isEmpty ? "image" : stem
      return (filename: base + ".jpg", mimeType: "image/jpeg", data: jpeg)
    }
    return (
      filename: url.lastPathComponent,
      mimeType: type.preferredMIMEType ?? "application/octet-stream",
      data: rawData
    )
  }
}

/// Rough size context for attach decisions: text averages ~4 bytes per token, so the
/// estimate tells users why a large text reference file may exceed a model's context
/// window. Binary/image files omit the misleading byte-division token estimate.
func macProjectFileDetail(_ file: ProjectFile) -> String {
  let size = ByteCountFormatter.string(
    fromByteCount: Int64(file.byteCount),
    countStyle: .file
  )
  guard file.byteCount > 0, MacProjectFileImportSupport.isTextLikeMIMEType(file.mimeType) else {
    return size
  }
  let estimatedTokens = max(1, file.byteCount / 4)
  return "\(size) · ~\(estimatedTokens.formatted()) tokens"
}
