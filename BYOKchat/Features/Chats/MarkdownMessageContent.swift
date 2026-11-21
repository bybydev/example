import AppFoundation
import BYOKchatProviderCore
import CryptoKit
import Foundation
import LaTeXSwiftUI
import MarkdownUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Immutable pre-parsed representation of a message's Markdown/code/math blocks.
/// MarkdownUI's `MarkdownContent` wraps immutable block nodes but predates
/// `Sendable`; instances are constructed once off the main actor and published
/// read-only.
nonisolated final class PreparedMarkdownMessage: @unchecked Sendable {
  struct Segment: @unchecked Sendable {
    let text: String
    let useLaTeX: Bool
    let markdownContent: MarkdownContent?
    let columnAlignments: [TextAlignment]
  }

  enum Block: @unchecked Sendable {
    case markdown([Segment])
    case code(language: String?, content: String, isClosed: Bool)
    case math(String)
  }

  let source: String
  let blocks: [Block]

  init(source: String) {
    self.source = source
    let parsedBlocks = AnswerContentParser.parseDetailed(source)
    self.blocks = parsedBlocks.map { parsed in
      switch parsed.block {
      case .markdown(let markdown):
        let segments = AnswerContentParser.splitMarkdownForInlineMath(markdown).map { segment in
          if segment.useLaTeX {
            return Segment(
              text: segment.text,
              useLaTeX: true,
              markdownContent: nil,
              columnAlignments: []
            )
          }
          return Segment(
            text: segment.text,
            useLaTeX: false,
            markdownContent: MarkdownContent(segment.text),
            columnAlignments: Self.tableColumnAlignments(in: segment.text) ?? []
          )
        }
        return .markdown(segments)
      case .code(let language, let content):
        return .code(language: language, content: content, isClosed: parsed.isClosed)
      case .math(let expression):
        return .math(expression)
      }
    }
  }

  /// Recovers GFM column alignments from a table's delimiter row
  /// (`| --- | :---: | ---: |`), mirroring the mapping TableView applies at the
  /// Grid level. MarkdownUI never exposes alignment to the theme closure, so
  /// with fixed-width cells — where the grid anchor has no slack to act on —
  /// it must be recovered from the source text here. Returns the first
  /// delimiter row outside code fences; tables after the first in the same
  /// markdown chunk share its alignments.
  static func tableColumnAlignments(in markdown: String) -> [TextAlignment]? {
    guard markdown.contains("|"), markdown.contains("-") else { return nil }
    var inFence = false
    for line in markdown.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        continue
      }
      guard !inFence, isTableDelimiterRow(trimmed) else { continue }

      let cells = trimmed
        .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        .components(separatedBy: "|")
      var alignments: [TextAlignment] = []
      for cell in cells {
        let c = cell.trimmingCharacters(in: .whitespaces)
        switch (c.hasPrefix(":"), c.hasSuffix(":")) {
        case (true, true): alignments.append(.center)
        case (false, true): alignments.append(.trailing)
        default: alignments.append(.leading)
        }
      }
      return alignments.isEmpty ? nil : alignments
    }
    return nil
  }

  private static func isTableDelimiterRow(_ line: String) -> Bool {
    guard line.contains("|"), line.contains("-") else { return false }
    let cells = line
      .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
      .components(separatedBy: "|")
    return !cells.isEmpty && cells.allSatisfy { cell in
      let c = cell.trimmingCharacters(in: .whitespaces)
      let body = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      return !body.isEmpty && body.allSatisfy { $0 == "-" }
        && c.contains("-")
    }
  }
}

/// Bounded thread-safe LRU cache for pre-parsed Markdown messages.
/// Parsing runs off the main actor (during conversation hydration or batch
/// expansion) so `MarkdownMessageContent.body` hits pre-built `MarkdownContent`
/// trees synchronously on frame 1.
nonisolated final class MarkdownParseCache: @unchecked Sendable {
  static let shared = MarkdownParseCache()

  private let lock = NSLock()
  private var values: [String: PreparedMarkdownMessage] = [:]
  private var order: [String] = []
  private var sourceBytes = 0
  private let limit: Int
  private let byteLimit: Int

  init(limit: Int = 128, byteLimit: Int = 8 * 1_024 * 1_024) {
    self.limit = max(limit, 1)
    self.byteLimit = max(byteLimit, 1)
  }

  func cached(for source: String) -> PreparedMarkdownMessage? {
    lock.lock()
    defer { lock.unlock() }
    guard let value = values[source] else { return nil }
    order.removeAll { $0 == source }
    order.append(source)
    return value
  }

  func prepare(for source: String) -> PreparedMarkdownMessage {
    if let existing = cached(for: source) {
      return existing
    }
    let prepared = PreparedMarkdownMessage(source: source)
    insert(prepared)
    return prepared
  }

  func prewarm(messages: [ChatMessage]) {
    for message in messages {
      if Task.isCancelled { return }
      guard !message.content.isEmpty, message.status != .streaming else { continue }
      _ = prepare(for: message.content)
    }
  }

  private func insert(_ value: PreparedMarkdownMessage) {
    let cost = value.source.utf8.count
    guard cost <= byteLimit else { return }
    lock.lock()
    defer { lock.unlock() }
    if values[value.source] == nil {
      sourceBytes += cost
    }
    values[value.source] = value
    order.removeAll { $0 == value.source }
    order.append(value.source)
    while order.count > limit || sourceBytes > byteLimit {
      let evicted = order.removeFirst()
      sourceBytes -= evicted.utf8.count
      values.removeValue(forKey: evicted)
    }
  }
}

struct MarkdownMessageContent: View {
  let text: String
  /// Stretch every block to the offered width. Off inside right-hugging user
  /// bubbles so the capsule shrinks to its content instead of filling the row.
  var fillsWidth = true
  var isStreaming = false

  @Environment(\.appFoundationTheme) private var theme
  @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = 17
  @State private var browserDestination: BrowserDestination?

  var body: some View {
    let prepared = isStreaming
      ? PreparedMarkdownMessage(source: text)
      : MarkdownParseCache.shared.prepare(for: text)

    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(prepared.blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    .environment(
      \.openURL,
      OpenURLAction { url in
        guard AnswerContentParser.isValidBrowsableURL(url) else {
          return .systemAction
        }
        browserDestination = BrowserDestination(url: url)
        return .handled
      }
    )
    .sheet(item: $browserDestination) { destination in
      InAppBrowserView(url: destination.url)
        .ignoresSafeArea()
    }
  }

  @ViewBuilder
  private func blockView(_ block: PreparedMarkdownMessage.Block) -> some View {
    switch block {
    case .markdown(let segments):
      if segments.count == 1, let only = segments.first {
        markdownSegmentView(only)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            markdownSegmentView(segment)
          }
        }
      }

    case .code(let language, let content, let isClosed):
      let blockComplete = isClosed || !isStreaming
      if AnswerContentParser.isMermaidLanguage(language) {
        MermaidAnswerView(source: content, isComplete: blockComplete)
      } else {
        HighlightedCodeBlock(language: language, content: content, isComplete: blockComplete)
      }

    case .math(let expression):
      MathAnswerView(expression: expression)
    }
  }

  @ViewBuilder
  private func markdownSegmentView(_ segment: PreparedMarkdownMessage.Segment) -> some View {
    if segment.useLaTeX {
      LaTeX(segment.text)
        .parsingMode(.onlyEquations)
        .blockMode(.blockViews)
        .processEscapes()
        .renderingStyle(.redactedOriginal)
        .renderingAnimation(.easeOut(duration: 0.18))
        .errorMode(.original)
        .imageRenderingMode(.template)
        .imageAccessibility(.sre)
        .font(.system(size: bodyFontSize))
        .foregroundStyle(theme.primaryForegroundColor)
        .textSelection(.enabled)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    } else {
      Markdown(segment.markdownContent ?? MarkdownContent(segment.text))
        .markdownImageProvider(MarkdownResponseImageProvider())
        .markdownTheme(
          chatTheme(columnAlignments: segment.columnAlignments)
        )
        .textSelection(.enabled)
        .tint(theme.accentColor)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    }
  }

  private func horizontalAlignment(_ alignment: TextAlignment) -> HorizontalAlignment {
    switch alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    @unknown default: .leading
    }
  }

  private func chatTheme(columnAlignments: [TextAlignment]) -> MarkdownUI.Theme {
    MarkdownUI.Theme.basic
      .text {
        ForegroundColor(theme.primaryForegroundColor)
        FontSize(bodyFontSize)
      }
      .code {
        FontFamilyVariant(.monospaced)
        FontSize(.em(0.87))
        ForegroundColor(theme.primaryForegroundColor)
        BackgroundColor(theme.elevatedSurfaceColor)
      }
      .strong {
        FontWeight(.semibold)
      }
      .link {
        ForegroundColor(theme.accentColor)
      }
      .heading1 { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .relativeLineSpacing(.em(0.08))
          .markdownMargin(top: .em(0.8), bottom: .em(0.42))
          .markdownTextStyle {
            FontWeight(.bold)
            FontSize(.em(1.48))
            ForegroundColor(theme.primaryForegroundColor)
          }
      }
      .heading2 { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .relativeLineSpacing(.em(0.08))
          .markdownMargin(top: .em(0.72), bottom: .em(0.38))
          .markdownTextStyle {
            FontWeight(.bold)
            FontSize(.em(1.28))
            ForegroundColor(theme.primaryForegroundColor)
          }
      }
      .heading3 { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .markdownMargin(top: .em(0.62), bottom: .em(0.3))
          .markdownTextStyle {
            FontWeight(.semibold)
            FontSize(.em(1.12))
            ForegroundColor(theme.primaryForegroundColor)
          }
      }
      .heading4 { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .markdownMargin(top: .em(0.52), bottom: .em(0.24))
          .markdownTextStyle {
            FontWeight(.semibold)
            FontSize(.em(1.02))
            ForegroundColor(theme.primaryForegroundColor)
          }
      }
      .heading5 { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .markdownMargin(top: .em(0.48), bottom: .em(0.2))
          .markdownTextStyle {
            FontWeight(.semibold)
            FontSize(.em(0.94))
            ForegroundColor(theme.secondaryForegroundColor)
          }
      }
      .heading6 { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .markdownMargin(top: .em(0.44), bottom: .em(0.18))
          .markdownTextStyle {
            FontWeight(.semibold)
            FontSize(.em(0.88))
            ForegroundColor(theme.accentColor)
          }
      }
      .paragraph { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .relativeLineSpacing(.em(0.22))
          .markdownMargin(top: .zero, bottom: .em(0.78))
      }
      .blockquote { configuration in
        HStack(spacing: 0) {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(theme.accentColor.opacity(0.68))
            .relativeFrame(width: .em(0.18))

          configuration.label
            .markdownTextStyle {
              ForegroundColor(theme.secondaryForegroundColor)
            }
            .relativePadding(.horizontal, length: .em(0.9))
            .relativePadding(.vertical, length: .em(0.62))
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
          theme.surfaceColor.opacity(0.72),
          in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .markdownMargin(top: .em(0.08), bottom: .em(0.82))
      }
      .listItem { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .relativeLineSpacing(.em(0.18))
          .markdownMargin(top: .em(0.16), bottom: .em(0.16))
      }
      .taskListMarker { configuration in
        Image(systemName: configuration.isCompleted ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(
            configuration.isCompleted ? theme.accentColor : theme.secondaryForegroundColor
          )
          .relativeFrame(minWidth: .em(1.45), alignment: .trailing)
      }
      .table { configuration in
        ScrollView(.horizontal) {
          // Do not force the Grid to its unconstrained intrinsic width. Let the bounded cells
          // below participate in layout so ordinary two-column tables can fit the chat viewport,
          // while genuinely wide tables still overflow into this horizontal scroller.
          configuration.label
            .markdownTableBorderStyle(.init(color: theme.borderColor))
            .markdownTableBackgroundStyle(
              .alternatingRows(theme.surfaceColor, theme.elevatedSurfaceColor)
            )
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .markdownMargin(top: .em(0.16), bottom: .em(0.9))
      }
      .tableCell { configuration in
        // Fixed cell width: the horizontal scroller above proposes nil width,
        // and under a nil proposal every flexible sizing (min/ideal/max frames,
        // or none at all) desynchronizes height measurement from the wrapped
        // render — rows collapse to one line or columns balloon. An exact
        // width makes every layout pass agree, so wrapped rows grow reliably.
        // Uniform widths leave the grid-level column anchor no slack, so the
        // delimiter-row alignment recovered by tableColumnAlignments is applied
        // here instead. Tune cellWidth if tables feel cramped or airy.
        let alignment = configuration.column < columnAlignments.count
          ? columnAlignments[configuration.column] : .leading

        configuration.label
          .markdownTextStyle {
            FontSize(.em(0.88))
            if configuration.row == 0 {
              FontWeight(.semibold)
              ForegroundColor(theme.primaryForegroundColor)
            } else {
              ForegroundColor(theme.secondaryForegroundColor)
            }
            BackgroundColor(nil)
          }
          .multilineTextAlignment(alignment)
          .frame(width: 140, alignment: Alignment(horizontal: horizontalAlignment(alignment), vertical: .top))
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
      }
      .thematicBreak {
        HStack(spacing: 8) {
          Rectangle().fill(theme.borderColor)
          Circle().fill(theme.accentColor.opacity(0.72)).frame(width: 4, height: 4)
          Rectangle().fill(theme.borderColor)
        }
        .frame(height: 1)
        .markdownMargin(top: .em(1.1), bottom: .em(1.1))
      }
  }
}

nonisolated enum MarkdownImageSupport {
  static let maxByteCount = 20 * 1_024 * 1_024

  private struct RawByteCache: @unchecked Sendable {
    let storage: NSCache<NSString, NSData> = {
      let cache = NSCache<NSString, NSData>()
      cache.countLimit = 48
      cache.totalCostLimit = 24 * 1_024 * 1_024
      return cache
    }()
  }

  private static let rawByteCache = RawByteCache()

  static func isSupportedURL(_ url: URL) -> Bool {
    if AnswerContentParser.isValidBrowsableURL(url) { return true }
    return url.absoluteString.lowercased().hasPrefix("data:image/")
  }

  static func cacheKey(for url: URL) -> String {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
      .prefix(16)
      .map { String(format: "%02x", $0) }
      .joined()
    return "mdimg::\(digest)"
  }

  static func cachedRawBytes(for key: String) -> Data? {
    rawByteCache.storage.object(forKey: key as NSString) as Data?
  }

  static func dataURIMetadata(for url: URL) -> (filename: String, mimeType: String)? {
    let raw = url.absoluteString
    guard raw.lowercased().hasPrefix("data:image/"),
      let semicolon = raw.firstIndex(of: ";")
    else { return nil }
    let mimeType = String(raw[raw.index(raw.startIndex, offsetBy: 5)..<semicolon]).lowercased()
    let subtype = mimeType.split(separator: "/").last.map(String.init) ?? "png"
    let fileExtension = subtype == "jpeg" ? "jpg" : subtype
    return ("image.\(fileExtension)", mimeType)
  }

  static func decodeDataURI(_ url: URL) -> (data: Data, filename: String, mimeType: String)? {
    let raw = url.absoluteString
    guard let meta = dataURIMetadata(for: url),
      let semicolon = raw.firstIndex(of: ";")
    else { return nil }
    let payload = raw[raw.index(after: semicolon)...]
    guard payload.lowercased().hasPrefix("base64,") else { return nil }
    let encoded = String(payload.dropFirst("base64,".count))
    guard !encoded.isEmpty, encoded.count <= (maxByteCount * 4) / 3 + 4 else { return nil }
    guard let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= maxByteCount else {
      return nil
    }
    return (data, meta.filename, meta.mimeType)
  }

  static func metadata(for url: URL) -> (filename: String, mimeType: String) {
    if let dataMeta = dataURIMetadata(for: url) {
      return dataMeta
    }
    let filename = ResponseImageScanner.suggestedFilename(for: .url(url), fallbackIndex: 1)
    let ext = (filename as NSString).pathExtension
    let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/jpeg"
    return (filename, mimeType)
  }

  static func loadBytes(for url: URL) async -> (data: Data, filename: String, mimeType: String)? {
    guard isSupportedURL(url) else { return nil }
    let key = cacheKey(for: url)
    if let cached = cachedRawBytes(for: key) {
      let meta = metadata(for: url)
      return (cached, meta.filename, meta.mimeType)
    }

    if url.absoluteString.lowercased().hasPrefix("data:image/") {
      let decoded = await Task.detached(priority: .utility) {
        decodeDataURI(url)
      }.value
      guard let decoded else { return nil }
      rawByteCache.storage.setObject(
        decoded.data as NSData,
        forKey: key as NSString,
        cost: decoded.data.count
      )
      return decoded
    }

    guard AnswerContentParser.isValidBrowsableURL(url) else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode),
      !data.isEmpty,
      data.count <= maxByteCount
    else { return nil }

    rawByteCache.storage.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    let meta = metadata(for: url)
    return (data, meta.filename, meta.mimeType)
  }
}

private nonisolated struct MarkdownResponseImageProvider: ImageProvider {
  func makeImage(url: URL?) -> some View {
    MarkdownResponseImageView(url: url)
  }
}

private struct MarkdownResponseImageView: View {
  let url: URL?

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @State private var image: UIImage?
  @State private var isFailed = false
  @State private var isOpeningPreview = false
  @State private var preview: ChatAttachmentImagePreview?
  @State private var previewTempDirectory: URL?

  nonisolated init(url: URL?) {
    self.url = url
  }

  private var displayPixelSize: CGFloat {
    min(1_200, max(360, 360 * displayScale))
  }

  var body: some View {
    let cacheKey = url.map(MarkdownImageSupport.cacheKey(for:))
    let resolvedImage = image ?? cacheKey.flatMap {
      AttachmentThumbnailLoader.cachedImage(cacheKey: $0, maxPixelSize: displayPixelSize)
    }

    Group {
      if let resolvedImage {
        Button {
          openFullScreen(fallbackImage: resolvedImage)
        } label: {
          Image(uiImage: resolvedImage)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.borderColor.opacity(0.8), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Image")
        .accessibilityHint("Double tap to view full screen")
      } else if isFailed || url == nil {
        HStack(spacing: 8) {
          Image(systemName: "photo.badge.exclamationmark")
          Text("Image unavailable")
            .font(.caption.weight(.medium))
        }
        .foregroundStyle(theme.secondaryForegroundColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
          theme.surfaceColor,
          in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(theme.borderColor.opacity(0.8), lineWidth: 0.75)
        )
      } else {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(theme.surfaceColor)
          .frame(maxWidth: .infinity)
          .frame(height: 180)
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(theme.borderColor.opacity(0.8), lineWidth: 0.75)
          )
          .overlay {
            Image(systemName: "photo")
              .font(.system(size: 24, weight: .medium))
              .foregroundStyle(theme.secondaryForegroundColor.opacity(0.32))
          }
      }
    }
    .task(id: url) {
      await loadImage()
    }
    .sheet(item: $preview, onDismiss: {
      cleanupTempDirectory()
    }) { item in
      LibraryImageViewerView(
        entry: item.entry,
        image: item.image,
        shareFileURL: item.shareFileURL,
        onSaveToPhotos: {
          try await LibraryPhotoWriter.save(item.image)
        }
      )
    }
  }

  private func loadImage() async {
    guard let url, MarkdownImageSupport.isSupportedURL(url) else {
      isFailed = true
      return
    }
    let key = MarkdownImageSupport.cacheKey(for: url)
    let pixelSize = displayPixelSize
    if AttachmentThumbnailLoader.cachedImage(cacheKey: key, maxPixelSize: pixelSize) != nil {
      if isFailed { isFailed = false }
      return
    }
    image = nil
    isFailed = false
    guard let loaded = await MarkdownImageSupport.loadBytes(for: url) else {
      if !Task.isCancelled { isFailed = true }
      return
    }
    guard !Task.isCancelled else { return }
    let decoded = await AttachmentThumbnailLoader.decodeImage(
      from: loaded.data,
      cacheKey: key,
      maxPixelSize: pixelSize,
      alreadyDownsampled: false
    )
    guard !Task.isCancelled else { return }
    if let decoded {
      image = decoded
    } else {
      isFailed = true
    }
  }

  private func openFullScreen(fallbackImage: UIImage) {
    guard !isOpeningPreview, let url else { return }
    isOpeningPreview = true
    let key = MarkdownImageSupport.cacheKey(for: url)
    Task { @MainActor in
      defer { isOpeningPreview = false }
      let loaded = await MarkdownImageSupport.loadBytes(for: url)
      let fallbackMeta = MarkdownImageSupport.metadata(for: url)
      let filename = loaded?.filename ?? fallbackMeta.filename
      let mimeType = loaded?.mimeType ?? fallbackMeta.mimeType
      let rawData = loaded?.data
      let prepared = await Task.detached(priority: .userInitiated) {
        () -> (image: UIImage, shareData: Data?, materialized: LibraryTempFileSupport.MaterializedFile?) in
        let fullImage = rawData.flatMap(UIImage.init(data:)) ?? fallbackImage
        let shareData = rawData ?? fullImage.pngData()
        let materialized = shareData.flatMap { data in
          try? LibraryTempFileSupport.materializeTempFile(
            directoryPrefix: "byok-md-preview",
            filename: filename,
            data: data
          )
        }
        return (fullImage, shareData, materialized)
      }.value

      cleanupTempDirectory()
      previewTempDirectory = prepared.materialized?.directory
      let entry = LibraryEntry(
        id: LibraryEntryID(rawValue: key),
        filename: filename,
        kind: .image,
        mimeType: mimeType,
        byteCount: prepared.shareData?.count ?? 0,
        source: .manual
      )
      preview = ChatAttachmentImagePreview(
        entry: entry,
        image: prepared.image,
        shareFileURL: prepared.materialized?.fileURL,
        tempDirectory: prepared.materialized?.directory
      )
    }
  }

  private func cleanupTempDirectory() {
    if let directory = previewTempDirectory {
      previewTempDirectory = nil
      LibraryTempFileSupport.cleanupDirectory(directory)
    }
  }
}
