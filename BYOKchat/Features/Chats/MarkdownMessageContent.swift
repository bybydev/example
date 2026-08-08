import AppFoundation
import Foundation
import LaTeXSwiftUI
import MarkdownUI
import SwiftUI

struct MarkdownMessageContent: View {
  let text: String
  var showsSources = true

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var browserDestination: BrowserDestination?
  @State private var displayedText: String
  @State private var isPresentingStream = false
  @State private var lastRevealDate = Date.distantPast

  private static let revealInterval: Duration = .milliseconds(50)
  private static let settleDelay: Duration = .milliseconds(300)

  init(text: String, showsSources: Bool = true) {
    self.text = text
    self.showsSources = showsSources
    _displayedText = State(initialValue: text)
  }

  private var blocks: [AnswerContentBlock] {
    AnswerContentParser.parse(displayedText)
  }

  private var sources: [AnswerSource] {
    showsSources ? AnswerContentParser.sources(in: blocks) : []
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
        blockView(
          block,
          isLiveTail: isPresentingStream && index == blocks.count - 1
        )
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
    .task(id: text) {
      await presentTargetText(text)
    }
  }

  @ViewBuilder
  private func blockView(_ block: AnswerContentBlock, isLiveTail: Bool) -> some View {
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
      } else if isLiveTail, canUseAnimatedStreamingTail(markdown) {
        streamingMarkdownBlock(markdown)
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

  @ViewBuilder
  private func streamingMarkdownBlock(_ markdown: String) -> some View {
    let parts = liveParagraphParts(markdown)

    VStack(alignment: .leading, spacing: 0) {
      if !parts.settled.isEmpty {
        Markdown(parts.settled)
          .markdownTheme(chatTheme)
          .textSelection(.enabled)
          .tint(theme.accentColor)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if !parts.live.isEmpty {
        StreamingTailText(
          text: parts.live,
          revealDate: lastRevealDate,
          foregroundColor: theme.primaryForegroundColor,
          reduceMotion: reduceMotion
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func presentTargetText(_ target: String) async {
    guard target != displayedText else { return }

    guard target.hasPrefix(displayedText) else {
      displayedText = target
      isPresentingStream = false
      return
    }

    isPresentingStream = true

    while displayedText != target, !Task.isCancelled {
      let displayedCount = displayedText.count
      let start = target.index(target.startIndex, offsetBy: displayedCount)
      let backlog = target.distance(from: start, to: target.endIndex)
      let amount = revealAmount(for: backlog)
      let end = target.index(start, offsetBy: amount, limitedBy: target.endIndex) ?? target.endIndex

      displayedText.append(contentsOf: target[start..<end])
      lastRevealDate = .now

      guard displayedText != target else { break }
      do {
        try await Task.sleep(for: Self.revealInterval)
      } catch {
        return
      }
    }

    guard !Task.isCancelled, displayedText == target else { return }

    do {
      try await Task.sleep(for: Self.settleDelay)
    } catch {
      return
    }

    guard !Task.isCancelled, displayedText == target else { return }
    isPresentingStream = false
  }

  private func revealAmount(for backlog: Int) -> Int {
    switch backlog {
    case ...10:
      return max(backlog, 1)
    case ...40:
      return 4
    case ...100:
      return 7
    case ...240:
      return 12
    case ...600:
      return 20
    case ...1_200:
      return 30
    default:
      return 42
    }
  }

  private func liveParagraphParts(_ markdown: String) -> (settled: String, live: String) {
    guard let range = markdown.range(of: "\n\n", options: .backwards) else {
      return ("", markdown)
    }

    return (
      String(markdown[..<range.lowerBound]),
      String(markdown[range.upperBound...])
    )
  }

  private func canUseAnimatedStreamingTail(_ markdown: String) -> Bool {
    guard !AnswerContentParser.containsInlineMath(markdown) else { return false }

    let live = liveParagraphParts(markdown).live
    for line in live.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#")
        || trimmed.hasPrefix(">")
        || trimmed.hasPrefix("- ")
        || trimmed.hasPrefix("* ")
        || trimmed.hasPrefix("+ ")
        || trimmed.hasPrefix("|")
        || trimmed.hasPrefix("```")
        || trimmed.hasPrefix("~~~")
        || trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
      {
        return false
      }
    }
    return true
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

private struct StreamingTailText: View {
  let text: String
  let revealDate: Date
  let foregroundColor: Color
  let reduceMotion: Bool

  private var attributedText: AttributedString {
    (try? AttributedString(markdown: text)) ?? AttributedString(text)
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
      let age = max(0, timeline.date.timeIntervalSince(revealDate))
      let revealProgress = reduceMotion ? 1 : min(1, age / 0.16)
      let phase = reduceMotion
        ? 0
        : timeline.date.timeIntervalSinceReferenceDate
          .truncatingRemainder(dividingBy: 1.15) / 1.15

      Text(attributedText)
        .font(.system(size: 17))
        .lineSpacing(4)
        .foregroundStyle(foregroundColor)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textRenderer(
          StreamingTailTextRenderer(
            shimmerPhase: phase,
            revealProgress: revealProgress,
            reduceMotion: reduceMotion
          )
        )
    }
  }
}

private struct StreamingTailTextRenderer: TextRenderer {
  var shimmerPhase: Double
  var revealProgress: Double
  var reduceMotion: Bool

  var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(shimmerPhase, revealProgress) }
    set {
      shimmerPhase = newValue.first
      revealProgress = newValue.second
    }
  }

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    let totalSlices = layout.reduce(0) { lineTotal, line in
      lineTotal + line.reduce(0) { runTotal, run in
        runTotal + run.count
      }
    }
    let liveSliceCount = min(28, totalSlices)
    let liveStart = max(0, totalSlices - liveSliceCount)
    var sliceIndex = 0

    for line in layout {
      for run in line {
        for slice in run {
          if reduceMotion || sliceIndex < liveStart {
            context.draw(slice, options: .disablesSubpixelQuantization)
          } else {
            var copy = context
            let localIndex = sliceIndex - liveStart
            let localProgress = Double(localIndex) / Double(max(liveSliceCount - 1, 1))
            let shimmerCenter = shimmerPhase * 1.45 - 0.2
            let shimmerDistance = abs(localProgress - shimmerCenter)
            let shimmer = max(0, 1 - shimmerDistance / 0.24)
            let baseOpacity = 0.62 + 0.38 * revealProgress

            copy.opacity = min(1, baseOpacity + 0.16 * shimmer)
            let blurRadius = max(0, (1 - revealProgress) * 0.65 - shimmer * 0.15)
            if blurRadius > 0.02 {
              copy.addFilter(.blur(radius: CGFloat(blurRadius)))
            }
            copy.draw(slice, options: .disablesSubpixelQuantization)
          }
          sliceIndex += 1
        }
      }
    }
  }
}