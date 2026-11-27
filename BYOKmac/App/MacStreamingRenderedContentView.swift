import AppKit
import SwiftUI

struct MacStreamingRenderedContentView: View {
  let snapshot: MacStreamingAnswerSnapshot
  var textSize: CGFloat = 15
  var muted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(snapshot.stableBlocks) { rendered in
        MacStableRenderedAnswerBlockView(rendered: rendered, textSize: textSize, muted: muted)
          .equatable()
      }

      ForEach(Array(snapshot.tailBlocks.enumerated()), id: \.offset) { _, block in
        MacStreamingTailBlockView(block: block, textSize: textSize, muted: muted)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MacStableRenderedAnswerBlockView: View, Equatable {
  let rendered: MacRenderedAnswerBlock
  let textSize: CGFloat
  let muted: Bool

  @ViewBuilder
  var body: some View {
    switch rendered.block {
    case .markdown(let source):
      // MarkdownUI and inline LaTeX are allowed only after this top-level
      // block has crossed the stable boundary. Its input never changes again.
      MacMarkdownMessageContent(text: source, textSize: textSize, muted: muted)

    case .code(let language, let content, let isComplete):
      if MacAnswerContentParser.isMermaidLanguage(language) {
        MacMermaidAnswerView(source: content, isComplete: isComplete)
      } else if isComplete {
        // Stable code is highlighted once. MacHighlightedCodeText shows plain
        // monospaced source until the asynchronous highlight is ready.
        MacHighlightedCodeBlock(language: language, content: content, textSize: textSize)
      } else {
        MacStreamingCodeSourceView(language: language, content: content, textSize: textSize)
      }

    case .math(let expression, let isComplete):
      if isComplete {
        MacMathAnswerView(expression: expression)
      } else {
        MacStreamingMathSourceView(expression: expression)
      }

    case .table(let table):
      MacMarkdownTableView(table: table, textSize: textSize, isComplete: true)

    case .callout(let kind, let body):
      MacCalloutAnswerView(kind: kind, bodyText: body, textSize: textSize, muted: muted)

    case .details(let summary, let body, let isComplete):
      MacDetailsAnswerView(
        summary: summary,
        bodyText: body,
        isComplete: isComplete,
        textSize: textSize,
        muted: muted
      )

    case .footnotes(let footnotes):
      MacFootnotesAnswerView(footnotes: footnotes, textSize: textSize, muted: muted)
    }
  }
}

/// The mutable suffix avoids heavy full-document MarkdownUI / LaTeX / syntax
/// highlighters on every token, while applying lightweight progressive inline
/// Markdown formatting (`**bold**`, `*italic*`, `` `code` ``, `[links](url)`,
/// headings, lists, and blockquotes) so completed paragraphs don't visibly pop.
private struct MacStreamingTailBlockView: View {
  let block: MacAnswerContentBlock
  let textSize: CGFloat
  let muted: Bool

  @Environment(\.macAppTheme) private var theme

  @ViewBuilder
  var body: some View {
    switch block {
    case .markdown(let source):
      let chunks = streamingMarkdownChunks(for: source)
      if chunks.count == 1, case .text(let only) = chunks[0] {
        streamingMarkdownTextView(only)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
            switch chunk {
            case .text(let text):
              streamingMarkdownTextView(text)
            case .thematicBreak:
              Rectangle()
                .fill(theme.separator.opacity(0.70))
                .frame(height: 1)
                .padding(.vertical, textSize * 0.45)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

    case .code(let language, let content, _):
      if MacAnswerContentParser.isMermaidLanguage(language) {
        MacMermaidAnswerView(source: content, isComplete: false)
      } else {
        MacStreamingCodeSourceView(language: language, content: content, textSize: textSize)
      }

    case .math(let expression, _):
      MacStreamingMathSourceView(expression: expression)

    case .table(let table):
      MacStreamingTableSourceView(rawMarkdown: table.rawMarkdown)

    case .callout(let kind, let body):
      MacCalloutAnswerView(kind: kind, bodyText: body, textSize: textSize, muted: muted)

    case .details(let summary, let body, let isComplete):
      MacDetailsAnswerView(
        summary: summary,
        bodyText: body,
        isComplete: isComplete,
        textSize: textSize,
        muted: muted
      )

    case .footnotes(let footnotes):
      MacFootnotesAnswerView(footnotes: footnotes, textSize: textSize, muted: muted)
    }
  }

  private enum StreamingMarkdownChunk {
    case text(String)
    case thematicBreak
  }

  private func streamingMarkdownChunks(for source: String) -> [StreamingMarkdownChunk] {
    guard source.contains("---") || source.contains("***") || source.contains("___") else {
      return [.text(source)]
    }

    var chunks: [StreamingMarkdownChunk] = []
    var currentLines: [String] = []

    func flushText() {
      guard !currentLines.isEmpty else { return }
      chunks.append(.text(currentLines.joined(separator: "\n")))
      currentLines.removeAll(keepingCapacity: true)
    }

    for line in source.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if MacSelectableMarkdownBuilder.isThematicBreak(trimmed) {
        flushText()
        chunks.append(.thematicBreak)
      } else {
        currentLines.append(line)
      }
    }
    flushText()

    return chunks.isEmpty ? [.text(source)] : chunks
  }

  private func streamingMarkdownTextView(_ text: String) -> some View {
    let formatted = MacStreamingTailFormatter.formattedAttributedString(
      text,
      textSize: textSize,
      foregroundColor: muted ? theme.textMuted : theme.textPrimary,
      mutedColor: theme.textMuted,
      accentColor: theme.accent,
      codeBackground: theme.codeSurface.opacity(0.85),
      muted: muted
    )
    return Text(formatted)
      .lineSpacing(textSize * 0.32)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
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
  }
}

private struct MacStreamingCodeSourceView: View {
  let language: String?
  let content: String
  var textSize: CGFloat = 15

  var body: some View {
    MacHighlightedCodeBlock(
      language: language,
      content: content,
      isStreaming: true,
      textSize: textSize
    )
  }
}

private struct MacStreamingTableSourceView: View {
  let rawMarkdown: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "tablecells")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
        Text("TABLE · STREAMING")
          .font(.system(size: 9, weight: .semibold, design: .monospaced))
          .foregroundStyle(.tertiary)
      }
      Text(rawMarkdown)
        .font(.system(size: 12.5, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    }
  }
}

private struct MacStreamingMathSourceView: View {
  let expression: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("MATH")
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(.tertiary)
      Text(expression)
        .font(.system(size: 13, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    }
  }
}
