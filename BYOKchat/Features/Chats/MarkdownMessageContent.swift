import MarkdownUI
import SwiftUI
import UIKit

struct MarkdownMessageContent: View {
  let text: String

  var body: some View {
    Markdown(text)
      .markdownTheme(.gitHub)
      .markdownBlockStyle(\.codeBlock) { configuration in
        ChatCodeBlock(configuration: configuration)
      }
      .textSelection(.enabled)
      .tint(.accentColor)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ChatCodeBlock: View {
  let configuration: CodeBlockConfiguration

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(configuration.language?.uppercased() ?? "CODE")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Spacer(minLength: 8)

        Button("Copy Code", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = configuration.content
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 14, weight: .medium))
        .frame(width: 34, height: 30)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityLabel("Copy code block")
      }
      .padding(.leading, 12)
      .padding(.trailing, 6)
      .frame(minHeight: 38)
      .background(Color(uiColor: .tertiarySystemBackground))

      Divider()

      ScrollView(.horizontal) {
        configuration.label
          .relativeLineSpacing(.em(0.22))
          .markdownTextStyle {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
          }
          .padding(12)
      }
      .scrollIndicators(.visible)
    }
    .background(Color(uiColor: .secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
    )
    .markdownMargin(top: .zero, bottom: .em(0.8))
  }
}
