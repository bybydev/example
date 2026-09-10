import AppKit
import BeautifulMermaid
import Foundation
import Highlighter
import LaTeXSwiftUI
import MarkdownUI
import os
import SwiftUI

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
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
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
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
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
  private func blockView(_ block: MacAnswerContentBlock) -> some View {
    switch block {
    case .markdown(let source):
      let markdown = isStreaming ? stabilizedStreamingMarkdown(source) : source
      if preparedAnswer?.inlineMathSources.contains(markdown)
        ?? MacPreparedAnswer.shouldUseInlineMathRenderer(markdown)
      {
        LaTeX(markdown)
          .parsingMode(.onlyEquations)
          .blockMode(.blockViews)
          .processEscapes()
          .renderingStyle(.redactedOriginal)
          .errorMode(.rendered)
          .imageRenderingMode(.template)
          .imageAccessibility(.sre)
          .font(.system(size: textSize))
          .foregroundStyle(.primary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Markdown(preparedAnswer?.markdown[markdown] ?? MarkdownContent(markdown))
          .markdownTheme(Self.chatTheme(textSize: textSize))
          .textSelection(.enabled)
          .tint(.accentColor)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

    case .code(let language, let content, let isComplete):
      if MacAnswerContentParser.isMermaidLanguage(language), isComplete {
        MacMermaidAnswerView(source: content)
      } else {
        MacHighlightedCodeBlock(language: language, content: content, isStreaming: isStreaming && !isComplete)
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

  private static func chatTheme(textSize: CGFloat) -> MarkdownUI.Theme {
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
        configuration.label
          .markdownTextStyle {
            FontSize(.em(0.9))
            if configuration.row == 0 { FontWeight(.semibold) }
            BackgroundColor(nil)
          }
          .fixedSize(horizontal: false, vertical: true)
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

struct MacHighlightedCodeBlock: View {
  let language: String?
  let content: String
  var isStreaming = false

  @Environment(\.colorScheme) private var colorScheme
  @State private var isExpanded = false
  @State private var showFullScreen = false
  @State private var copied = false

  private let collapsedLineLimit = 18

  private var lines: [Substring] {
    content.split(separator: "\n", omittingEmptySubsequences: false)
  }

  private var isLong: Bool {
    lines.count > collapsedLineLimit || content.count > 2_400
  }

  private var displayedContent: String {
    guard isLong, !isExpanded, !isStreaming else { return content }
    return lines.prefix(collapsedLineLimit).joined(separator: "\n") + "\n…"
  }

  private var languageLabel: String {
    let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? "CODE" : value.uppercased()
  }

  var body: some View {
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
          Text(displayedContent)
            .font(.system(size: 13, design: .monospaced))
            .fixedSize(horizontal: true, vertical: true)
            .textSelection(.enabled)
            .padding(13)
        } else {
          MacHighlightedCodeText(
            code: displayedContent,
            language: language,
            colorScheme: colorScheme
          )
          .padding(13)
        }
      }
      .scrollIndicators(.visible)

      if isLong && !isStreaming {
        Divider()
        Button {
          isExpanded.toggle()
        } label: {
          Label(
            isExpanded ? "Collapse code" : "Show all \(lines.count) lines",
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
    NSPasteboard.general.setString(content, forType: .string)
    copied = true
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.2))
      copied = false
    }
  }
}

private struct MacHighlightedCodeText: View {
  let code: String
  let language: String?
  let colorScheme: ColorScheme

  @State private var highlighted: AttributedString?

  var body: some View {
    Group {
      if let highlighted {
        Text(highlighted)
      } else {
        Text(code)
          .font(.system(size: 13, design: .monospaced))
      }
    }
    .fixedSize(horizontal: true, vertical: true)
    .textSelection(.enabled)
    .task(id: renderID) {
      highlighted = await MacSyntaxHighlighting.shared.render(
        code: code,
        language: language,
        isDark: colorScheme == .dark
      )
    }
  }

  private var renderID: String {
    "\(colorScheme == .dark ? "dark" : "light")::\(language ?? "auto")::\(code.hashValue)"
  }
}

private actor MacSyntaxHighlighting {
  private struct CacheKey: Hashable, Sendable {
    let code: String
    let language: String?
    let isDark: Bool
  }

  static let shared = MacSyntaxHighlighting()

  private var cache: [CacheKey: AttributedString] = [:]
  private var order: [CacheKey] = []
  private let limit = 72

  func render(code: String, language: String?, isDark: Bool) -> AttributedString? {
    let key = CacheKey(code: code, language: language, isDark: isDark)
    if let cached = cache[key] { return cached }

    guard let highlighter = Highlighter() else { return nil }
    _ = highlighter.setTheme(
      isDark ? "github-dark" : "github",
      withFont: "Menlo-Regular",
      ofSize: 13
    )
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
        .help("Share code")
        Button("Copy", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(content, forType: .string)
        }
        .labelStyle(.iconOnly)
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .buttonStyle(.plain)
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

struct MacMathAnswerView: View {
  let expression: String

  var body: some View {
    LaTeX("$$\(expression)$$")
      .blockMode(.blockViews)
      .renderingStyle(.redactedOriginal)
      .errorMode(.rendered)
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

struct MacMermaidAnswerView: View {
  let source: String

  @Environment(\.colorScheme) private var colorScheme
  @State private var parseError: Error?
  @State private var diagramBounds = CGRect.zero
  @State private var showFullScreen = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Label("DIAGRAM", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") {
          showFullScreen = true
        }
        .labelStyle(.iconOnly)
        Button("Copy", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(source, forType: .string)
        }
        .labelStyle(.iconOnly)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 11)
      .frame(minHeight: 38)
      .background(Color.primary.opacity(0.045))

      Divider()

      if let parseError {
        VStack(alignment: .leading, spacing: 8) {
          Label("Could not render this diagram", systemImage: "exclamationmark.triangle")
            .font(.callout.weight(.semibold))
          Text(parseError.localizedDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
          MacHighlightedCodeBlock(language: "mermaid", content: source)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
      } else {
        GeometryReader { proxy in
          MermaidDiagramView(
            source: source,
            theme: diagramTheme,
            parseError: $parseError,
            diagramBounds: $diagramBounds
          )
          .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: diagramHeight)
        .padding(8)
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
    }
    .sheet(isPresented: $showFullScreen) {
      MacFullScreenMermaidView(source: source)
    }
  }

  private var diagramTheme: DiagramTheme {
    colorScheme == .dark ? .githubDark : .githubLight
  }

  private var diagramHeight: CGFloat {
    min(max(diagramBounds.height + 24, 180), 480)
  }
}

private struct MacFullScreenMermaidView: View {
  let source: String

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var parseError: Error?
  @State private var diagramBounds = CGRect.zero

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Diagram")
          .font(.headline)
        Spacer()
        ShareLink(item: source) {
          Image(systemName: "square.and.arrow.up")
        }
        Button("Copy", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(source, forType: .string)
        }
        .labelStyle(.iconOnly)
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .buttonStyle(.plain)
      .padding(14)
      Divider()
      ZStack {
        MermaidDiagramView(
          source: source,
          theme: colorScheme == .dark ? .githubDark : .githubLight,
          parseError: $parseError,
          diagramBounds: $diagramBounds
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if let parseError {
          ContentUnavailableView(
            "Diagram Error",
            systemImage: "exclamationmark.triangle",
            description: Text(parseError.localizedDescription)
          )
        }
      }
      .padding(16)
    }
    .frame(minWidth: 760, minHeight: 560)
  }
}
