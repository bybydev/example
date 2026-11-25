import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One savable image found inside an assistant reply.
struct MacResponseImageCandidate: Identifiable, Equatable, Sendable {
  enum Source: Equatable, Sendable {
    case url(URL)
    case data(Data, fileExtension: String)
  }

  let id: String
  let label: String
  let source: Source
}

/// Validated image payload ready to save into the Library.
struct MacScannedResponseImage: Equatable, Sendable {
  let candidate: MacResponseImageCandidate
  let data: Data
  let filename: String
  let mimeType: String
  let pixelWidth: Int?
  let pixelHeight: Int?
}

enum MacResponseImageScanner {
  /// Fast presence check used to decide whether to show "Save Images…" in a
  /// message menu without base64-decoding or hashing inline image payloads.
  static func hasImageCandidates(in content: String) -> Bool {
    guard !content.isEmpty, content.contains("![") else {
      return false
    }
    return hasImageCandidates(in: MacAnswerContentParser.parse(content))
  }

  /// Reuses already-parsed answer blocks to avoid parsing large responses twice.
  static func hasImageCandidates(in blocks: [MacAnswerContentBlock]) -> Bool {
    for block in blocks {
      let rawMarkdown: String
      switch block {
      case .markdown(let text):
        rawMarkdown = text
      case .table(let table):
        rawMarkdown = table.rawMarkdown
      case .code, .math:
        continue
      }
      guard rawMarkdown.contains("![") else { continue }
      let markdown = MacAnswerContentParser.stripInlineCodeSpans(from: rawMarkdown)
      guard markdown.contains("![") else { continue }
      var found = false
      forEachMarkdownImage(in: markdown) { _, rawURL in
        if hasValidDataURIHeader(rawURL) {
          found = true
          return false
        }
        if rawURL.utf8.count <= 4_096,
          let url = URL(string: String(rawURL)),
          MacAnswerContentParser.isValidBrowsableURL(url)
        {
          found = true
          return false
        }
        return true
      }
      if found { return true }
    }
    return false
  }

  /// Finds markdown image references and inline `data:image/*;base64,...` images
  /// across markdown paragraphs and GFM tables, skipping fenced/inline code and
  /// display math blocks. Results are deduplicated by source location so the
  /// same image linked twice is offered once.
  static func imageCandidates(in content: String) -> [MacResponseImageCandidate] {
    guard !content.isEmpty, content.contains("![") else {
      return []
    }

    var candidates: [MacResponseImageCandidate] = []
    var seen = Set<String>()

    for block in MacAnswerContentParser.parse(content) {
      let rawMarkdown: String
      switch block {
      case .markdown(let text):
        rawMarkdown = text
      case .table(let table):
        rawMarkdown = table.rawMarkdown
      case .code, .math:
        continue
      }
      guard rawMarkdown.contains("![") else { continue }
      let markdown = MacAnswerContentParser.stripInlineCodeSpans(from: rawMarkdown)
      guard markdown.contains("![") else { continue }
      forEachMarkdownImage(in: markdown) { altSlice, urlSlice in
        let alt = altSlice.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = String(urlSlice)

        guard seen.insert(rawURL).inserted else { return true }

        if hasValidDataURIHeader(urlSlice) {
          if let decoded = decodeDataURI(rawURL) {
            let digest = SHA256.hash(data: Data(rawURL.utf8))
              .prefix(16)
              .map { String(format: "%02x", $0) }
              .joined()
            candidates.append(
              MacResponseImageCandidate(
                id: "data::\(digest)",
                label: alt.isEmpty ? "image-\(candidates.count + 1).\(decoded.extension)" : alt,
                source: .data(decoded.data, fileExtension: decoded.extension)
              )
            )
          }
        } else if let url = URL(string: rawURL), MacAnswerContentParser.isValidBrowsableURL(url) {
          let derived = sanitizeFilename(url.lastPathComponent)
          candidates.append(
            MacResponseImageCandidate(
              id: rawURL,
              label: alt.isEmpty ? (derived.isEmpty ? "image" : derived) : alt,
              source: .url(url)
            )
          )
        }
        return true
      }
    }
    return candidates
  }

  /// Linear-time scanner for `![alt](url ...)` markdown image syntax that avoids
  /// regex backtracking on multi-megabyte `data:image/...;base64,...` strings.
  private static func forEachMarkdownImage(
    in markdown: String,
    _ visit: (_ alt: Substring, _ url: Substring) -> Bool
  ) {
    var cursor = markdown.startIndex
    while let openRange = markdown.range(of: "![", range: cursor..<markdown.endIndex) {
      let altStart = openRange.upperBound
      guard let closeBracket = markdown[altStart...].firstIndex(of: "]") else {
        break
      }
      let afterBracket = markdown.index(after: closeBracket)
      guard afterBracket < markdown.endIndex, markdown[afterBracket] == "(" else {
        cursor = afterBracket
        continue
      }
      let urlStart = markdown.index(after: afterBracket)
      var idx = urlStart
      var parenDepth = 0
      var urlEnd: String.Index?
      var closingParen: String.Index?

      while idx < markdown.endIndex {
        let ch = markdown[idx]
        if ch == "(" {
          parenDepth += 1
        } else if ch == ")" {
          if parenDepth == 0 {
            if urlEnd == nil { urlEnd = idx }
            closingParen = idx
            break
          }
          parenDepth -= 1
        } else if ch == "\n" || ch == "\r" {
          break
        } else if ch.isWhitespace {
          if urlEnd == nil {
            urlEnd = idx
          }
        }
        idx = markdown.index(after: idx)
      }

      guard let closingParen, let urlEnd, urlEnd > urlStart else {
        cursor = urlStart
        continue
      }

      let alt = markdown[altStart..<closeBracket]
      let url = markdown[urlStart..<urlEnd]
      if !visit(alt, url) {
        return
      }
      cursor = markdown.index(after: closingParen)
    }
  }

  /// Fetches bytes for a candidate. Returns nil on failure, empty payload, or
  /// when the payload exceeds `maxByteCount`.
  static func fetchData(
    for source: MacResponseImageCandidate.Source,
    session: URLSession = .shared,
    maxByteCount: Int
  ) async -> Data? {
    switch source {
    case .data(let data, _):
      return !data.isEmpty && data.count <= maxByteCount ? data : nil
    case .url(let url):
      guard MacAnswerContentParser.isValidBrowsableURL(url) else { return nil }
      var request = URLRequest(url: url)
      request.timeoutInterval = 15
      guard let (data, response) = try? await session.data(for: request),
        let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode),
        !data.isEmpty,
        data.count <= maxByteCount
      else { return nil }
      return data
    }
  }

  /// Fetches (or reuses cached bytes), validates image encoding via ImageIO, and
  /// resolves filename, MIME type, and pixel dimensions for one candidate.
  static func resolveImage(
    for candidate: MacResponseImageCandidate,
    fallbackIndex: Int,
    session: URLSession = .shared,
    maxByteCount: Int = MacMarkdownImageSupport.maxByteCount
  ) async -> MacScannedResponseImage? {
    let rawData: Data?
    if case .url(let url) = candidate.source,
      session === URLSession.shared,
      let cached = MacMarkdownImageSupport.cachedRawBytes(
        for: MacMarkdownImageSupport.cacheKey(for: url)
      ),
      !cached.isEmpty,
      cached.count <= maxByteCount
    {
      rawData = cached
    } else {
      rawData = await fetchData(
        for: candidate.source,
        session: session,
        maxByteCount: maxByteCount
      )
    }

    guard let data = rawData,
      let dimensions = validateImageData(data)
    else { return nil }

    let initialFilename = suggestedFilename(
      for: candidate.source,
      fallbackIndex: fallbackIndex
    )
    let resolvedMimeType = mimeType(for: data, filename: initialFilename)
    let filename = suggestedFilename(
      for: candidate.source,
      fallbackIndex: fallbackIndex,
      resolvedMimeType: resolvedMimeType
    )

    return MacScannedResponseImage(
      candidate: candidate,
      data: data,
      filename: filename,
      mimeType: resolvedMimeType,
      pixelWidth: dimensions.width > 0 ? dimensions.width : nil,
      pixelHeight: dimensions.height > 0 ? dimensions.height : nil
    )
  }

  /// Validates that `data` decodes as a real image via ImageIO and returns its
  /// pixel dimensions, rejecting HTML error pages or corrupt payloads.
  static func validateImageData(_ data: Data) -> (width: Int, height: Int)? {
    guard !data.isEmpty,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { return nil }

    if let typeIdentifier = CGImageSourceGetType(source) as String?,
      let utType = UTType(typeIdentifier),
      !utType.conforms(to: .image)
    {
      return nil
    }

    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0,
      height > 0
    {
      return (width, height)
    }

    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
      cgImage.width > 0,
      cgImage.height > 0
    else { return nil }
    return (cgImage.width, cgImage.height)
  }

  static func isValidImageData(_ data: Data) -> Bool {
    validateImageData(data) != nil
  }

  static func decodeThumbnailCGImage(from data: Data, maxPixelSize: CGFloat) async -> CGImage? {
    await MacMarkdownImageSupport.decodeCGImage(from: data, maxPixelSize: maxPixelSize)
  }

  static func suggestedFilename(
    for source: MacResponseImageCandidate.Source,
    fallbackIndex: Int,
    resolvedMimeType: String? = nil
  ) -> String {
    let fallbackExt = fileExtension(forMimeType: resolvedMimeType) ?? "jpg"
    switch source {
    case .url(let url):
      let name = sanitizeFilename(url.lastPathComponent)
      if !name.isEmpty, name.contains(".") { return name }
      return name.isEmpty ? "image-\(fallbackIndex).\(fallbackExt)" : "\(name).\(fallbackExt)"
    case .data(_, let fileExtension):
      let ext = sanitizeFilename(fileExtension.lowercased())
      return "image-\(fallbackIndex).\(ext.isEmpty ? fallbackExt : ext)"
    }
  }

  static func sanitizeFilename(_ name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
    let cleaned = name.components(separatedBy: allowed.inverted).joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(cleaned.prefix(80))
  }

  /// Sniffs the image encoding from payload bytes rather than trusting the URL
  /// path extension; Library viewers and model adapters both assume real bytes.
  static func mimeType(for data: Data, filename: String) -> String {
    if data.prefix(2) == Data([0xFF, 0xD8]) { return "image/jpeg" }
    if data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
      return "image/png"
    }
    if data.prefix(6) == Data("GIF89a".utf8) || data.prefix(6) == Data("GIF87a".utf8) {
      return "image/gif"
    }
    if data.count >= 12,
      data.prefix(4) == Data("RIFF".utf8),
      data.subdata(in: 8..<12) == Data("WEBP".utf8)
    {
      return "image/webp"
    }
    if let source = CGImageSourceCreateWithData(data as CFData, nil),
      let typeIdentifier = CGImageSourceGetType(source) as String?,
      let utType = UTType(typeIdentifier),
      utType.conforms(to: .image),
      let preferred = utType.preferredMIMEType
    {
      return preferred
    }
    let ext = (filename as NSString).pathExtension.lowercased()
    if !ext.isEmpty,
      let utType = UTType(filenameExtension: ext),
      utType.conforms(to: .image),
      let preferred = utType.preferredMIMEType
    {
      return preferred
    }
    return ext == "png" ? "image/png" : "image/jpeg"
  }

  private static func fileExtension(forMimeType mimeType: String?) -> String? {
    guard let mimeType else { return nil }
    switch mimeType.lowercased() {
    case "image/jpeg": return "jpg"
    case "image/png": return "png"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "image/heic": return "heic"
    case "image/tiff": return "tiff"
    default:
      return UTType(mimeType: mimeType)?.preferredFilenameExtension
    }
  }

  private static func hasValidDataURIHeader<S: StringProtocol>(_ value: S) -> Bool {
    guard value.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil,
      let semicolon = value.firstIndex(of: ";")
    else { return false }
    let payload = value[value.index(after: semicolon)...]
    guard payload.range(of: "base64,", options: [.anchored, .caseInsensitive]) != nil else {
      return false
    }
    let encoded = payload.dropFirst("base64,".count)
    return !encoded.isEmpty
  }

  private static func decodeDataURI(_ value: String) -> (data: Data, extension: String)? {
    guard value.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil else {
      return nil
    }
    guard let semicolon = value.firstIndex(of: ";") else { return nil }
    let mimeType = String(value[value.index(value.startIndex, offsetBy: 5)..<semicolon]).lowercased()
    let payload = value[value.index(after: semicolon)...]
    guard payload.range(of: "base64,", options: [.anchored, .caseInsensitive]) != nil else {
      return nil
    }
    let encoded = String(payload.dropFirst("base64,".count))
    guard !encoded.isEmpty, encoded.count <= (MacMarkdownImageSupport.maxByteCount * 4) / 3 + 4 else {
      return nil
    }
    guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
      !data.isEmpty,
      data.count <= MacMarkdownImageSupport.maxByteCount
    else { return nil }
    let subtype = mimeType.split(separator: "/").last.map(String.init) ?? "jpg"
    let fileExtension = subtype == "jpeg" ? "jpg" : subtype
    return (data, fileExtension)
  }
}
