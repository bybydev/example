import SwiftUI
import UIKit

struct MarkdownMessageContent: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(MessageBlock.parse(text).enumerated()), id: \.offset) { _, block in
        switch block {
        case .markdown(let value):
          if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(.init(value))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        case .code(let language, let value):
          CodeBlockView(language: language, code: value)
        }
      }
    }
  }
}

enum MessageBlock {
  case markdown(String)
  case code(language: String?, value: String)

  static func parse(_ text: String) -> [MessageBlock] {
    let pieces = text.components(separatedBy: "```")
    guard pieces.count > 1 else { return [.markdown(text)] }
    return pieces.enumerated().compactMap { index, piece in
      if index.isMultiple(of: 2) { return .markdown(piece) }
      let lines = piece.split(separator: "\n", omittingEmptySubsequences: false)
      guard let first = lines.first else { return .code(language: nil, value: "") }
      let language = first.trimmingCharacters(in: .whitespacesAndNewlines)
      let code = lines.dropFirst().joined(separator: "\n")
      return .code(language: language.isEmpty ? nil : language, value: code)
    }
  }
}

struct CodeBlockView: View {
  let language: String?
  let code: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(language ?? "Code")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Copy Code", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = code
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel("Copy code block")
      }
      ScrollView(.horizontal) {
        Text(code)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .padding(10)
    .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }
}
