import AppFoundation
import MarkdownUI
import SwiftUI
import UIKit

struct MarkdownMessageContent: View {
  let text: String

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    Markdown(text)
      .markdownTheme(chatTheme)
      .markdownBlockStyle(\.codeBlock) { configuration in
        ChatCodeBlock(configuration: configuration)
      }
      .textSelection(.enabled)
      .tint(theme.accentColor)
      .frame(maxWidth: .infinity, alignment: .leading)
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
          configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .markdownTableBorderStyle(.init(color: theme.borderColor))
            .markdownTableBackgroundStyle(
              .alternatingRows(theme.surfaceColor, theme.elevatedSurfaceColor)
            )
        }
        .scrollIndicators(.hidden)
        .markdownMargin(top: .em(0.08), bottom: .em(0.9))
      }
      .tableCell { configuration in
        configuration.label
          .markdownTextStyle {
            if configuration.row == 0 {
              FontWeight(.semibold)
              ForegroundColor(theme.primaryForegroundColor)
            } else {
              ForegroundColor(theme.secondaryForegroundColor)
            }
            BackgroundColor(nil)
          }
          .fixedSize(horizontal: false, vertical: true)
          .relativeLineSpacing(.em(0.16))
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
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

private struct ChatCodeBlock: View {
  let configuration: CodeBlockConfiguration

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        HStack(spacing: 6) {
          Circle()
            .fill(theme.accentColor)
            .frame(width: 6, height: 6)

          Text(configuration.language?.uppercased() ?? "CODE")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(theme.secondaryForegroundColor)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        Button {
          UIPasteboard.general.string = configuration.content
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(theme.surfaceColor, in: Capsule())
        }
        .foregroundStyle(theme.secondaryForegroundColor)
        .buttonStyle(.plain)
        .accessibilityLabel("Copy code block")
      }
      .padding(.leading, 13)
      .padding(.trailing, 7)
      .frame(minHeight: 42)
      .background(theme.elevatedSurfaceColor)

      Rectangle()
        .fill(theme.borderColor)
        .frame(height: 0.5)

      ScrollView(.horizontal) {
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .relativeLineSpacing(.em(0.24))
          .markdownTextStyle {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            ForegroundColor(theme.primaryForegroundColor)
          }
          .padding(14)
      }
      .scrollIndicators(.visible)
    }
    .background(theme.surfaceColor)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 0.75)
    )
    .shadow(color: theme.appearance.shadow.color.opacity(0.35), radius: 8, y: 3)
    .markdownMargin(top: .em(0.1), bottom: .em(0.9))
  }
}
