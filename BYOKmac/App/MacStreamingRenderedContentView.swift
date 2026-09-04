import SwiftUI

struct MacStreamingRenderedContentView: View {
  let snapshot: MacStreamingAnswerSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(snapshot.stableBlocks) { rendered in
        MacStableRenderedAnswerBlockView(rendered: rendered)
          .equatable()
      }

      ForEach(Array(snapshot.tailBlocks.enumerated()), id: \.offset) { _, block in
        MacStreamingTailBlockView(block: block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MacStableRenderedAnswerBlockView: View, Equatable {
  let rendered: MacRenderedAnswerBlock

  @ViewBuilder
  var body: some View {
    switch rendered.block {
    case .markdown(let source):
      // MarkdownUI and inline LaTeX are allowed only after this top-level
      // block has crossed the stable boundary. Its input never changes again.
      MacMarkdownMessageContent(text: source)

    case .code(let language, let content, let isComplete):
      if MacAnswerContentParser.isMermaidLanguage(language), isComplete {
        MacMermaidAnswerView(source: content)
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
    }
  }
}

/// The mutable suffix deliberately avoids every rich renderer. This keeps
/// Markdown parsing, syntax highlighting, Mermaid layout, and LaTeX conversion
/// out of the per-token path. A tail may change representation once when it
/// becomes stable; until then readable source is preferred over rich output.
private struct MacStreamingTailBlockView: View {
  let block: MacAnswerContentBlock

  @ViewBuilder
  var body: some View {
    switch block {
    case .markdown(let source):
      Text(stabilizedTailText(source))
        .font(.system(size: 15))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

    case .code(let language, let content, _):
      MacStreamingCodeSourceView(language: language, content: content)

    case .math(let expression, _):
      MacStreamingMathSourceView(expression: expression)
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
