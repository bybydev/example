import AppFoundation
import LaTeXSwiftUI
import MarkdownUI
import SwiftUI

struct MarkdownMessageContent: View {
  let text: String
  var showsSources = true
  /// Stretch every block to the offered width. Off inside right-hugging user
  /// bubbles so the capsule shrinks to its content instead of filling the row.
  var fillsWidth = true

  @Environment(\.appFoundationTheme) private var theme
  @State private var browserDestination: BrowserDestination?

  var body: some View {
    let blocks = AnswerContentParser.parse(text)
    let sources = showsSources ? AnswerContentParser.sources(in: blocks) : []

    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }

      if !sources.isEmpty {
        AnswerSourcesView(sources: sources) { url in
          browserDestination = BrowserDestination(url: url)
        }
      }
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    .environment(
      \.openURL,
      OpenURLAction { url in
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
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
  private func blockView(_ block: AnswerContentBlock) -> some View {
    switch block {
    case .markdown(let markdown):
      if shouldUseInlineMathRenderer(markdown) {
        LaTeX(markdown)
          .parsingMode(.onlyEquations)
          .blockMode(.blockViews)
          .processEscapes()
          .renderingStyle(.redactedOriginal)
          .renderingAnimation(.easeOut(duration: 0.18))
          .errorMode(.original)
          .imageRenderingMode(.template)
          .imageAccessibility(.sre)
          .font(.system(size: 17))
          .foregroundStyle(theme.primaryForegroundColor)
          .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
      } else {
        Markdown(markdown)
          .markdownTheme(
            chatTheme(
              columnAlignments: tableColumnAlignments(in: markdown) ?? []
            )
          )
          .textSelection(.enabled)
          .tint(theme.accentColor)
          .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
      }

    case .code(let language, let content):
      if AnswerContentParser.isMermaidLanguage(language) {
        MermaidAnswerView(source: content)
      } else {
        HighlightedCodeBlock(language: language, content: content)
      }

    case .math(let expression):
      MathAnswerView(expression: expression)
    }
  }

  private func shouldUseInlineMathRenderer(_ markdown: String) -> Bool {
    guard AnswerContentParser.containsInlineMath(markdown) else { return false }

    for line in markdown.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#")
        || trimmed.hasPrefix(">")
        || trimmed.hasPrefix("- ")
        || trimmed.hasPrefix("* ")
        || trimmed.hasPrefix("+ ")
        || trimmed.hasPrefix("|")
        || trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
      {
        return false
      }
    }
    return true
  }

  /// Recovers GFM column alignments from a table's delimiter row
  /// (`| --- | :---: | ---: |`), mirroring the mapping TableView applies at the
  /// Grid level. MarkdownUI never exposes alignment to the theme closure, so
  /// with fixed-width cells — where the grid anchor has no slack to act on —
  /// it must be recovered from the source text here. Returns the first
  /// delimiter row outside code fences; tables after the first in the same
  /// markdown chunk share its alignments.
  private func tableColumnAlignments(in markdown: String) -> [TextAlignment]? {
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

  private func isTableDelimiterRow(_ line: String) -> Bool {
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
        FontSize(17)
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
