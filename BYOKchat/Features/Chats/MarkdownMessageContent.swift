import SwiftUI
import UIKit

struct MarkdownMessageContent: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(Array(MessageBlock.parse(text).enumerated()), id: \.offset) { _, block in
        switch block {
        case .markdown(let value):
          if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(.init(value))
              .font(.system(size: 18, weight: .regular, design: .default))
              .lineSpacing(7)
              .foregroundStyle(.primary)
              .tint(.primary)
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
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(language ?? "Code")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Copy Code", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = code
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 15))
        .frame(width: 36, height: 36)
        .accessibilityLabel("Copy code block")
      }

      ScrollView(.horizontal) {
        Text(code)
          .font(.system(size: 15, design: .monospaced))
          .lineSpacing(4)
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .padding(12)
    .background(
      Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    )
  }
}
