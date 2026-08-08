import AppFoundation
import LaTeXSwiftUI
import MarkdownUI
import SwiftUI

struct MarkdownMessageContent: View {
  let text: String
  var showsSources = true

  @Environment(\.appFoundationTheme) private var theme
  @State private var browserDestination: BrowserDestination?

  private var blocks: [AnswerContentBlock] {
    AnswerContentParser.parse(text)
  }

  private var sources: [AnswerSource] {
    showsSources ? AnswerContentParser.sources(in: blocks) : []
  }

  var body: some View {
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
    .frame(maxWidth: .infinity, alignment: .leading)
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
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Markdown(markdown)
          .markdownTheme(chatTheme)
          .textSelection(.enabled)
          .tint(theme.accentColor)
          .frame(maxWidth: .infinity, alignment: .leading)
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

  private var chatTheme: MarkdownUI.Theme {
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
          // Keep the table at its natural total width. Individual columns are capped below,
          // so a wide multi-column table can still exceed the viewport and scroll horizontally.
          configuration.label
            .fixedSize(horizontal: true, vertical: true)
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
          // Let text wrap inside a bounded column and grow the row vertically. The enclosing
          // table still owns horizontal overflow when the sum of the capped columns is wider
          // than the screen.
          .fixedSize(horizontal: false, vertical: true)
          .frame(minWidth: 88, maxWidth: 240, alignment: .topLeading)
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
