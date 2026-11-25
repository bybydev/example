import SwiftUI

struct MacStreamingRenderedContentView: View {
  let snapshot: MacStreamingAnswerSnapshot
  var textSize: CGFloat = 15

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(snapshot.stableBlocks) { rendered in
        MacStableRenderedAnswerBlockView(rendered: rendered, textSize: textSize)
          .equatable()
      }

      ForEach(Array(snapshot.tailBlocks.enumerated()), id: \.offset) { _, block in
        MacStreamingTailBlockView(block: block, textSize: textSize)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MacStableRenderedAnswerBlockView: View, Equatable {
  let rendered: MacRenderedAnswerBlock
  let textSize: CGFloat

  @ViewBuilder
  var body: some View {
    switch rendered.block {
    case .markdown(let source):
      // MarkdownUI and inline LaTeX are allowed only after this top-level
      // block has crossed the stable boundary. Its input never changes again.
      MacMarkdownMessageContent(text: source, textSize: textSize)

    case .code(let language, let content, let isComplete):
      if MacAnswerContentParser.isMermaidLanguage(language) {
        MacMermaidAnswerView(source: content, isComplete: isComplete)
      } else if isComplete {
        // Stable code is highlighted once. MacHighlightedCodeText shows plain
        // monospaced source until the asynchronous highlight is ready.
        MacHighlightedCodeBlock(language: language, content: content)
      } else {
        MacStreamingCodeSourceView(language: language, content: content)
      }

    case .math(let expression, let isComplete):
      if isComplete {
        MacMathAnswerView(expression: expression)
      } else {
        MacStreamingMathSourceView(expression: expression)
      }

    case .table(let table):
      MacMarkdownTableView(table: table, textSize: textSize, isComplete: true)
    }
  }
}

/// The mutable suffix deliberately avoids every rich renderer. This keeps
/// Markdown parsing, syntax highlighting, Mermaid layout, and LaTeX conversion
/// out of the per-token path. A tail may change representation once when it
/// becomes stable; until then readable source is preferred over rich output.
private struct MacStreamingTailBlockView: View {
  let block: MacAnswerContentBlock
  let textSize: CGFloat

  @ViewBuilder
  var body: some View {
    switch block {
    case .markdown(let source):
      Text(stabilizedTailText(source))
        .font(.system(size: textSize))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

    case .code(let language, let content, _):
      if MacAnswerContentParser.isMermaidLanguage(language) {
        MacMermaidAnswerView(source: content, isComplete: false)
      } else {
        MacStreamingCodeSourceView(language: language, content: content)
      }

    case .math(let expression, _):
      MacStreamingMathSourceView(expression: expression)

    case .table(let table):
      MacStreamingTableSourceView(rawMarkdown: table.rawMarkdown)
    }
  }

  private func stabilizedTailText(_ source: String) -> String {
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
}

private struct MacStreamingCodeSourceView: View {
  let language: String?
  let content: String

  var body: some View {
    MacHighlightedCodeBlock(
      language: language,
      content: content,
      isStreaming: true
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
