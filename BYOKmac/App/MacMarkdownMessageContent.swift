import AppKit
import BeautifulMermaid
import CryptoKit
import Foundation
import Highlighter
import ImageIO
import LaTeXSwiftUI
import MacAppFoundation
import MarkdownUI
import os
import SwiftUI
import UniformTypeIdentifiers

struct MacMarkdownMessageContent: View {
  let text: String
  var isStreaming = false
  /// Base body font size. Code/theme styles derive from it; defaults to the
  /// standard answer size.
  var textSize: CGFloat = 15

  @State private var completedAnswer: MacPreparedAnswer?
  @Environment(\.macPreparedAnswers) private var preparedAnswers
  @Environment(\.macTranscriptIsActive) private var isTranscriptActive

  private var preparedAnswer: MacPreparedAnswer? {
    if let completedAnswer, completedAnswer.source == text { return completedAnswer }
    return preparedAnswers[text] ?? MacAnswerContentParseCache.shared.cachedAnswer(for: text)
  }

  private struct RenderRequest: Equatable {
    let text: String
    let isStreaming: Bool
    let isActive: Bool
  }

  private static let renderSignpostLog = OSLog(
    subsystem: "pro.byok.BYOKchat",
    category: "MacStreamingRenderer"
  )

  var body: some View {
    Group {
      if isStreaming {
        renderedBlocks(parsedStreamingBlocks())
      } else if let preparedAnswer {
        renderedBlocks(preparedAnswer.blocks)
      } else {
        // Keep initial row materialization cheap. Completed structural parsing
        // happens asynchronously on MacAnswerContentParseCache, never here.
        Text(text)
          .font(.system(size: textSize))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .environment(
      \.openURL,
      OpenURLAction { url in
        guard MacAnswerContentParser.isValidBrowsableURL(url) else {
          return .systemAction
        }
        NSWorkspace.shared.open(url)
        return .handled
      }
    )
    .task(id: RenderRequest(text: text, isStreaming: isStreaming, isActive: isTranscriptActive)) {
      guard !isStreaming, isTranscriptActive else { return }
      if let preparedAnswer {
        completedAnswer = preparedAnswer
        return
      }
      let source = text
      do {
        let prepared = try await MacAnswerContentParseCache.shared.answer(for: source)
        guard !Task.isCancelled, source == text else { return }
        completedAnswer = prepared
      } catch {
        // A recycled or inactive row no longer needs this preparation.
      }
    }
  }

  @ViewBuilder
  private func renderedBlocks(_ blocks: [MacAnswerContentBlock]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
        blockView(block, isTrailingBlock: offset == blocks.count - 1)
      }
    }
  }

  private func parsedStreamingBlocks() -> [MacAnswerContentBlock] {
    os_signpost(.event, log: Self.renderSignpostLog, name: "Stream Presentation")
    os_signpost(.begin, log: Self.renderSignpostLog, name: "Stream Parse")
    defer {
      os_signpost(.end, log: Self.renderSignpostLog, name: "Stream Parse")
    }
    return MacAnswerContentParser.parse(text)
  }

  @ViewBuilder
  private func blockView(_ block: MacAnswerContentBlock, isTrailingBlock: Bool) -> some View {
    switch block {
    case .markdown(let source):
      let markdown = isStreaming ? stabilizedStreamingMarkdown(source) : source
      let segments = resolvedSegments(for: markdown)
      if segments.count == 1, let only = segments.first {
        markdownSegmentView(only)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            markdownSegmentView(segment)
          }
        }
      }

    case .code(let language, let content, let isComplete):
      let blockComplete = isComplete || !isStreaming
      if MacAnswerContentParser.isMermaidLanguage(language) {
        MacMermaidAnswerView(source: content, isComplete: blockComplete)
      } else {
        MacHighlightedCodeBlock(
          language: language,
          content: content,
          isStreaming: isStreaming && !isComplete
        )
      }

    case .math(let expression, let isComplete):
      if isComplete {
        MacMathAnswerView(expression: expression)
      } else {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.mini)
          Text("Rendering equation…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
      }

    case .table(let table):
      MacMarkdownTableView(
        table: table,
        textSize: textSize,
        isComplete: !(isStreaming && isTrailingBlock)
      )
    }
  }

  private func resolvedSegments(for markdown: String) -> [MacPreparedAnswer.MarkdownSegment] {
    if !isStreaming, let cached = preparedAnswer?.markdownSegments[markdown] {
      return cached
    }
    return MacAnswerContentParser.splitMarkdownForInlineMath(markdown).map { segment in
      if segment.useLaTeX {
        return MacPreparedAnswer.MarkdownSegment(
          text: segment.text,
          useLaTeX: true,
          markdownContent: nil,
          columnAlignments: []
        )
      }
      return MacPreparedAnswer.MarkdownSegment(
        text: segment.text,
        useLaTeX: false,
        markdownContent: preparedAnswer?.markdown[segment.text],
        columnAlignments: MacMarkdownTableAlignment.columnAlignments(in: segment.text) ?? []
      )
    }
  }

  @ViewBuilder
  private func markdownSegmentView(_ segment: MacPreparedAnswer.MarkdownSegment) -> some View {
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
        .font(.system(size: textSize))
        .foregroundStyle(.primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Markdown(segment.markdownContent ?? MarkdownContent(segment.text))
        .markdownImageProvider(MacMarkdownResponseImageProvider())
        .markdownTheme(Self.chatTheme(textSize: textSize, columnAlignments: segment.columnAlignments))
        .textSelection(.enabled)
        .tint(.accentColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Keep an unfinished inline math tail from appearing as raw `$...` or
  /// `\(...` while a response is still streaming. The preceding Markdown is
  /// still rendered normally and the hidden tail is replaced by one ellipsis.
  private func stabilizedStreamingMarkdown(_ source: String) -> String {
    guard !MacAnswerContentParser.isLikelyBalancedInlineMath(source) else { return source }

    var lastUnescapedDollar: String.Index?
    var escaped = false
    for index in source.indices {
      let character = source[index]
      if escaped {
        escaped = false
        continue
      }
      if character == "\\" {
        escaped = true
      } else if character == "$" {
        lastUnescapedDollar = index
      }
    }

    if let start = lastUnescapedDollar {
      return String(source[..<start]) + "…"
    }

    if let range = source.range(of: "\\(", options: .backwards),
      source.range(of: "\\)", range: range.upperBound..<source.endIndex) == nil
    {
      return String(source[..<range.lowerBound]) + "…"
    }

    return source
  }

  private static func textAlignment(for alignment: MacTableColumnAlignment) -> TextAlignment {
    switch alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  private static func horizontalAlignment(for alignment: MacTableColumnAlignment) -> HorizontalAlignment {
    switch alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  private struct ChatThemeKey: Hashable {
    let textSize: CGFloat
    let columnAlignments: [MacTableColumnAlignment]
  }

  @MainActor
  private static var cachedThemes: [ChatThemeKey: MarkdownUI.Theme] = [:]

  @MainActor
  private static func chatTheme(
    textSize: CGFloat,
    columnAlignments: [MacTableColumnAlignment] = []
  ) -> MarkdownUI.Theme {
    let key = ChatThemeKey(textSize: textSize, columnAlignments: columnAlignments)
    if let existing = cachedThemes[key] {
      return existing
    }
    let theme = buildChatTheme(textSize: textSize, columnAlignments: columnAlignments)
    if cachedThemes.count >= 16 {
      cachedThemes.removeAll(keepingCapacity: true)
    }
    cachedThemes[key] = theme
    return theme
  }

  private static func buildChatTheme(
    textSize: CGFloat,
    columnAlignments: [MacTableColumnAlignment] = []
  ) -> MarkdownUI.Theme {
    MarkdownUI.Theme.basic
      .text {
        ForegroundColor(.primary)
        FontSize(textSize)
      }
      .code {
        FontFamilyVariant(.monospaced)
        FontSize(.em(0.9))
        ForegroundColor(.primary)
        BackgroundColor(Color.primary.opacity(0.06))
      }
      .strong {
        FontWeight(.semibold)
      }
      .link {
        ForegroundColor(.accentColor)
      }
      .heading1 { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .markdownMargin(top: .em(0.8), bottom: .em(0.4))
          .markdownTextStyle {
            FontWeight(.bold)
            FontSize(.em(1.5))
          }
      }
      .heading2 { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .markdownMargin(top: .em(0.72), bottom: .em(0.36))
          .markdownTextStyle {
            FontWeight(.bold)
            FontSize(.em(1.3))
          }
      }
      .heading3 { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .markdownMargin(top: .em(0.6), bottom: .em(0.3))
          .markdownTextStyle {
            FontWeight(.semibold)
            FontSize(.em(1.14))
          }
      }
      .heading4 { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .markdownMargin(top: .em(0.52), bottom: .em(0.24))
          .markdownTextStyle {
            FontWeight(.semibold)
            FontSize(.em(1.02))
            ForegroundColor(.primary)
          }
      }
      .heading5 { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .markdownMargin(top: .em(0.48), bottom: .em(0.2))
          .markdownTextStyle {
            FontWeight(.semibold)
            FontSize(.em(0.94))
            ForegroundColor(.secondary)
          }
      }
      .heading6 { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .markdownMargin(top: .em(0.44), bottom: .em(0.18))
          .markdownTextStyle {
            FontWeight(.semibold)
            FontSize(.em(0.88))
            ForegroundColor(.accentColor)
          }
      }
      .paragraph { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .relativeLineSpacing(.em(0.18))
          .markdownMargin(top: .zero, bottom: .em(0.72))
      }
      .blockquote { configuration in
        HStack(spacing: 0) {
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.accentColor.opacity(0.68))
            .relativeFrame(width: .em(0.18))
          configuration.label
            .markdownTextStyle { ForegroundColor(.secondary) }
            .relativePadding(.horizontal, length: .em(0.85))
            .relativePadding(.vertical, length: .em(0.55))
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
          Color.primary.opacity(0.035),
          in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .markdownMargin(top: .em(0.08), bottom: .em(0.78))
      }
      .listItem { configuration in
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .relativeLineSpacing(.em(0.14))
          .markdownMargin(top: .em(0.12), bottom: .em(0.12))
      }
      .taskListMarker { configuration in
        Image(systemName: configuration.isCompleted ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(configuration.isCompleted ? Color.accentColor : Color.secondary)
          .relativeFrame(minWidth: .em(1.4), alignment: .trailing)
      }
      .table { configuration in
        MacHorizontalPassthroughScrollView {
          configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .markdownTableBorderStyle(.init(color: Color.primary.opacity(0.14)))
            .markdownTableBackgroundStyle(
              .alternatingRows(Color.primary.opacity(0.025), Color.primary.opacity(0.045))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .markdownMargin(top: .em(0.15), bottom: .em(0.85))
      }
      .tableCell { configuration in
        let columnAlignment = configuration.column < columnAlignments.count
          ? columnAlignments[configuration.column] : .leading
        configuration.label
          .markdownTextStyle {
            FontSize(.em(0.9))
            if configuration.row == 0 { FontWeight(.semibold) }
            BackgroundColor(nil)
          }
          .multilineTextAlignment(Self.textAlignment(for: columnAlignment))
          .fixedSize(horizontal: false, vertical: true)
          .frame(
            maxWidth: .infinity,
            alignment: Alignment(
              horizontal: Self.horizontalAlignment(for: columnAlignment),
              vertical: .top
            )
          )
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .relativeLineSpacing(.em(0.18))
      }
      .thematicBreak {
        Rectangle()
          .fill(Color.primary.opacity(0.14))
          .frame(height: 1)
          .markdownMargin(top: .em(1), bottom: .em(1))
      }
  }
}

// MARK: - Custom Markdown Tables

private struct MacMarkdownTablePalette: Sendable {
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
  let borderColor: Color
  let primaryForeground: Color
  let secondaryForeground: Color
  let accentColor: Color

  @MainActor
  init(colorScheme: ColorScheme) {
    let palette = MacThemeFoundation.store
      .currentTheme(hasPro: MacPurchaseStore.manager.hasPro)
      .palette
    let canvas = palette.canvas
    let surface = palette.surface
    let separator = palette.separator
    let codeSurface = palette.codeSurface

    borderColor = separator
    primaryForeground = palette.textPrimary
    secondaryForeground = palette.textMuted
    accentColor = palette.accent

    if colorScheme == .dark {
      cardBackground = surface
      utilityBarBackground = codeSurface.opacity(0.76)
      headerRowBackground = codeSurface
      evenRowBackground = surface
      oddRowBackground = canvas.opacity(0.45)
      codeChipBackground = canvas.opacity(0.78)
      headerDivider = separator
      rowDivider = separator.opacity(0.62)
      columnDivider = separator.opacity(0.38)
      edgeFadeColor = surface
    } else {
      cardBackground = surface
      utilityBarBackground = canvas.opacity(0.62)
      headerRowBackground = codeSurface.opacity(0.9)
      evenRowBackground = surface
      oddRowBackground = canvas.opacity(0.4)
      codeChipBackground = codeSurface
      headerDivider = separator
      rowDivider = separator.opacity(0.65)
      columnDivider = separator.opacity(0.42)
      edgeFadeColor = surface
    }
  }
}

struct MacMarkdownTableView: View {
  let table: MacParsedMarkdownTable
  var textSize: CGFloat = 15
  var fillsWidth = true
  var isComplete = true

  @Environment(\.colorScheme) private var colorScheme
  @State private var measuredWidth: CGFloat = 0
  @State private var showFullScreen = false
  @State private var isCopied = false
  @State private var copyFeedbackRevision = 0

  private var cellFontSize: CGFloat {
    max(12, textSize * 0.9)
  }

  private var effectiveAvailableWidth: CGFloat {
    if measuredWidth > 1 {
      return measuredWidth
    }
    return fillsWidth ? 640 : 320
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
    let palette = MacMarkdownTablePalette(colorScheme: colorScheme)
    let metrics = MacMarkdownTableLayout.compute(
      for: table,
      availableWidth: effectiveAvailableWidth,
      fontSize: cellFontSize,
      fillsWidth: fillsWidth
    )

    VStack(spacing: 0) {
      if fillsWidth {
        utilityBar(palette: palette, overflowsViewport: metrics.overflowsViewport)

        Rectangle()
          .fill(palette.rowDivider)
          .frame(height: 0.5)
      }

      MacHorizontalPassthroughScrollView {
        MacMarkdownTableGrid(
          table: table,
          columnWidths: metrics.columnWidths,
          totalWidth: metrics.totalWidth,
          fontSize: cellFontSize,
          palette: palette
        )
      }
      .overlay(alignment: .leading) {
        if metrics.overflowsViewport {
          LinearGradient(
            colors: [palette.edgeFadeColor.opacity(0.45), palette.edgeFadeColor.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: 12)
          .allowsHitTesting(false)
        }
      }
      .overlay(alignment: .trailing) {
        if metrics.overflowsViewport {
          LinearGradient(
            colors: [palette.edgeFadeColor.opacity(0), palette.edgeFadeColor.opacity(0.92)],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: 24)
          .allowsHitTesting(false)
        }
      }
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    .background(palette.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(palette.borderColor, lineWidth: 0.85)
    }
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
      withAnimation(.easeOut(duration: 0.18)) {
        isCopied = false
      }
    }
    .sheet(isPresented: $showFullScreen) {
      MacFullScreenTableView(table: table, textSize: textSize)
    }
  }

  private func utilityBar(
    palette: MacMarkdownTablePalette,
    overflowsViewport: Bool
  ) -> some View {
    HStack(spacing: 8) {
      Label(dimensionsLabel, systemImage: "tablecells")
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(palette.secondaryForeground)
        .lineLimit(1)

      if overflowsViewport {
        Text("Shift + Scroll")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(palette.secondaryForeground.opacity(0.75))
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
        showFullScreen = true
      }
      .labelStyle(.iconOnly)
      .buttonStyle(MacIconButtonStyle())
      .help("Open full screen")
      .disabled(!isComplete)

      Menu {
        Button("Copy as Markdown", systemImage: "doc.plaintext") {
          copyTable(table.markdownText)
        }
        Button("Copy for Spreadsheets", systemImage: "tablecells") {
          copyTable(table.tsvText)
        }
      } label: {
        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(isCopied ? palette.accentColor : palette.secondaryForeground)
          .frame(
            width: MacDesignTokens.Control.iconButtonSize,
            height: MacDesignTokens.Control.iconButtonSize
          )
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Copy table")
      .accessibilityLabel("Copy Table")
    }
    .foregroundStyle(palette.secondaryForeground)
    .padding(.horizontal, 11)
    .frame(minHeight: 36)
    .background(palette.utilityBarBackground)
  }

  private func copyTable(_ payload: String) {
    NSPasteboard.general.clearContents()
    if NSPasteboard.general.setString(payload, forType: .string) {
      MacAppAnalytics.track(.contentCopied, dimension: .message)
    }
    withAnimation(.easeOut(duration: 0.18)) {
      isCopied = true
    }
    copyFeedbackRevision += 1
  }
}

private struct MacMarkdownTableGrid: View {
  let table: MacParsedMarkdownTable
  let columnWidths: [CGFloat]
  let totalWidth: CGFloat
  let fontSize: CGFloat
  let palette: MacMarkdownTablePalette

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

        MacMarkdownTableCellView(
          text: cellText,
          alignment: alignment,
          isHeader: isHeader,
          fontSize: isHeader ? max(11.5, fontSize * 0.96) : fontSize,
          columnWidth: columnWidth,
          palette: palette
        )
      }
    }
    .background(background)
  }
}

private struct MacMarkdownTableCellView: View {
  let text: String
  let alignment: MacTableColumnAlignment
  let isHeader: Bool
  let fontSize: CGFloat
  let columnWidth: CGFloat
  let palette: MacMarkdownTablePalette

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
      .padding(.horizontal, MacMarkdownTableLayout.cellHorizontalPadding)
      .padding(.vertical, MacMarkdownTableLayout.cellVerticalPadding)
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
        .markdownImageProvider(MacMarkdownResponseImageProvider())
        .markdownTheme(
          MarkdownUI.Theme.basic
            .text {
              ForegroundColor(palette.primaryForeground)
              FontSize(fontSize)
              if isHeader {
                FontWeight(.semibold)
              }
            }
            .link {
              ForegroundColor(palette.accentColor)
            }
        )
        .textSelection(.enabled)
        .tint(palette.accentColor)
    } else if MacAnswerContentParser.shouldRenderCellAsInlineMath(text) {
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
        .foregroundStyle(palette.primaryForeground)
        .textSelection(.enabled)
    } else if let attributed = MacMarkdownTableCellFormatter.attributedString(
      for: text,
      fontSize: fontSize,
      isHeader: isHeader,
      accentColor: palette.accentColor,
      codeChipBackground: palette.codeChipBackground
    ) {
      Text(attributed)
        .font(.system(size: fontSize, weight: isHeader ? .semibold : .regular))
        .monospacedDigit()
        .foregroundStyle(palette.primaryForeground)
        .lineSpacing(2)
        .textSelection(.enabled)
        .tint(palette.accentColor)
    } else {
      Text(text)
        .font(.system(size: fontSize, weight: isHeader ? .semibold : .regular))
        .monospacedDigit()
        .foregroundStyle(palette.primaryForeground)
        .lineSpacing(2)
        .textSelection(.enabled)
    }
  }
}

private enum MacMarkdownTableCellFormatter {
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
          MacAnswerContentParser.isValidBrowsableURL(url),
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

struct MacFullScreenTableView: View {
  let table: MacParsedMarkdownTable
  var textSize: CGFloat = 15

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var sheetWidth: CGFloat = 760
  @State private var isCopied = false
  @State private var copyFeedbackRevision = 0

  private var cellFontSize: CGFloat {
    max(12.5, textSize * 0.92)
  }

  private var titleLabel: String {
    table.rows.isEmpty ? "Table" : "Table (\(table.columnCount) × \(table.rows.count))"
  }

  var body: some View {
    let palette = MacMarkdownTablePalette(colorScheme: colorScheme)
    let metrics = MacMarkdownTableLayout.compute(
      for: table,
      availableWidth: max(360, sheetWidth - 36),
      fontSize: cellFontSize,
      fillsWidth: true,
      maxColumnWidthOverride: 360
    )

    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Label(titleLabel, systemImage: "tablecells")
          .font(.headline)

        Spacer()

        ShareLink(item: table.markdownText) {
          Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(MacIconButtonStyle())
        .help("Share table")

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
            .foregroundStyle(isCopied ? palette.accentColor : palette.secondaryForeground)
            .frame(
              width: MacDesignTokens.Control.iconButtonSize,
              height: MacDesignTokens.Control.iconButtonSize
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy table")
        .accessibilityLabel("Copy Table")

        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(14)

      Divider()

      ScrollView([.horizontal, .vertical]) {
        MacMarkdownTableGrid(
          table: table,
          columnWidths: metrics.columnWidths,
          totalWidth: metrics.totalWidth,
          fontSize: cellFontSize,
          palette: palette
        )
        .background(palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(palette.borderColor, lineWidth: 0.85)
        }
        .padding(18)
      }
      .background(MacDesignTokens.Colors.canvas)
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.width
      } action: { newWidth in
        if newWidth > 1, abs(newWidth - sheetWidth) > 1 {
          sheetWidth = newWidth
        }
      }
    }
    .frame(minWidth: 740, minHeight: 500)
    .environment(
      \.openURL,
      OpenURLAction { url in
        guard MacAnswerContentParser.isValidBrowsableURL(url) else {
          return .systemAction
        }
        NSWorkspace.shared.open(url)
        return .handled
      }
    )
    .task(id: copyFeedbackRevision) {
      guard copyFeedbackRevision > 0 else { return }
      try? await Task.sleep(for: .seconds(1.4))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.18)) {
        isCopied = false
      }
    }
  }

  private func copyTable(_ payload: String) {
    NSPasteboard.general.clearContents()
    if NSPasteboard.general.setString(payload, forType: .string) {
      MacAppAnalytics.track(.contentCopied, dimension: .message)
    }
    withAnimation(.easeOut(duration: 0.18)) {
      isCopied = true
    }
    copyFeedbackRevision += 1
  }
}

// MARK: - Inline Response Image Provider

enum MacMarkdownImageSupport {
  static let maxByteCount = 20 * 1_024 * 1_024

  private final class RawByteCache: @unchecked Sendable {
    let storage: NSCache<NSString, NSData> = {
      let cache = NSCache<NSString, NSData>()
      cache.countLimit = 48
      cache.totalCostLimit = 24 * 1_024 * 1_024
      return cache
    }()
  }

  private static let rawByteCache = RawByteCache()

  static func isSupportedURL(_ url: URL) -> Bool {
    if MacAnswerContentParser.isValidBrowsableURL(url) { return true }
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
    guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
      !data.isEmpty,
      data.count <= maxByteCount
    else { return nil }
    return (data, meta.filename, meta.mimeType)
  }

  static func metadata(for url: URL) -> (filename: String, mimeType: String) {
    if let dataMeta = dataURIMetadata(for: url) {
      return dataMeta
    }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
    let rawName = url.lastPathComponent
      .components(separatedBy: allowed.inverted)
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let filename: String
    if !rawName.isEmpty, rawName.contains(".") {
      filename = String(rawName.prefix(80))
    } else if !rawName.isEmpty {
      filename = "\(String(rawName.prefix(76))).jpg"
    } else {
      filename = "image.jpg"
    }
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

    guard MacAnswerContentParser.isValidBrowsableURL(url) else { return nil }
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

  static func decodeCGImage(from data: Data, maxPixelSize: CGFloat?) async -> CGImage? {
    await Task.detached(priority: .utility) {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
      if let maxPixelSize {
        let options: [CFString: Any] = [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maxPixelSize.rounded())),
          kCGImageSourceShouldCacheImmediately: true,
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
          return thumb
        }
      }
      return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }.value
  }
}

@MainActor
private final class MacDecodedImageCache {
  static let shared = MacDecodedImageCache()

  private let storage: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 48
    return cache
  }()

  func image(forKey key: String) -> NSImage? {
    storage.object(forKey: key as NSString)
  }

  func insert(_ image: NSImage, forKey key: String) {
    storage.setObject(image, forKey: key as NSString)
  }
}

struct MacMarkdownResponseImageProvider: ImageProvider {
  func makeImage(url: URL?) -> some View {
    MacMarkdownResponseImageView(url: url)
  }
}

private struct MacImageViewerPayload: Identifiable {
  let id = UUID()
  let title: String
  let image: NSImage
  let rawData: Data?
}

struct MacMarkdownResponseImageView: View {
  let url: URL?

  @Environment(\.displayScale) private var displayScale
  @State private var image: NSImage?
  @State private var isFailed = false
  @State private var isOpeningPreview = false
  @State private var preview: MacImageViewerPayload?

  nonisolated init(url: URL?) {
    self.url = url
  }

  private var displayPixelSize: CGFloat {
    min(1_200, max(360, 360 * displayScale))
  }

  private func decodedCacheKey(for baseKey: String) -> String {
    "\(baseKey)@\(Int(displayPixelSize.rounded()))"
  }

  var body: some View {
    let cacheKey = url.map(MacMarkdownImageSupport.cacheKey(for:))
    let resolvedImage = image ?? cacheKey.flatMap {
      MacDecodedImageCache.shared.image(forKey: decodedCacheKey(for: $0))
    }

    Group {
      if let resolvedImage {
        Button {
          openFullScreen(fallbackImage: resolvedImage)
        } label: {
          Image(nsImage: resolvedImage)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MacDesignTokens.Colors.separator.opacity(0.85), lineWidth: 0.85)
            }
        }
        .buttonStyle(.plain)
        .help("Click to view full screen")
        .accessibilityLabel("Image")
      } else if isFailed || url == nil {
        HStack(spacing: 8) {
          Image(systemName: "photo.badge.exclamationmark")
          Text("Image unavailable")
            .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
          MacDesignTokens.Colors.surface,
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(MacDesignTokens.Colors.separator.opacity(0.85), lineWidth: 0.85)
        }
      } else {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(MacDesignTokens.Colors.surface)
          .frame(maxWidth: .infinity)
          .frame(height: 180)
          .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(MacDesignTokens.Colors.separator.opacity(0.85), lineWidth: 0.85)
          }
          .overlay {
            VStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Image(systemName: "photo")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.45))
            }
          }
      }
    }
    .task(id: url) {
      await loadImage()
    }
    .sheet(item: $preview) { item in
      MacZoomableImageSheet(
        title: item.title,
        image: item.image,
        rawData: item.rawData
      )
    }
  }

  private func loadImage() async {
    guard let url, MacMarkdownImageSupport.isSupportedURL(url) else {
      isFailed = true
      return
    }
    let key = decodedCacheKey(for: MacMarkdownImageSupport.cacheKey(for: url))
    if let cached = MacDecodedImageCache.shared.image(forKey: key) {
      image = cached
      isFailed = false
      return
    }
    image = nil
    isFailed = false

    guard let loaded = await MacMarkdownImageSupport.loadBytes(for: url) else {
      if !Task.isCancelled { isFailed = true }
      return
    }
    guard !Task.isCancelled else { return }

    if let cgImage = await MacMarkdownImageSupport.decodeCGImage(
      from: loaded.data,
      maxPixelSize: displayPixelSize
    ) {
      guard !Task.isCancelled else { return }
      let decoded = NSImage(
        cgImage: cgImage,
        size: NSSize(width: cgImage.width, height: cgImage.height)
      )
      MacDecodedImageCache.shared.insert(decoded, forKey: key)
      image = decoded
    } else if let direct = NSImage(data: loaded.data) {
      guard !Task.isCancelled else { return }
      MacDecodedImageCache.shared.insert(direct, forKey: key)
      image = direct
    } else if !Task.isCancelled {
      isFailed = true
    }
  }

  private func openFullScreen(fallbackImage: NSImage) {
    guard !isOpeningPreview, let url else { return }
    isOpeningPreview = true
    Task { @MainActor in
      defer { isOpeningPreview = false }
      let loaded = await MacMarkdownImageSupport.loadBytes(for: url)
      let fallbackMeta = MacMarkdownImageSupport.metadata(for: url)
      let filename = loaded?.filename ?? fallbackMeta.filename
      let rawData = loaded?.data
      var fullImage = fallbackImage
      if let rawData {
        if let cgImage = await MacMarkdownImageSupport.decodeCGImage(
          from: rawData,
          maxPixelSize: nil
        ) {
          fullImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
          )
        } else if let direct = NSImage(data: rawData) {
          fullImage = direct
        }
      }
      preview = MacImageViewerPayload(
        title: filename,
        image: fullImage,
        rawData: rawData
      )
    }
  }
}

struct MacZoomableImageSheet: View {
  let title: String
  let image: NSImage
  var rawData: Data? = nil

  @Environment(\.dismiss) private var dismiss
  @State private var zoomScale: CGFloat = 1.0
  @State private var statusBanner: String?
  @State private var statusBannerRevision = 0
  @State private var saveErrorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(title)
          .font(.headline)
          .lineLimit(1)

        Spacer()

        zoomControls

        Divider()
          .frame(height: 16)

        Button("Save Image…", systemImage: "square.and.arrow.down") {
          saveImage()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(MacIconButtonStyle())
        .help("Save image…")

        Button("Copy Image", systemImage: "doc.on.doc") {
          copyImage()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(MacIconButtonStyle())
        .help("Copy image")

        ShareLink(
          item: Image(nsImage: image),
          preview: SharePreview(title, image: Image(nsImage: image))
        ) {
          Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(MacIconButtonStyle())
        .help("Share image")

        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(14)

      Divider()

      ZStack(alignment: .bottom) {
        MacZoomableImageCanvas(image: image, zoomScale: $zoomScale)
          .background(MacDesignTokens.Colors.canvas)

        if let statusBanner {
          Label(statusBanner, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(MacDesignTokens.Colors.surface, in: Capsule())
            .overlay {
              Capsule()
                .stroke(MacDesignTokens.Colors.separator, lineWidth: 0.75)
            }
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.easeInOut(duration: 0.18), value: statusBanner)
    }
    .frame(minWidth: 740, minHeight: 540)
    .task(id: statusBannerRevision) {
      guard statusBannerRevision > 0 else { return }
      try? await Task.sleep(for: .seconds(1.8))
      guard !Task.isCancelled else { return }
      statusBanner = nil
    }
    .alert(
      "Could Not Save Image",
      isPresented: Binding(
        get: { saveErrorMessage != nil },
        set: { if !$0 { saveErrorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { saveErrorMessage = nil }
    } message: {
      Text(saveErrorMessage ?? "Unknown error")
    }
  }

  private var zoomControls: some View {
    HStack(spacing: 4) {
      Button("Zoom Out", systemImage: "minus.magnifyingglass") {
        withAnimation(.easeOut(duration: 0.15)) {
          zoomScale = max(0.5, (zoomScale - 0.25).roundedToQuarter)
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(MacIconButtonStyle())
      .help("Zoom out")
      .keyboardShortcut("-", modifiers: .command)

      Button {
        withAnimation(.easeOut(duration: 0.18)) {
          zoomScale = 1.0
        }
      } label: {
        Text("\(Int((zoomScale * 100).rounded()))%")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .frame(minWidth: 44)
      }
      .buttonStyle(MacSecondaryButtonStyle())
      .help("Reset zoom")
      .keyboardShortcut("0", modifiers: .command)

      Button("Zoom In", systemImage: "plus.magnifyingglass") {
        withAnimation(.easeOut(duration: 0.15)) {
          zoomScale = min(6.0, (zoomScale + 0.25).roundedToQuarter)
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(MacIconButtonStyle())
      .help("Zoom in")
      .keyboardShortcut("+", modifiers: .command)
    }
  }

  private func copyImage() {
    NSPasteboard.general.clearContents()
    if NSPasteboard.general.writeObjects([image]) {
      showStatusBanner("Copied Image")
    }
  }

  private func saveImage() {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    let ext = (title as NSString).pathExtension.lowercased()
    if let rawData, !rawData.isEmpty, let contentType = UTType(filenameExtension: ext),
      contentType.conforms(to: .image)
    {
      panel.allowedContentTypes = [contentType, .png]
      panel.nameFieldStringValue = title
    } else {
      panel.allowedContentTypes = [.png]
      let baseName = (title as NSString).deletingPathExtension
      panel.nameFieldStringValue = "\(baseName.isEmpty ? "image" : baseName).png"
    }

    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      let destinationExt = destination.pathExtension.lowercased()
      let payload: Data?
      if destinationExt == "png" {
        payload = MacMermaidDiagramSupport.pngData(from: image) ?? rawData
      } else {
        payload = rawData ?? MacMermaidDiagramSupport.pngData(from: image)
      }
      guard let payload else {
        throw CocoaError(.fileWriteUnknown)
      }
      try payload.write(to: destination, options: .atomic)
      showStatusBanner("Saved Image")
    } catch {
      saveErrorMessage = error.localizedDescription
    }
  }

  private func showStatusBanner(_ message: String) {
    statusBanner = message
    statusBannerRevision += 1
  }
}

private struct MacZoomableImageCanvas: View {
  let image: NSImage
  @Binding var zoomScale: CGFloat

  @State private var offset: CGSize = .zero
  @State private var dragStartOffset: CGSize = .zero
  @State private var pinchStartScale: CGFloat?

  var body: some View {
    GeometryReader { proxy in
      let canvasSize = proxy.size
      let effectiveScale = max(0.5, min(6.0, zoomScale))

      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: max(1, canvasSize.width - 32), maxHeight: max(1, canvasSize.height - 32))
        .scaleEffect(effectiveScale)
        .offset(effectiveScale > 1.01 ? offset : .zero)
        .frame(width: canvasSize.width, height: canvasSize.height)
        .contentShape(Rectangle())
        .gesture(
          MagnifyGesture()
            .onChanged { value in
              let base = pinchStartScale ?? zoomScale
              if pinchStartScale == nil { pinchStartScale = base }
              let clamped = max(0.5, min(6.0, base * value.magnification))
              zoomScale = clamped
              if clamped <= 1.01 {
                offset = .zero
                dragStartOffset = .zero
              } else {
                offset = clampedOffset(offset, scale: clamped, canvasSize: canvasSize)
              }
            }
            .onEnded { _ in
              pinchStartScale = nil
              if zoomScale <= 1.01 {
                offset = .zero
                dragStartOffset = .zero
              } else {
                offset = clampedOffset(offset, scale: zoomScale, canvasSize: canvasSize)
                dragStartOffset = offset
              }
            }
        )
        .simultaneousGesture(
          DragGesture()
            .onChanged { value in
              guard zoomScale > 1.01 else { return }
              let proposed = CGSize(
                width: dragStartOffset.width + value.translation.width,
                height: dragStartOffset.height + value.translation.height
              )
              offset = clampedOffset(proposed, scale: zoomScale, canvasSize: canvasSize)
            }
            .onEnded { _ in
              guard zoomScale > 1.01 else {
                offset = .zero
                dragStartOffset = .zero
                return
              }
              dragStartOffset = offset
            }
        )
        .onTapGesture(count: 2) {
          withAnimation(.easeOut(duration: 0.2)) {
            if zoomScale > 1.05 {
              zoomScale = 1.0
              offset = .zero
              dragStartOffset = .zero
            } else {
              zoomScale = 2.5
            }
          }
        }
        .onChange(of: zoomScale) { _, newScale in
          if newScale <= 1.01 {
            offset = .zero
            dragStartOffset = .zero
          } else {
            offset = clampedOffset(offset, scale: newScale, canvasSize: canvasSize)
            dragStartOffset = offset
          }
        }
    }
    .clipped()
  }

  private func clampedOffset(
    _ proposed: CGSize,
    scale: CGFloat,
    canvasSize: CGSize
  ) -> CGSize {
    let maxX = max(0, (canvasSize.width * (scale - 1)) / 2 + 40)
    let maxY = max(0, (canvasSize.height * (scale - 1)) / 2 + 40)
    return CGSize(
      width: min(max(proposed.width, -maxX), maxX),
      height: min(max(proposed.height, -maxY), maxY)
    )
  }
}

private extension CGFloat {
  var roundedToQuarter: CGFloat {
    (self * 4).rounded() / 4
  }
}

// MARK: - Code Blocks

struct MacHighlightedCodeBlock: View {
  nonisolated static let collapseLineThreshold = 18
  nonisolated static let collapseCharacterThreshold = 1_800

  nonisolated struct Preview: Equatable, Sendable {
    let displayedContent: String
    let isLong: Bool
    let lineCount: Int
    let toggleLabel: String
  }

  nonisolated static func preview(
    for content: String,
    isExpanded: Bool,
    isStreaming: Bool = false
  ) -> Preview {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    let exceedsLines = lines.count > collapseLineThreshold
    let exceedsCharacters = content.count > collapseCharacterThreshold
    let isLong = exceedsLines || exceedsCharacters

    let displayedContent: String
    if isLong, !isExpanded, !isStreaming {
      let lineCapped = exceedsLines
        ? lines.prefix(collapseLineThreshold).joined(separator: "\n")
        : content
      let charCapped = lineCapped.count > collapseCharacterThreshold
        ? String(lineCapped.prefix(collapseCharacterThreshold))
        : lineCapped
      displayedContent = charCapped + "\n…"
    } else {
      displayedContent = content
    }

    let toggleLabel: String
    if isExpanded {
      toggleLabel = "Show less"
    } else if exceedsLines {
      toggleLabel = "Show all \(lines.count) lines"
    } else {
      toggleLabel = "Show all"
    }

    return Preview(
      displayedContent: displayedContent,
      isLong: isLong,
      lineCount: lines.count,
      toggleLabel: toggleLabel
    )
  }

  let language: String?
  let content: String
  var isStreaming = false

  @Environment(\.colorScheme) private var colorScheme
  @State private var isExpanded = false
  @State private var showFullScreen = false
  @State private var copied = false

  private var languageLabel: String {
    let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? "CODE" : value.uppercased()
  }

  var body: some View {
    let preview = Self.preview(for: content, isExpanded: isExpanded, isStreaming: isStreaming)

    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Circle()
          .fill(Color.accentColor)
          .frame(width: 6, height: 6)
        Text(languageLabel)
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(.secondary)
        if isStreaming {
          Text("STREAMING")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        Spacer()
        if !isStreaming {
          Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") {
            showFullScreen = true
          }
          .labelStyle(.iconOnly)
          .help("Open code")
        }
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
          copyCode()
        }
        .labelStyle(.iconOnly)
        .help(copied ? "Copied" : "Copy code")
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 11)
      .frame(minHeight: 38)
      .background(Color.primary.opacity(0.045))

      Divider()

      ScrollView(.horizontal) {
        if isStreaming {
          Text(preview.displayedContent)
            .font(.system(size: 13, design: .monospaced))
            .fixedSize(horizontal: true, vertical: true)
            .textSelection(.enabled)
            .padding(13)
        } else {
          MacHighlightedCodeText(
            code: preview.displayedContent,
            language: language,
            colorScheme: colorScheme
          )
          .padding(13)
        }
      }
      .scrollIndicators(.visible)

      if preview.isLong && !isStreaming {
        Divider()
        Button {
          isExpanded.toggle()
        } label: {
          Label(
            preview.toggleLabel,
            systemImage: isExpanded ? "chevron.up" : "chevron.down"
          )
          .font(.caption.weight(.medium))
          .frame(maxWidth: .infinity)
          .frame(height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
    }
    .sheet(isPresented: $showFullScreen) {
      MacFullScreenCodeView(language: language, content: content)
    }
  }

  private func copyCode() {
    NSPasteboard.general.clearContents()
    if NSPasteboard.general.setString(content, forType: .string) {
      MacAppAnalytics.track(.contentCopied, dimension: .code)
    }
    copied = true
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.2))
      copied = false
    }
  }
}

private struct MacHighlightedCodeText: View {
  private struct RenderKey: Equatable {
    let code: String
    let language: String?
    let isDark: Bool
  }

  let code: String
  let language: String?
  let colorScheme: ColorScheme

  @State private var highlighted: AttributedString?
  @State private var highlightedKey: RenderKey?

  var body: some View {
    Group {
      if let highlighted, highlightedKey == renderKey {
        Text(highlighted)
      } else {
        Text(code)
          .font(.system(size: 13, design: .monospaced))
      }
    }
    .fixedSize(horizontal: true, vertical: true)
    .textSelection(.enabled)
    .task(id: renderKey) {
      let key = renderKey
      let rendered = await MacSyntaxHighlighting.shared.render(
        code: code,
        language: language,
        isDark: colorScheme == .dark
      )
      guard !Task.isCancelled else { return }
      highlighted = rendered
      highlightedKey = rendered != nil ? key : nil
    }
  }

  private var renderKey: RenderKey {
    RenderKey(
      code: code,
      language: language,
      isDark: colorScheme == .dark
    )
  }
}

private actor MacSyntaxHighlighting {
  private struct CacheKey: Hashable, Sendable {
    let code: String
    let language: String?
    let isDark: Bool
  }

  static let shared = MacSyntaxHighlighting()

  private var highlighter: Highlighter?
  private var configuredTheme: String?
  private var cache: [CacheKey: AttributedString] = [:]
  private var order: [CacheKey] = []
  private let limit = 72

  func render(code: String, language: String?, isDark: Bool) -> AttributedString? {
    guard !Task.isCancelled else { return nil }
    let key = CacheKey(code: code, language: language, isDark: isDark)
    if let cached = cache[key] { return cached }

    if highlighter == nil {
      highlighter = Highlighter()
    }
    guard let highlighter else { return nil }

    let themeName = isDark ? "github-dark" : "github"
    if configuredTheme != themeName {
      _ = highlighter.setTheme(
        themeName,
        withFont: "Menlo-Regular",
        ofSize: 13
      )
      configuredTheme = themeName
    }

    guard !Task.isCancelled else { return nil }
    guard let value = highlighter.highlight(code, as: normalize(language)) else { return nil }

    let mutable = NSMutableAttributedString(attributedString: value)
    mutable.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: mutable.length))
    let rendered = AttributedString(mutable)
    cache[key] = rendered
    order.append(key)
    if order.count > limit {
      cache.removeValue(forKey: order.removeFirst())
    }
    return rendered
  }

  private func normalize(_ language: String?) -> String? {
    guard let value = language?.lowercased(), !value.isEmpty else { return nil }
    switch value {
    case "text", "txt", "plaintext", "plain": return nil
    case "js": return "javascript"
    case "ts": return "typescript"
    case "py": return "python"
    case "rb": return "ruby"
    case "sh", "shell", "zsh": return "bash"
    case "objc", "objective-c": return "objectivec"
    case "c++", "cplusplus": return "cpp"
    case "c#": return "csharp"
    case "html": return "xml"
    default: return value
    }
  }
}

private struct MacFullScreenCodeView: View {
  let language: String?
  let content: String

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(language?.uppercased() ?? "CODE")
          .font(.headline.monospaced())
        Spacer()
        ShareLink(item: content) {
          Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(MacIconButtonStyle())
        .help("Share code")
        Button("Copy", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          if NSPasteboard.general.setString(content, forType: .string) {
            MacAppAnalytics.track(.contentCopied, dimension: .code)
          }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(MacIconButtonStyle())
        .help("Copy code")
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(14)
      Divider()
      ScrollView([.horizontal, .vertical]) {
        MacHighlightedCodeText(code: content, language: language, colorScheme: colorScheme)
          .padding(18)
      }
    }
    .frame(minWidth: 720, minHeight: 500)
  }
}

// MARK: - Math

struct MacMathAnswerView: View {
  let expression: String

  var body: some View {
    LaTeX("$$\(expression)$$")
      .blockMode(.blockViews)
      .renderingStyle(.redactedOriginal)
      .renderingAnimation(.easeOut(duration: 0.18))
      .errorMode(.original)
      .imageRenderingMode(.template)
      .imageAccessibility(.sre)
      .font(.body)
      .foregroundStyle(.primary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, 12)
      .padding(.vertical, 14)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      }
  }
}

// MARK: - Mermaid Diagrams

enum MacMermaidDiagramSupport {
  enum CanvasRole {
    case inlineCard
    case fullScreen
  }

  struct Analysis: Equatable, Sendable {
    let renderSource: String
    let title: String?
    let kindLabel: String
    let displayTitle: String
    let unsupportedKindName: String?
    let isEmpty: Bool

    var headerLabel: String {
      if let title, !title.isEmpty {
        return "\(kindLabel) · \(title)"
      }
      return kindLabel
    }
  }

  private struct RenderedDiagramBitmap: Sendable {
    let cgImage: CGImage
    let pointSize: CGSize
  }

  static let defaultInlineHeight: CGFloat = 180
  static let minInlineHeight: CGFloat = 110
  static let maxInlineHeight: CGFloat = 420
  static let inlineVerticalPadding: CGFloat = 20

  /// Analyzes Mermaid source to strip leading YAML frontmatter, extract an
  /// optional title, classify the diagram type, and flag unsupported Mermaid
  /// diagram types.
  static func analyze(_ source: String) -> Analysis {
    let (strippedSource, frontmatterTitle) = stripLeadingFrontmatter(from: source)
    let trimmed = strippedSource.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return Analysis(
        renderSource: "",
        title: frontmatterTitle,
        kindLabel: "DIAGRAM",
        displayTitle: "Diagram",
        unsupportedKindName: nil,
        isEmpty: true
      )
    }

    let firstDirective = firstDiagramDirectiveLine(in: strippedSource)
    let firstToken = firstDirective?
      .split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "{" })
      .first
      .map { String($0).lowercased() } ?? ""

    let classification = classify(token: firstToken, line: firstDirective?.lowercased() ?? "")
    return Analysis(
      renderSource: strippedSource,
      title: frontmatterTitle,
      kindLabel: classification.kindLabel,
      displayTitle: classification.displayTitle,
      unsupportedKindName: classification.unsupportedKindName,
      isEmpty: false
    )
  }

  static func inlineHeight(for diagramBounds: CGRect, availableWidth: CGFloat) -> CGFloat {
    guard diagramBounds.width > 0, diagramBounds.height > 0 else {
      return defaultInlineHeight
    }
    let usableWidth = max(160, availableWidth)
    let fitScale = min(1.0, usableWidth / diagramBounds.width)
    let fittedHeight = ceil(diagramBounds.height * fitScale) + inlineVerticalPadding
    return min(max(fittedHeight, minInlineHeight), maxInlineHeight)
  }

  static func renderScale(
    for diagramSize: CGSize,
    desiredScale: CGFloat = 3.0,
    maxPixelDimension: CGFloat = 4096
  ) -> CGFloat {
    let safeDesired = max(1.0, min(desiredScale, 3.0))
    let maxDim = max(diagramSize.width, diagramSize.height)
    guard maxDim > 0 else { return safeDesired }
    return max(1.0, min(safeDesired, maxPixelDimension / maxDim))
  }

  /// Builds a `DiagramTheme` matched to the active macOS app theme palette.
  @MainActor
  static func diagramTheme(
    colorScheme: ColorScheme,
    canvas: CanvasRole
  ) -> DiagramTheme {
    let palette = MacThemeFoundation.store
      .currentTheme(hasPro: MacPurchaseStore.manager.hasPro)
      .palette

    let canvasColor: Color
    let nodeSurfaceColor: Color

    switch (canvas, colorScheme) {
    case (.inlineCard, .dark):
      canvasColor = palette.surface
      nodeSurfaceColor = palette.codeSurface
    case (.inlineCard, _):
      canvasColor = palette.surface
      nodeSurfaceColor = palette.canvas
    case (.fullScreen, .dark):
      canvasColor = palette.canvas
      nodeSurfaceColor = palette.surface
    case (.fullScreen, _):
      canvasColor = palette.canvas
      nodeSurfaceColor = palette.codeSurface
    }

    return DiagramTheme(
      background: NSColor(canvasColor),
      foreground: NSColor(palette.textPrimary),
      line: nil,
      accent: NSColor(palette.accent),
      muted: NSColor(palette.textMuted),
      surface: NSColor(nodeSurfaceColor),
      border: NSColor(palette.separator)
    )
  }

  @MainActor
  static func renderImage(
    source: String,
    theme: DiagramTheme,
    desiredScale: CGFloat = 3.0
  ) async throws -> NSImage? {
    let bitmap: RenderedDiagramBitmap? = try await Task.detached(priority: .userInitiated) {
      let positioned = try MermaidRenderer.layout(source)
      let scale = renderScale(
        for: CGSize(width: positioned.width, height: positioned.height),
        desiredScale: desiredScale
      )
      let renderer = MermaidImageRenderer(theme: theme)
      guard let image = renderer.renderImage(from: positioned, scale: scale) else {
        return nil
      }
      var proposedRect = CGRect(origin: .zero, size: image.size)
      if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
        return RenderedDiagramBitmap(cgImage: cgImage, pointSize: image.size)
      }
      if let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let cgImage = rep.cgImage
      {
        return RenderedDiagramBitmap(cgImage: cgImage, pointSize: image.size)
      }
      return nil
    }.value

    guard let bitmap else { return nil }
    return NSImage(cgImage: bitmap.cgImage, size: bitmap.pointSize)
  }

  @MainActor
  static func pngData(from image: NSImage) -> Data? {
    var proposedRect = CGRect(origin: .zero, size: image.size)
    if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
      let rep = NSBitmapImageRep(cgImage: cgImage)
      return rep.representation(using: .png, properties: [:])
    }
    guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff)
    else { return nil }
    return rep.representation(using: .png, properties: [:])
  }

  static func suggestedFilename(for title: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
    let cleaned = title
      .components(separatedBy: allowed.inverted)
      .joined()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: "-")
    let base = cleaned.isEmpty ? "diagram" : String(cleaned.prefix(64))
    return "\(base).png"
  }

  private struct Classification {
    let kindLabel: String
    let displayTitle: String
    let unsupportedKindName: String?
  }

  private static func classify(token: String, line: String) -> Classification {
    if token == "graph" || token.hasPrefix("flowchart") {
      return Classification(kindLabel: "FLOWCHART", displayTitle: "Flowchart", unsupportedKindName: nil)
    }
    if token.hasPrefix("sequencediagram") {
      return Classification(
        kindLabel: "SEQUENCE",
        displayTitle: "Sequence Diagram",
        unsupportedKindName: nil
      )
    }
    if token.hasPrefix("statediagram") {
      return Classification(
        kindLabel: "STATE",
        displayTitle: "State Diagram",
        unsupportedKindName: nil
      )
    }
    if token.hasPrefix("classdiagram") {
      return Classification(
        kindLabel: "CLASS",
        displayTitle: "Class Diagram",
        unsupportedKindName: nil
      )
    }
    if token.hasPrefix("erdiagram") {
      return Classification(
        kindLabel: "ER DIAGRAM",
        displayTitle: "ER Diagram",
        unsupportedKindName: nil
      )
    }
    if token.hasPrefix("xychart") {
      return Classification(kindLabel: "XY CHART", displayTitle: "XY Chart", unsupportedKindName: nil)
    }

    // Known Mermaid diagram types not supported by BeautifulMermaid 1.0.4.
    switch token {
    case "pie":
      return Classification(kindLabel: "PIE CHART", displayTitle: "Pie Chart", unsupportedKindName: "Pie charts")
    case "gantt":
      return Classification(kindLabel: "GANTT", displayTitle: "Gantt Chart", unsupportedKindName: "Gantt charts")
    case "mindmap":
      return Classification(kindLabel: "MINDMAP", displayTitle: "Mindmap", unsupportedKindName: "Mindmaps")
    case "timeline":
      return Classification(kindLabel: "TIMELINE", displayTitle: "Timeline", unsupportedKindName: "Timelines")
    case "gitgraph":
      return Classification(kindLabel: "GIT GRAPH", displayTitle: "Git Graph", unsupportedKindName: "Git graphs")
    case "journey":
      return Classification(
        kindLabel: "JOURNEY",
        displayTitle: "User Journey",
        unsupportedKindName: "User journey diagrams"
      )
    case "quadrantchart":
      return Classification(
        kindLabel: "QUADRANT",
        displayTitle: "Quadrant Chart",
        unsupportedKindName: "Quadrant charts"
      )
    case "sankey", "sankey-beta":
      return Classification(
        kindLabel: "SANKEY",
        displayTitle: "Sankey Diagram",
        unsupportedKindName: "Sankey diagrams"
      )
    case "requirementdiagram":
      return Classification(
        kindLabel: "REQUIREMENT",
        displayTitle: "Requirement Diagram",
        unsupportedKindName: "Requirement diagrams"
      )
    case "block", "block-beta":
      return Classification(
        kindLabel: "BLOCK",
        displayTitle: "Block Diagram",
        unsupportedKindName: "Block diagrams"
      )
    case "architecture", "architecture-beta":
      return Classification(
        kindLabel: "ARCHITECTURE",
        displayTitle: "Architecture Diagram",
        unsupportedKindName: "Architecture diagrams"
      )
    case "kanban":
      return Classification(
        kindLabel: "KANBAN",
        displayTitle: "Kanban Board",
        unsupportedKindName: "Kanban boards"
      )
    case "packet", "packet-beta":
      return Classification(
        kindLabel: "PACKET",
        displayTitle: "Packet Diagram",
        unsupportedKindName: "Packet diagrams"
      )
    case "radar", "radar-beta":
      return Classification(
        kindLabel: "RADAR",
        displayTitle: "Radar Chart",
        unsupportedKindName: "Radar charts"
      )
    default:
      if token.hasPrefix("c4") || line.hasPrefix("c4") {
        return Classification(
          kindLabel: "C4 DIAGRAM",
          displayTitle: "C4 Diagram",
          unsupportedKindName: "C4 diagrams"
        )
      }
      return Classification(kindLabel: "DIAGRAM", displayTitle: "Diagram", unsupportedKindName: nil)
    }
  }

  private static func stripLeadingFrontmatter(from source: String) -> (String, String?) {
    let lines = source.components(separatedBy: .newlines)
    guard let firstNonEmptyIndex = lines.firstIndex(where: {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) else {
      return (source, nil)
    }

    guard lines[firstNonEmptyIndex].trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
      return (source, nil)
    }

    var closingIndex: Int?
    var title: String?
    for index in (firstNonEmptyIndex + 1)..<lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == "---" || trimmed == "..." {
        closingIndex = index
        break
      }
      if title == nil, trimmed.lowercased().hasPrefix("title:") {
        let rawTitle = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted = stripMatchingQuotes(rawTitle)
        if !unquoted.isEmpty {
          title = unquoted
        }
      }
    }

    guard let closingIndex else {
      return (source, nil)
    }

    let remainder = lines[(closingIndex + 1)...].joined(separator: "\n")
    return (remainder, title)
  }

  private static func stripMatchingQuotes(_ value: String) -> String {
    guard value.count >= 2 else { return value }
    if (value.hasPrefix("\"") && value.hasSuffix("\""))
      || (value.hasPrefix("'") && value.hasSuffix("'"))
    {
      return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value
  }

  private static func firstDiagramDirectiveLine(in source: String) -> String? {
    var inInitDirective = false
    for rawLine in source.components(separatedBy: .newlines) {
      let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if inInitDirective {
        if trimmed.contains("}%%") {
          inInitDirective = false
        }
        continue
      }
      if trimmed.hasPrefix("%%{") {
        if !trimmed.contains("}%%") {
          inInitDirective = true
        }
        continue
      }
      if trimmed.hasPrefix("%%") { continue }
      return trimmed
    }
    return nil
  }
}

struct MacMermaidAnswerView: View {
  let source: String
  var isComplete: Bool = true

  @Environment(\.colorScheme) private var colorScheme
  @State private var parseError: Error?
  @State private var diagramBounds = CGRect.zero
  @State private var cardWidth: CGFloat = 560
  @State private var showFullScreen = false
  @State private var showSource = false
  @State private var isSourceExpanded = false
  @State private var copied = false

  private let collapsedLineLimit = 14
  private let collapsedCharacterLimit = 1_800

  var body: some View {
    let analysis = MacMermaidDiagramSupport.analyze(source)
    let canRenderDiagram = isComplete
      && !analysis.isEmpty
      && analysis.unsupportedKindName == nil
      && parseError == nil
    let inlineTheme = MacMermaidDiagramSupport.diagramTheme(
      colorScheme: colorScheme,
      canvas: .inlineCard
    )
    let availableDiagramWidth = max(160, cardWidth - 16)
    let diagramHeight = MacMermaidDiagramSupport.inlineHeight(
      for: diagramBounds,
      availableWidth: availableDiagramWidth
    )
    let isScaledDown = diagramBounds.width > availableDiagramWidth * 1.15

    VStack(spacing: 0) {
      header(analysis: analysis, canRenderDiagram: canRenderDiagram)

      Divider()

      if !isComplete {
        streamingBody
      } else if analysis.isEmpty {
        Text("Empty diagram block.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
      } else if let unsupportedKindName = analysis.unsupportedKindName {
        unsupportedBody(kindName: unsupportedKindName)
      } else if let parseError {
        errorBody(error: parseError)
      } else if showSource {
        collapsibleSourceBody(content: source)
      } else {
        ZStack(alignment: .bottomTrailing) {
          GeometryReader { proxy in
            MermaidDiagramView(
              source: analysis.renderSource,
              theme: inlineTheme,
              parseError: $parseError,
              diagramBounds: $diagramBounds
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
          }
          .frame(height: diagramHeight)
          .padding(8)

          if isScaledDown {
            Label("Click to zoom", systemImage: "plus.magnifyingglass")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .padding(.horizontal, 9)
              .padding(.vertical, 5)
              .background(
                MacDesignTokens.Colors.codeSurface.opacity(0.92),
                in: Capsule()
              )
              .overlay {
                Capsule()
                  .stroke(MacDesignTokens.Colors.separator, lineWidth: 0.6)
              }
              .padding(10)
              .allowsHitTesting(false)
          }
        }
        .contentShape(Rectangle())
        .onTapGesture {
          showFullScreen = true
        }
        .help("Click to open full screen and zoom")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(analysis.displayTitle). Click to open full screen and zoom.")
      }
    }
    .background(MacDesignTokens.Colors.surface)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          parseError != nil ? Color.red.opacity(0.45) : MacDesignTokens.Colors.separator,
          lineWidth: 0.85
        )
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { newWidth in
      if newWidth > 1, abs(newWidth - cardWidth) > 1 {
        cardWidth = newWidth
      }
    }
    .onChange(of: source) { _, _ in
      parseError = nil
      diagramBounds = .zero
      showSource = false
      isSourceExpanded = false
    }
    .onChange(of: isComplete) { _, complete in
      if complete {
        parseError = nil
        diagramBounds = .zero
      }
    }
    .sheet(isPresented: $showFullScreen) {
      MacFullScreenMermaidView(source: source, analysis: analysis)
    }
  }

  private func header(
    analysis: MacMermaidDiagramSupport.Analysis,
    canRenderDiagram: Bool
  ) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .accessibilityHidden(true)

      Text(analysis.headerLabel)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .lineLimit(1)

      if !isComplete {
        Text("STREAMING")
          .font(.system(size: 9, weight: .semibold, design: .monospaced))
          .foregroundStyle(.tertiary)
      }

      Spacer(minLength: 8)

      if canRenderDiagram {
        Button(
          showSource ? "Show Diagram" : "Show Source",
          systemImage: showSource ? "eye" : "chevron.left.forwardslash.chevron.right"
        ) {
          withAnimation(.easeOut(duration: 0.18)) {
            showSource.toggle()
          }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(MacIconButtonStyle())
        .help(showSource ? "Show diagram" : "Show Mermaid source")
      }

      Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") {
        showFullScreen = true
      }
      .labelStyle(.iconOnly)
      .buttonStyle(MacIconButtonStyle())
      .help("Open full screen")
      .disabled(!canRenderDiagram)

      Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
        copySource()
      }
      .labelStyle(.iconOnly)
      .buttonStyle(MacIconButtonStyle())
      .help(copied ? "Copied" : "Copy Mermaid source")
    }
    .foregroundStyle(MacDesignTokens.Colors.textMuted)
    .padding(.horizontal, 11)
    .frame(minHeight: 38)
    .background(MacDesignTokens.Colors.codeSurface.opacity(0.65))
  }

  private var streamingBody: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Rendering diagram…")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }
      if !source.isEmpty {
        ScrollView([.horizontal, .vertical]) {
          Text(source)
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
  }

  private func unsupportedBody(kindName: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "info.circle.fill")
          .font(.subheadline)
          .foregroundStyle(MacDesignTokens.Colors.accent)
        VStack(alignment: .leading, spacing: 2) {
          Text("\(kindName) aren’t supported for preview yet")
            .font(.subheadline.weight(.semibold))
          Text("You can still copy or inspect the Mermaid source below.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)

      Divider()

      collapsibleSourceBody(content: source)
    }
  }

  private func errorBody(error: Error) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(Color.red)
          Text("Could not render this diagram")
            .font(.subheadline.weight(.semibold))
        }
        Text(error.localizedDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)

      Divider()

      collapsibleSourceBody(content: source)
    }
  }

  @ViewBuilder
  private func collapsibleSourceBody(content: String) -> some View {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    let exceedsLines = lines.count > collapsedLineLimit
    let exceedsCharacters = content.count > collapsedCharacterLimit
    let isLong = exceedsLines || exceedsCharacters

    let displayedContent: String = {
      guard isLong, !isSourceExpanded else { return content }
      let lineCapped = exceedsLines ? lines.prefix(collapsedLineLimit).joined(separator: "\n") : content
      let capped = lineCapped.count > collapsedCharacterLimit
        ? String(lineCapped.prefix(collapsedCharacterLimit))
        : lineCapped
      return capped + "\n…"
    }()

    let toggleLabel: String = {
      if isSourceExpanded { return "Collapse source" }
      if exceedsLines { return "Show all \(lines.count) lines" }
      return "Show full source"
    }()

    VStack(spacing: 0) {
      ScrollView(.horizontal) {
        Text(displayedContent)
          .font(.system(size: 13, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: true)
          .padding(13)
      }
      .scrollIndicators(.visible)

      if isLong {
        Divider()
        Button {
          withAnimation(.easeOut(duration: 0.18)) {
            isSourceExpanded.toggle()
          }
        } label: {
          Label(
            toggleLabel,
            systemImage: isSourceExpanded ? "chevron.up" : "chevron.down"
          )
          .font(.caption.weight(.medium))
          .frame(maxWidth: .infinity)
          .frame(height: 34)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func copySource() {
    NSPasteboard.general.clearContents()
    if NSPasteboard.general.setString(source, forType: .string) {
      MacAppAnalytics.track(.contentCopied, dimension: .diagram)
    }
    copied = true
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.2))
      copied = false
    }
  }
}

private struct MacFullScreenMermaidView: View {
  private enum ViewMode {
    case diagram
    case source
  }

  private struct RenderKey: Equatable {
    let source: String
    let themeID: String
    let isDark: Bool
    let scale: Int
  }

  let source: String
  let analysis: MacMermaidDiagramSupport.Analysis

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale

  @State private var viewMode: ViewMode = .diagram
  @State private var renderedImage: NSImage?
  @State private var renderError: Error?
  @State private var isRendering = false
  @State private var zoomScale: CGFloat = 1.0
  @State private var statusBanner: String?
  @State private var statusBannerRevision = 0
  @State private var saveErrorMessage: String?

  private var title: String {
    if let title = analysis.title, !title.isEmpty {
      return title
    }
    return analysis.displayTitle
  }

  private var activeThemeID: String {
    MacThemeFoundation.store
      .currentTheme(hasPro: MacPurchaseStore.manager.hasPro)
      .id
      .rawValue
  }

  private var renderKey: RenderKey {
    RenderKey(
      source: analysis.renderSource,
      themeID: activeThemeID,
      isDark: colorScheme == .dark,
      scale: Int(max(displayScale, 3.0).rounded())
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbarBar

      Divider()

      ZStack(alignment: .bottom) {
        Group {
          if viewMode == .source {
            sourceView
          } else if let renderedImage {
            MacZoomableImageCanvas(image: renderedImage, zoomScale: $zoomScale)
          } else if let renderError {
            ContentUnavailableView {
              Label("Diagram Error", systemImage: "exclamationmark.triangle")
            } description: {
              Text(renderError.localizedDescription)
            } actions: {
              Button("View Mermaid Source") {
                viewMode = .source
              }
              .buttonStyle(.borderedProminent)
            }
            .padding()
          } else if isRendering {
            VStack(spacing: 10) {
              ProgressView()
              Text("Preparing diagram…")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            MermaidDiagramView(
              source: analysis.renderSource,
              theme: MacMermaidDiagramSupport.diagramTheme(
                colorScheme: colorScheme,
                canvas: .fullScreen
              )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
          }
        }
        .background(MacDesignTokens.Colors.canvas)

        if let statusBanner {
          Label(statusBanner, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(MacDesignTokens.Colors.surface, in: Capsule())
            .overlay {
              Capsule()
                .stroke(MacDesignTokens.Colors.separator, lineWidth: 0.75)
            }
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.easeInOut(duration: 0.18), value: statusBanner)
    }
    .frame(minWidth: 780, minHeight: 560)
    .task(id: renderKey) {
      await renderDiagram()
    }
    .task(id: statusBannerRevision) {
      guard statusBannerRevision > 0 else { return }
      try? await Task.sleep(for: .seconds(1.8))
      guard !Task.isCancelled else { return }
      statusBanner = nil
    }
    .alert(
      "Could Not Save Image",
      isPresented: Binding(
        get: { saveErrorMessage != nil },
        set: { if !$0 { saveErrorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { saveErrorMessage = nil }
    } message: {
      Text(saveErrorMessage ?? "Unknown error")
    }
  }

  private var toolbarBar: some View {
    HStack(spacing: 8) {
      Label(title, systemImage: "point.3.connected.trianglepath.dotted")
        .font(.headline)
        .lineLimit(1)

      Spacer()

      if viewMode == .diagram, renderedImage != nil {
        HStack(spacing: 4) {
          Button("Zoom Out", systemImage: "minus.magnifyingglass") {
            withAnimation(.easeOut(duration: 0.15)) {
              zoomScale = max(0.5, (zoomScale - 0.25).roundedToQuarter)
            }
          }
          .labelStyle(.iconOnly)
          .buttonStyle(MacIconButtonStyle())
          .help("Zoom out")
          .keyboardShortcut("-", modifiers: .command)

          Button {
            withAnimation(.easeOut(duration: 0.18)) {
              zoomScale = 1.0
            }
          } label: {
            Text("\(Int((zoomScale * 100).rounded()))%")
              .font(.system(size: 11, weight: .semibold, design: .monospaced))
              .frame(minWidth: 44)
          }
          .buttonStyle(MacSecondaryButtonStyle())
          .help("Reset zoom")
          .keyboardShortcut("0", modifiers: .command)

          Button("Zoom In", systemImage: "plus.magnifyingglass") {
            withAnimation(.easeOut(duration: 0.15)) {
              zoomScale = min(6.0, (zoomScale + 0.25).roundedToQuarter)
            }
          }
          .labelStyle(.iconOnly)
          .buttonStyle(MacIconButtonStyle())
          .help("Zoom in")
          .keyboardShortcut("+", modifiers: .command)
        }

        Divider()
          .frame(height: 16)
      }

      Button(
        viewMode == .diagram ? "View Source" : "View Diagram",
        systemImage: viewMode == .diagram ? "chevron.left.forwardslash.chevron.right" : "eye"
      ) {
        withAnimation(.easeOut(duration: 0.18)) {
          viewMode = viewMode == .diagram ? .source : .diagram
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(MacIconButtonStyle())
      .help(viewMode == .diagram ? "View Mermaid source" : "View rendered diagram")

      if viewMode == .diagram, let renderedImage {
        Button("Save Image…", systemImage: "square.and.arrow.down") {
          savePNG(renderedImage)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(MacIconButtonStyle())
        .help("Save image…")
      }

      Menu {
        if let renderedImage {
          ShareLink(
            item: Image(nsImage: renderedImage),
            preview: SharePreview(title, image: Image(nsImage: renderedImage))
          ) {
            Label("Share Image", systemImage: "photo")
          }
        }
        ShareLink(item: source) {
          Label("Share Mermaid Source", systemImage: "doc.plaintext")
        }
        Button("Copy Mermaid Source", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          if NSPasteboard.general.setString(source, forType: .string) {
            MacAppAnalytics.track(.contentCopied, dimension: .diagram)
          }
          showStatusBanner("Copied Mermaid Source")
        }
      } label: {
        Image(systemName: "square.and.arrow.up")
          .font(.system(size: 12.5, weight: .semibold))
          .frame(
            width: MacDesignTokens.Control.iconButtonSize,
            height: MacDesignTokens.Control.iconButtonSize
          )
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Share or copy diagram")
      .accessibilityLabel("Share or Copy Diagram")

      Button("Done") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(14)
  }

  private var sourceView: some View {
    ScrollView([.horizontal, .vertical]) {
      Text(source)
        .font(.system(size: 13.5, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize(horizontal: true, vertical: true)
        .padding(20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func renderDiagram() async {
    renderError = nil
    isRendering = true
    let diagramTheme = MacMermaidDiagramSupport.diagramTheme(
      colorScheme: colorScheme,
      canvas: .fullScreen
    )
    let desiredScale = max(displayScale, 3.0)
    do {
      let image = try await MacMermaidDiagramSupport.renderImage(
        source: analysis.renderSource,
        theme: diagramTheme,
        desiredScale: desiredScale
      )
      guard !Task.isCancelled else { return }
      renderedImage = image
      isRendering = false
    } catch {
      guard !Task.isCancelled else { return }
      renderedImage = nil
      renderError = error
      isRendering = false
    }
  }

  private func savePNG(_ image: NSImage) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = MacMermaidDiagramSupport.suggestedFilename(for: title)
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      guard let data = MacMermaidDiagramSupport.pngData(from: image) else {
        throw CocoaError(.fileWriteUnknown)
      }
      try data.write(to: destination, options: .atomic)
      showStatusBanner("Saved PNG Image")
    } catch {
      saveErrorMessage = error.localizedDescription
    }
  }

  private func showStatusBanner(_ message: String) {
    statusBanner = message
    statusBannerRevision += 1
  }
}
