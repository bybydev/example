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
    case table(ParsedMarkdownTable, isClosed: Bool)
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
      case .table(let table):
        return .table(table, isClosed: parsed.isClosed)
      }
    }
  }

  /// Recovers GFM column alignments for rare nested tables that stay inside
  /// `.markdown` segments (for example inside blockquotes or list items).
  static func tableColumnAlignments(in markdown: String) -> [TextAlignment]? {
    guard markdown.contains("|"), markdown.contains("-") else { return nil }
    var inFence = false
    for line in markdown.components(separatedBy: .newlines) {
      var trimmed = line.trimmingCharacters(in: .whitespaces)
      while trimmed.hasPrefix(">") {
        trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        continue
      }
      guard !inFence, let alignments = AnswerContentParser.parseTableDelimiterRow(trimmed) else {
        continue
      }
      return alignments.map { alignment in
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
      }
    }
    return nil
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
  @Environment(\.colorScheme) private var colorScheme
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

    case .table(let table, let isClosed):
      let blockComplete = isClosed || !isStreaming
      MarkdownTableView(
        table: table,
        fillsWidth: fillsWidth,
        isComplete: blockComplete
      )
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
        let isDark = colorScheme == .dark
        let fallbackCellWidth = max(120, ceil(bodyFontSize * 8.2))
        ScrollView(.horizontal) {
          configuration.label
            .markdownTableBorderStyle(.init(color: theme.borderColor.opacity(0.85)))
            .markdownTableBackgroundStyle(
              .alternatingRows(
                isDark ? theme.surfaceColor : theme.elevatedSurfaceColor,
                isDark ? theme.elevatedSurfaceColor.opacity(0.45) : theme.backgroundColor.opacity(0.42)
              )
            )
            .frame(minWidth: fallbackCellWidth, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.borderColor, lineWidth: 0.75)
            )
            .padding(.bottom, 4)
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .markdownMargin(top: .em(0.16), bottom: .em(0.9))
      }
      .tableCell { configuration in
        let alignment = configuration.column < columnAlignments.count
          ? columnAlignments[configuration.column] : .leading
        let scaledWidth = max(120, ceil(bodyFontSize * 8.2))

        configuration.label
          .markdownTextStyle {
            FontSize(.em(0.88))
            if configuration.row == 0 {
              FontWeight(.semibold)
            }
            ForegroundColor(theme.primaryForegroundColor)
            BackgroundColor(nil)
          }
          .multilineTextAlignment(alignment)
          .frame(
            width: scaledWidth,
            alignment: Alignment(horizontal: horizontalAlignment(alignment), vertical: .top)
          )
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
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

// MARK: - Markdown Tables

private struct MarkdownTablePalette {
  let cardBackground: Color
  let utilityBarBackground: Color
  let headerRowBackground: Color
  let evenRowBackground: Color
  let oddRowBackground: Color
  let codeChipBackground: Color
  let headerDivider: Color
  let rowDivider: Color
  let columnDivider: Color
  let edgeFadeColor: Color

  init(theme: AppTheme, colorScheme: ColorScheme) {
    if colorScheme == .dark {
      cardBackground = theme.surfaceColor
      utilityBarBackground = theme.elevatedSurfaceColor.opacity(0.68)
      headerRowBackground = theme.elevatedSurfaceColor
      evenRowBackground = theme.surfaceColor
      oddRowBackground = theme.elevatedSurfaceColor.opacity(0.38)
      codeChipBackground = theme.backgroundColor.opacity(0.75)
      headerDivider = theme.borderColor
      rowDivider = theme.borderColor.opacity(0.62)
      columnDivider = theme.borderColor.opacity(0.36)
      edgeFadeColor = theme.surfaceColor
    } else {
      cardBackground = theme.elevatedSurfaceColor
      utilityBarBackground = theme.backgroundColor.opacity(0.62)
      headerRowBackground = theme.backgroundColor.opacity(0.9)
      evenRowBackground = theme.elevatedSurfaceColor
      oddRowBackground = theme.backgroundColor.opacity(0.38)
      codeChipBackground = theme.backgroundColor
      headerDivider = theme.borderColor
      rowDivider = theme.borderColor.opacity(0.65)
      columnDivider = theme.borderColor.opacity(0.42)
      edgeFadeColor = theme.elevatedSurfaceColor
    }
  }
}

private struct HorizontalScrollEdges: Equatable {
  var canScrollLeading = false
  var canScrollTrailing = false
}

struct MarkdownTableView: View {
  let table: ParsedMarkdownTable
  var fillsWidth = true
  var isComplete = true

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = 17
  @State private var measuredWidth: CGFloat = 0
  @State private var scrollEdges = HorizontalScrollEdges()
  @State private var showFullScreen = false
  @State private var isCopied = false
  @State private var copyFeedbackRevision = 0

  private var cellFontSize: CGFloat {
    max(12, bodyFontSize * 0.88)
  }

  private var effectiveAvailableWidth: CGFloat {
    if measuredWidth > 1 {
      return measuredWidth
    }
    return fillsWidth ? 344 : 264
  }

  private var dimensionsLabel: String {
    let cols = table.columnCount
    let rows = table.rows.count
    if rows == 0 {
      return cols == 1 ? "TABLE · 1 COL" : "TABLE · \(cols) COLS"
    }
    return "\(cols) × \(rows)"
  }

  var body: some View {
    let palette = MarkdownTablePalette(theme: theme, colorScheme: colorScheme)
    let metrics = MarkdownTableLayout.compute(
      for: table,
      availableWidth: effectiveAvailableWidth,
      fontSize: cellFontSize,
      fillsWidth: fillsWidth
    )

    VStack(spacing: 0) {
      if fillsWidth {
        utilityBar(palette: palette)

        Rectangle()
          .fill(palette.rowDivider)
          .frame(height: 0.5)
      }

      ScrollView(.horizontal) {
        MarkdownTableGrid(
          table: table,
          columnWidths: metrics.columnWidths,
          totalWidth: metrics.totalWidth,
          fontSize: cellFontSize,
          palette: palette
        )
        .padding(.bottom, metrics.overflowsViewport ? 6 : 0)
      }
      .scrollIndicators(metrics.overflowsViewport ? .visible : .hidden)
      .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
      .onScrollGeometryChange(for: HorizontalScrollEdges.self) { geometry in
        let maxOffset = max(0, geometry.contentSize.width - geometry.containerSize.width)
        return HorizontalScrollEdges(
          canScrollLeading: geometry.contentOffset.x > 4,
          canScrollTrailing: maxOffset > 4 && geometry.contentOffset.x < maxOffset - 4
        )
      } action: { _, newValue in
        if scrollEdges != newValue {
          scrollEdges = newValue
        }
      }
      .overlay(alignment: .leading) {
        if metrics.overflowsViewport, scrollEdges.canScrollLeading {
          LinearGradient(
            colors: [palette.edgeFadeColor.opacity(0.92), palette.edgeFadeColor.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: 18)
          .allowsHitTesting(false)
        }
      }
      .overlay(alignment: .trailing) {
        if metrics.overflowsViewport, scrollEdges.canScrollTrailing {
          LinearGradient(
            colors: [palette.edgeFadeColor.opacity(0), palette.edgeFadeColor.opacity(0.92)],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: 22)
          .allowsHitTesting(false)
        }
      }
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    .background(palette.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 0.75)
    )
    .shadow(color: theme.appearance.shadow.color.opacity(0.22), radius: 6, y: 2)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { newWidth in
      if newWidth > 1, abs(newWidth - measuredWidth) > 1 {
        measuredWidth = newWidth
      }
    }
    .task(id: copyFeedbackRevision) {
      guard copyFeedbackRevision > 0 else { return }
      try? await Task.sleep(for: .seconds(1.4))
      guard !Task.isCancelled else { return }
      withAnimation(.snappy(duration: 0.2)) {
        isCopied = false
      }
    }
    .sheet(isPresented: $showFullScreen) {
      FullScreenTableView(table: table)
    }
  }

  private func utilityBar(palette: MarkdownTablePalette) -> some View {
    HStack(spacing: 6) {
      Label(dimensionsLabel, systemImage: "tablecells")
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(theme.secondaryForegroundColor)
        .lineLimit(1)

      Spacer(minLength: 8)

      Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
        showFullScreen = true
      }
      .labelStyle(.iconOnly)
      .frame(width: 36, height: 34)
      .contentShape(Rectangle())
      .disabled(!isComplete)
      .opacity(isComplete ? 1 : 0.35)

      Menu {
        Button("Copy as Markdown", systemImage: "doc.plaintext") {
          copyTable(table.markdownText)
        }
        Button("Copy for Spreadsheets", systemImage: "tablecells") {
          copyTable(table.tsvText)
        }
      } label: {
        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(isCopied ? theme.accentColor : theme.secondaryForegroundColor)
          .frame(width: 36, height: 34)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Copy Table")
    }
    .font(.system(size: 12.5, weight: .semibold))
    .foregroundStyle(theme.secondaryForegroundColor)
    .buttonStyle(.plain)
    .padding(.leading, 12)
    .padding(.trailing, 4)
    .frame(minHeight: 36)
    .background(palette.utilityBarBackground)
  }

  private func copyTable(_ payload: String) {
    UIPasteboard.general.string = payload
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    withAnimation(.snappy(duration: 0.2)) {
      isCopied = true
    }
    copyFeedbackRevision += 1
  }
}

private struct MarkdownTableGrid: View {
  let table: ParsedMarkdownTable
  let columnWidths: [CGFloat]
  let totalWidth: CGFloat
  let fontSize: CGFloat
  let palette: MarkdownTablePalette

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      rowView(
        cells: table.headers,
        isHeader: true,
        background: palette.headerRowBackground
      )

      if !table.rows.isEmpty {
        Rectangle()
          .fill(palette.headerDivider)
          .frame(height: 1)

        ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
          rowView(
            cells: row,
            isHeader: false,
            background: rowIndex.isMultiple(of: 2)
              ? palette.evenRowBackground
              : palette.oddRowBackground
          )

          if rowIndex < table.rows.count - 1 {
            Rectangle()
              .fill(palette.rowDivider)
              .frame(height: 0.5)
          }
        }
      }
    }
    .frame(width: totalWidth, alignment: .leading)
    .overlay {
      if columnWidths.count > 1 {
        HStack(spacing: 0) {
          ForEach(Array(columnWidths.dropLast().enumerated()), id: \.offset) { _, width in
            Color.clear.frame(width: max(0, width - 0.5))
            Rectangle()
              .fill(palette.columnDivider)
              .frame(width: 0.5)
          }
          Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
      }
    }
  }

  private func rowView(
    cells: [String],
    isHeader: Bool,
    background: Color
  ) -> some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(Array(columnWidths.enumerated()), id: \.offset) { colIndex, columnWidth in
        let cellText = colIndex < cells.count ? cells[colIndex] : ""
        let alignment = colIndex < table.alignments.count ? table.alignments[colIndex] : .leading

        MarkdownTableCellView(
          text: cellText,
          alignment: alignment,
          isHeader: isHeader,
          fontSize: isHeader ? max(11.5, fontSize * 0.96) : fontSize,
          columnWidth: columnWidth,
          codeChipBackground: palette.codeChipBackground
        )
      }
    }
    .background(background)
  }
}

private struct MarkdownTableCellView: View {
  let text: String
  let alignment: MarkdownTableAlignment
  let isHeader: Bool
  let fontSize: CGFloat
  let columnWidth: CGFloat
  let codeChipBackground: Color

  @Environment(\.appFoundationTheme) private var theme

  private var textAlignment: TextAlignment {
    switch alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  private var frameAlignment: Alignment {
    switch alignment {
    case .leading: .topLeading
    case .center: .top
    case .trailing: .topTrailing
    }
  }

  var body: some View {
    cellContent
      .multilineTextAlignment(textAlignment)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: frameAlignment)
      .padding(.horizontal, MarkdownTableLayout.cellHorizontalPadding)
      .padding(.vertical, MarkdownTableLayout.cellVerticalPadding)
      .frame(width: columnWidth, alignment: frameAlignment)
  }

  @ViewBuilder
  private var cellContent: some View {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Text(" ")
        .font(.system(size: fontSize, weight: isHeader ? .semibold : .regular))
        .accessibilityHidden(true)
    } else if text.contains("![") {
      Markdown(text)
        .markdownImageProvider(MarkdownResponseImageProvider())
        .markdownTheme(
          MarkdownUI.Theme.basic
            .text {
              ForegroundColor(theme.primaryForegroundColor)
              FontSize(fontSize)
              if isHeader {
                FontWeight(.semibold)
              }
            }
            .link {
              ForegroundColor(theme.accentColor)
            }
        )
        .textSelection(.enabled)
        .tint(theme.accentColor)
    } else if AnswerContentParser.shouldRenderCellAsInlineMath(text) {
      LaTeX(text)
        .parsingMode(.onlyEquations)
        .blockMode(.blockViews)
        .processEscapes()
        .renderingStyle(.redactedOriginal)
        .renderingAnimation(.easeOut(duration: 0.18))
        .errorMode(.original)
        .imageRenderingMode(.template)
        .imageAccessibility(.sre)
        .font(.system(size: fontSize, weight: isHeader ? .semibold : .regular))
        .foregroundStyle(theme.primaryForegroundColor)
        .textSelection(.enabled)
    } else if let attributed = MarkdownTableCellFormatter.attributedString(
      for: text,
      fontSize: fontSize,
      isHeader: isHeader,
      accentColor: theme.accentColor,
      codeChipBackground: codeChipBackground
    ) {
      Text(attributed)
        .font(.system(size: fontSize, weight: isHeader ? .semibold : .regular))
        .monospacedDigit()
        .foregroundStyle(theme.primaryForegroundColor)
        .lineSpacing(2)
        .textSelection(.enabled)
        .tint(theme.accentColor)
    } else {
      Text(text)
        .font(.system(size: fontSize, weight: isHeader ? .semibold : .regular))
        .monospacedDigit()
        .foregroundStyle(theme.primaryForegroundColor)
        .lineSpacing(2)
        .textSelection(.enabled)
    }
  }
}

private enum MarkdownTableCellFormatter {
  private static func needsRichFormatting(_ text: String) -> Bool {
    text.contains("*")
      || text.contains("_")
      || text.contains("`")
      || text.contains("~")
      || text.contains("[")
      || text.contains("<")
      || text.contains("\\")
      || text.contains("http://")
      || text.contains("https://")
  }

  static func attributedString(
    for text: String,
    fontSize: CGFloat,
    isHeader: Bool,
    accentColor: Color,
    codeChipBackground: Color
  ) -> AttributedString? {
    guard needsRichFormatting(text) else { return nil }

    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .inlineOnlyPreservingWhitespace
    var attributed = (try? AttributedString(markdown: text, options: options))
      ?? AttributedString(text)

    let runs = Array(attributed.runs)
    for run in runs {
      let range = run.range
      if let intent = run.inlinePresentationIntent, intent.contains(.code) {
        let isBold = isHeader || intent.contains(.stronglyEmphasized)
        attributed[range].swiftUI.font = .system(
          size: max(11, fontSize * 0.88),
          weight: isBold ? .semibold : .regular,
          design: .monospaced
        )
        attributed[range].swiftUI.backgroundColor = codeChipBackground
      }
      if run.link != nil {
        attributed[range].swiftUI.foregroundColor = accentColor
      }
    }

    if text.contains("http://") || text.contains("https://"),
      let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    {
      let plain = String(attributed.characters)
      let fullRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
      for match in detector.matches(in: plain, range: fullRange) {
        guard let url = match.url,
          AnswerContentParser.isValidBrowsableURL(url),
          let stringRange = Range(match.range, in: plain)
        else { continue }

        let startOffset = plain.distance(from: plain.startIndex, to: stringRange.lowerBound)
        let endOffset = plain.distance(from: plain.startIndex, to: stringRange.upperBound)
        guard endOffset > startOffset else { continue }
        let lower = attributed.characters.index(attributed.startIndex, offsetBy: startOffset)
        let upper = attributed.characters.index(attributed.startIndex, offsetBy: endOffset)

        let targetRange = lower..<upper
        let hasLinkOrCode = attributed[targetRange].runs.contains { run in
          run.link != nil || (run.inlinePresentationIntent?.contains(.code) ?? false)
        }
        guard !hasLinkOrCode else { continue }
        attributed[targetRange].link = url
        attributed[targetRange].swiftUI.foregroundColor = accentColor
      }
    }

    return attributed
  }
}

private struct FullScreenTableView: View {
  let table: ParsedMarkdownTable

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = 17
  @State private var sheetWidth: CGFloat = 390
  @State private var isCopied = false
  @State private var copyFeedbackRevision = 0
  @State private var browserDestination: BrowserDestination?

  private var cellFontSize: CGFloat {
    max(12, bodyFontSize * 0.9)
  }

  var body: some View {
    let palette = MarkdownTablePalette(theme: theme, colorScheme: colorScheme)
    let metrics = MarkdownTableLayout.compute(
      for: table,
      availableWidth: max(320, sheetWidth - 32),
      fontSize: cellFontSize,
      fillsWidth: true,
      maxColumnWidthOverride: 320
    )

    NavigationStack {
      ScrollView([.horizontal, .vertical]) {
        MarkdownTableGrid(
          table: table,
          columnWidths: metrics.columnWidths,
          totalWidth: metrics.totalWidth,
          fontSize: cellFontSize,
          palette: palette
        )
        .background(palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(theme.borderColor, lineWidth: 0.75)
        )
        .padding(16)
      }
      .background(theme.backgroundColor.ignoresSafeArea())
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.width
      } action: { newWidth in
        if newWidth > 1, abs(newWidth - sheetWidth) > 1 {
          sheetWidth = newWidth
        }
      }
      .navigationTitle(
        table.rows.isEmpty ? "Table" : "Table (\(table.columnCount) × \(table.rows.count))"
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          ShareLink(item: table.markdownText) {
            Image(systemName: "square.and.arrow.up")
          }
          Menu {
            Button("Copy as Markdown", systemImage: "doc.plaintext") {
              copyTable(table.markdownText)
            }
            Button("Copy for Spreadsheets", systemImage: "tablecells") {
              copyTable(table.tsvText)
            }
          } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
          }
          .accessibilityLabel("Copy Table")

          Button("Done") { dismiss() }
        }
      }
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
      .task(id: copyFeedbackRevision) {
        guard copyFeedbackRevision > 0 else { return }
        try? await Task.sleep(for: .seconds(1.4))
        guard !Task.isCancelled else { return }
        withAnimation(.snappy(duration: 0.2)) {
          isCopied = false
        }
      }
    }
  }

  private func copyTable(_ payload: String) {
    UIPasteboard.general.string = payload
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    withAnimation(.snappy(duration: 0.2)) {
      isCopied = true
    }
    copyFeedbackRevision += 1
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
