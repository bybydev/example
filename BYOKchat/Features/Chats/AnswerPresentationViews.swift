import AppFoundation
import BeautifulMermaid
import Foundation
import Highlighter
import LaTeXSwiftUI
import SafariServices
import SwiftUI
import UIKit

struct BrowserDestination: Identifiable, Equatable {
  let url: URL
  var id: String { url.absoluteString }
}

enum HighlightedCodeBlockSupport {
  static let collapsedLineLimit = 14
  static let collapsedCharacterLimit = 1_800

  struct Preview: Equatable, Sendable {
    let displayedContent: String
    let isLong: Bool
    let toggleLabel: String
  }

  static func preview(for content: String, isExpanded: Bool) -> Preview {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    let exceedsLines = lines.count > collapsedLineLimit
    let exceedsCharacters = content.count > collapsedCharacterLimit
    let isLong = exceedsLines || exceedsCharacters

    let displayedContent: String
    if isLong, !isExpanded {
      let lineCapped = exceedsLines ? lines.prefix(collapsedLineLimit).joined(separator: "\n") : content
      let capped = lineCapped.count > collapsedCharacterLimit
        ? String(lineCapped.prefix(collapsedCharacterLimit))
        : lineCapped
      displayedContent = capped + "\n…"
    } else {
      displayedContent = content
    }

    let toggleLabel: String
    if isExpanded {
      toggleLabel = "Collapse code"
    } else if exceedsLines {
      toggleLabel = "Show all \(lines.count) lines"
    } else {
      toggleLabel = "Show full code"
    }

    return Preview(
      displayedContent: displayedContent,
      isLong: isLong,
      toggleLabel: toggleLabel
    )
  }
}

struct HighlightedCodeBlock: View {
  let language: String?
  let content: String
  var isComplete: Bool = true

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @ScaledMetric(relativeTo: .callout) private var codeFontSize: CGFloat = 14
  @State private var isExpanded = false
  @State private var showFullScreen = false

  private var languageLabel: String {
    let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? "CODE" : value.uppercased()
  }

  var body: some View {
    let preview = HighlightedCodeBlockSupport.preview(for: content, isExpanded: isExpanded)

    VStack(spacing: 0) {
      header

      Rectangle()
        .fill(theme.borderColor)
        .frame(height: 0.5)

      ScrollView(.horizontal) {
        HighlightedCodeText(
          code: preview.displayedContent,
          language: language,
          colorScheme: colorScheme,
          fontSize: codeFontSize,
          isComplete: isComplete
        )
        .padding(14)
      }
      .scrollIndicators(.visible)

      if preview.isLong {
        Rectangle()
          .fill(theme.borderColor)
          .frame(height: 0.5)

        Button {
          withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
          Label(
            preview.toggleLabel,
            systemImage: isExpanded ? "chevron.up" : "chevron.down"
          )
          .font(.system(size: 12, weight: .semibold))
          .frame(maxWidth: .infinity)
          .frame(height: 40)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .background(theme.surfaceColor)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 0.75)
    )
    .shadow(color: theme.appearance.shadow.color.opacity(0.3), radius: 8, y: 3)
    .sheet(isPresented: $showFullScreen) {
      FullScreenCodeView(language: language, content: content)
    }
  }

  private var header: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(theme.accentColor)
        .frame(width: 6, height: 6)

      Text(languageLabel)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(theme.secondaryForegroundColor)
        .lineLimit(1)
        .padding(.leading, 4)

      Spacer(minLength: 8)

      Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
        showFullScreen = true
      }
      .labelStyle(.iconOnly)
      .frame(width: 40, height: 38)
      .contentShape(Rectangle())

      CopyButton(text: content, accessibilityTitle: "Copy Code", size: .compact)
    }
    .font(.system(size: 13, weight: .semibold))
    .foregroundStyle(theme.secondaryForegroundColor)
    .buttonStyle(.plain)
    .padding(.leading, 13)
    .padding(.trailing, 4)
    .frame(minHeight: 42)
    .background(theme.elevatedSurfaceColor)
  }
}

private struct HighlightedCodeText: View {
  private struct RenderKey: Equatable {
    let code: String
    let language: String?
    let isDark: Bool
    let fontSize: Int
    let isComplete: Bool
  }

  let code: String
  let language: String?
  let colorScheme: ColorScheme
  let fontSize: CGFloat
  var isComplete: Bool = true

  @State private var highlighted: AttributedString?
  @State private var highlightedKey: RenderKey?

  var body: some View {
    Group {
      if let highlighted, highlightedKey == renderKey {
        Text(highlighted)
      } else {
        Text(code)
          .font(.system(size: fontSize, design: .monospaced))
      }
    }
    .fixedSize(horizontal: true, vertical: true)
    .textSelection(.enabled)
    .task(id: renderKey) {
      guard isComplete else {
        highlighted = nil
        highlightedKey = nil
        return
      }
      let key = renderKey
      let rendered = await SyntaxHighlighting.shared.render(
        code: code,
        language: language,
        isDark: colorScheme == .dark,
        fontSize: fontSize
      )
      guard !Task.isCancelled else { return }
      highlighted = rendered
      highlightedKey = rendered != nil ? key : nil
    }
  }

  private var renderKey: RenderKey {
    RenderKey(
      code: code,
      language: language,
      isDark: colorScheme == .dark,
      fontSize: Int(fontSize.rounded()),
      isComplete: isComplete
    )
  }
}

private actor SyntaxHighlighting {
  private struct CacheKey: Hashable, Sendable {
    let code: String
    let language: String?
    let isDark: Bool
    let fontSize: Int
  }

  static let shared = SyntaxHighlighting()

  private var highlighter: Highlighter?
  private var configuredTheme: String?
  private var configuredFontSize: Int?
  private var cache: [CacheKey: AttributedString] = [:]
  private var cacheOrder: [CacheKey] = []
  private let cacheLimit = 64

  func render(
    code: String,
    language: String?,
    isDark: Bool,
    fontSize: CGFloat = 14
  ) -> AttributedString? {
    guard !Task.isCancelled else { return nil }
    let roundedFontSize = max(11, min(32, Int(fontSize.rounded())))
    let key = CacheKey(code: code, language: language, isDark: isDark, fontSize: roundedFontSize)
    if let cached = cache[key] {
      return cached
    }

    if highlighter == nil {
      highlighter = Highlighter()
    }
    guard let highlighter else { return nil }

    let themeName = isDark ? "github-dark" : "github"
    if configuredTheme != themeName || configuredFontSize != roundedFontSize {
      _ = highlighter.setTheme(
        themeName,
        withFont: "Menlo-Regular",
        ofSize: CGFloat(roundedFontSize)
      )
      configuredTheme = themeName
      configuredFontSize = roundedFontSize
    }

    guard !Task.isCancelled else { return nil }
    let normalizedLanguage = normalize(language)
    guard let value = highlighter.highlight(code, as: normalizedLanguage) else {
      return nil
    }

    let mutable = NSMutableAttributedString(attributedString: value)
    let fullRange = NSRange(location: 0, length: mutable.length)
    mutable.removeAttribute(.backgroundColor, range: fullRange)
    let rendered = AttributedString(mutable)

    cache[key] = rendered
    cacheOrder.append(key)
    if cacheOrder.count > cacheLimit {
      let evicted = cacheOrder.removeFirst()
      cache.removeValue(forKey: evicted)
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

private struct FullScreenCodeView: View {
  let language: String?
  let content: String

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @ScaledMetric(relativeTo: .callout) private var codeFontSize: CGFloat = 14

  var body: some View {
    NavigationStack {
      ScrollView([.horizontal, .vertical]) {
        HighlightedCodeText(
          code: content,
          language: language,
          colorScheme: colorScheme,
          fontSize: codeFontSize
        )
        .padding(20)
      }
      .background(theme.backgroundColor)
      .navigationTitle(language?.uppercased() ?? "Code")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          ShareLink(item: content) {
            Image(systemName: "square.and.arrow.up")
          }
          CopyButton(text: content, accessibilityTitle: "Copy Code", size: .toolbar)
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

struct MathAnswerView: View {
  let expression: String

  @Environment(\.appFoundationTheme) private var theme
  @ScaledMetric(relativeTo: .body) private var mathFontSize: CGFloat = 17

  var body: some View {
    LaTeX("$$\(expression)$$")
      .blockMode(.blockViews)
      .renderingStyle(.redactedOriginal)
      .renderingAnimation(.easeOut(duration: 0.18))
      .errorMode(.original)
      .imageRenderingMode(.template)
      .imageAccessibility(.sre)
      .font(.system(size: mathFontSize))
      .foregroundStyle(theme.primaryForegroundColor)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, 12)
      .padding(.vertical, 14)
      .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(theme.borderColor, lineWidth: 0.75)
      )
  }
}

struct MermaidAnswerView: View {
  let source: String
  var isComplete: Bool = true

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @State private var parseError: Error?
  @State private var diagramBounds = CGRect.zero
  @State private var showFullScreen = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 4) {
        Label("DIAGRAM", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(theme.secondaryForegroundColor)

        Spacer()

        Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
          showFullScreen = true
        }
        .labelStyle(.iconOnly)
        .frame(width: 40, height: 38)
        .contentShape(Rectangle())
        .disabled(!isComplete)
        .opacity(isComplete ? 1 : 0.35)

        CopyButton(text: source, accessibilityTitle: "Copy Mermaid Source", size: .compact)
      }
      .buttonStyle(.plain)
      .foregroundStyle(theme.secondaryForegroundColor)
      .padding(.leading, 12)
      .padding(.trailing, 4)
      .frame(minHeight: 42)
      .background(theme.elevatedSurfaceColor)

      Rectangle().fill(theme.borderColor).frame(height: 0.5)

      if !isComplete {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Rendering diagram…")
              .font(.caption.weight(.medium))
              .foregroundStyle(theme.secondaryForegroundColor)
          }
          if !source.isEmpty {
            ScrollView(.horizontal) {
              Text(source)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(theme.secondaryForegroundColor)
                .fixedSize(horizontal: true, vertical: true)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
      } else if let parseError {
        VStack(alignment: .leading, spacing: 8) {
          Label("Could not render this diagram", systemImage: "exclamationmark.triangle")
            .font(.subheadline.weight(.semibold))
          Text(parseError.localizedDescription)
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
          ScrollView(.horizontal) {
            Text(source)
              .font(.system(size: 13, design: .monospaced))
              .textSelection(.enabled)
              .fixedSize(horizontal: true, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
      } else {
        // BeautifulMermaid exposes the diagram's natural pixel size through
        // intrinsicContentSize. Under the transcript's ideal-size passes that
        // value escapes as this block's reported width, widening the message
        // column and pushing sibling code blocks past the screen edge — pin
        // the representable to an explicit slot so only the offered proposal
        // reaches layout.
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
    .background(theme.surfaceColor)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 0.75)
    )
    .onChange(of: source) { _, _ in
      parseError = nil
      diagramBounds = .zero
    }
    .onChange(of: isComplete) { _, complete in
      if complete {
        parseError = nil
        diagramBounds = .zero
      }
    }
    .sheet(isPresented: $showFullScreen) {
      FullScreenMermaidView(source: source)
    }
  }

  private var diagramTheme: DiagramTheme {
    colorScheme == .dark ? .githubDark : .githubLight
  }

  private var diagramHeight: CGFloat {
    min(max(diagramBounds.height + 24, 180), 460)
  }
}

private struct FullScreenMermaidView: View {
  let source: String

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @State private var parseError: Error?
  @State private var diagramBounds = CGRect.zero

  var body: some View {
    NavigationStack {
      MermaidDiagramView(
        source: source,
        theme: colorScheme == .dark ? .githubDark : .githubLight,
        parseError: $parseError,
        diagramBounds: $diagramBounds
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(theme.backgroundColor)
      .navigationTitle("Diagram")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          ShareLink(item: source) {
            Image(systemName: "square.and.arrow.up")
          }
          CopyButton(text: source, accessibilityTitle: "Copy Mermaid Source", size: .toolbar)
          Button("Done") { dismiss() }
        }
      }
      .onChange(of: source) { _, _ in
        parseError = nil
        diagramBounds = .zero
      }
      .overlay {
        if let parseError {
          ContentUnavailableView(
            "Diagram Error",
            systemImage: "exclamationmark.triangle",
            description: Text(parseError.localizedDescription)
          )
          .padding()
        }
      }
    }
  }
}

struct AnswerSourcesSheet: View {
  let sources: [AnswerSource]

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var browserDestination: BrowserDestination?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 9) {
          ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
            Button {
              guard AnswerContentParser.isValidBrowsableURL(source.url) else { return }
              browserDestination = BrowserDestination(url: source.url)
            } label: {
              HStack(spacing: 11) {
                Text("\(index + 1)")
                  .font(.system(size: 11, weight: .bold, design: .rounded))
                  .foregroundStyle(theme.accentColor)
                  .frame(width: 26, height: 26)
                  .background(theme.accentColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                  Text(source.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.primaryForegroundColor)
                    .lineLimit(1)
                  Text(source.host)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                  .font(.system(size: 12, weight: .semibold))
                  .foregroundStyle(theme.secondaryForegroundColor)
              }
              .padding(.horizontal, 11)
              .frame(minHeight: 48)
              .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                  .stroke(theme.borderColor, lineWidth: 0.6)
              )
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(theme.backgroundColor.ignoresSafeArea())
      .navigationTitle("Sources")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .sheet(item: $browserDestination) { destination in
      InAppBrowserView(url: destination.url)
        .ignoresSafeArea()
    }
  }
}

struct InAppBrowserView: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> SFSafariViewController {
    let configuration = SFSafariViewController.Configuration()
    configuration.entersReaderIfAvailable = false
    configuration.barCollapsingEnabled = true
    return SFSafariViewController(url: url, configuration: configuration)
  }

  func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
