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

struct HighlightedCodeBlock: View {
  let language: String?
  let content: String

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @State private var isExpanded = false
  @State private var showFullScreen = false

  private let collapsedLineLimit = 14

  private var lines: [Substring] {
    content.split(separator: "\n", omittingEmptySubsequences: false)
  }

  private var isLong: Bool {
    lines.count > collapsedLineLimit || content.count > 1_800
  }

  private var displayedContent: String {
    guard isLong, !isExpanded else { return content }
    return lines.prefix(collapsedLineLimit).joined(separator: "\n") + "\n…"
  }

  private var languageLabel: String {
    let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? "CODE" : value.uppercased()
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Rectangle()
        .fill(theme.borderColor)
        .frame(height: 0.5)

      ScrollView(.horizontal) {
        HighlightedCodeText(
          code: displayedContent,
          language: language,
          colorScheme: colorScheme
        )
        .padding(14)
      }
      .scrollIndicators(.visible)

      if isLong {
        Rectangle()
          .fill(theme.borderColor)
          .frame(height: 0.5)

        Button {
          withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
          Label(
            isExpanded ? "Collapse code" : "Show all \(lines.count) lines",
            systemImage: isExpanded ? "chevron.up" : "chevron.down"
          )
          .font(.system(size: 12, weight: .semibold))
          .frame(maxWidth: .infinity)
          .frame(height: 38)
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
    HStack(spacing: 8) {
      Circle()
        .fill(theme.accentColor)
        .frame(width: 6, height: 6)

      Text(languageLabel)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(theme.secondaryForegroundColor)
        .lineLimit(1)

      Spacer(minLength: 8)

      Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
        showFullScreen = true
      }
      .labelStyle(.iconOnly)
      .frame(width: 34, height: 30)

      Button("Copy Code", systemImage: "doc.on.doc") {
        UIPasteboard.general.string = content
      }
      .labelStyle(.iconOnly)
      .frame(width: 34, height: 30)
    }
    .font(.system(size: 13, weight: .semibold))
    .foregroundStyle(theme.secondaryForegroundColor)
    .buttonStyle(.plain)
    .padding(.leading, 13)
    .padding(.trailing, 7)
    .frame(minHeight: 42)
    .background(theme.elevatedSurfaceColor)
  }
}

private struct HighlightedCodeText: View {
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
          .font(.system(size: 14, design: .monospaced))
      }
    }
    .fixedSize(horizontal: true, vertical: true)
    .textSelection(.enabled)
    .task(id: renderID) {
      highlighted = await SyntaxHighlighting.shared.render(
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

private actor SyntaxHighlighting {
  private struct CacheKey: Hashable, Sendable {
    let code: String
    let language: String?
    let isDark: Bool
  }

  static let shared = SyntaxHighlighting()

  private var cache: [CacheKey: AttributedString] = [:]
  private var cacheOrder: [CacheKey] = []
  private let cacheLimit = 64

  func render(
    code: String,
    language: String?,
    isDark: Bool
  ) -> AttributedString? {
    let key = CacheKey(code: code, language: language, isDark: isDark)
    if let cached = cache[key] {
      return cached
    }

    guard let highlighter = Highlighter() else { return nil }
    _ = highlighter.setTheme(
      isDark ? "github-dark" : "github",
      withFont: "Menlo-Regular",
      ofSize: 14
    )

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

  var body: some View {
    NavigationStack {
      ScrollView([.horizontal, .vertical]) {
        HighlightedCodeText(code: content, language: language, colorScheme: colorScheme)
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
          Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = content
          }
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

struct MathAnswerView: View {
  let expression: String

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    LaTeX("$$\(expression)$$")
      .blockMode(.blockViews)
      .renderingStyle(.redactedOriginal)
      .renderingAnimation(.easeOut(duration: 0.18))
      .errorMode(.original)
      .imageRenderingMode(.template)
      .imageAccessibility(.sre)
      .font(.system(size: 17))
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

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @State private var parseError: Error?
  @State private var diagramBounds = CGRect.zero
  @State private var showFullScreen = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Label("DIAGRAM", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(theme.secondaryForegroundColor)

        Spacer()

        Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
          showFullScreen = true
        }
        .labelStyle(.iconOnly)
        .frame(width: 34, height: 30)

        Button("Copy Mermaid Source", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = source
        }
        .labelStyle(.iconOnly)
        .frame(width: 34, height: 30)
      }
      .buttonStyle(.plain)
      .foregroundStyle(theme.secondaryForegroundColor)
      .padding(.horizontal, 10)
      .frame(minHeight: 42)
      .background(theme.elevatedSurfaceColor)

      Rectangle().fill(theme.borderColor).frame(height: 0.5)

      if let parseError {
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
        MermaidDiagramView(
          source: source,
          theme: diagramTheme,
          parseError: $parseError,
          diagramBounds: $diagramBounds
        )
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
          Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = source
          }
          Button("Done") { dismiss() }
        }
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

struct AnswerSourcesView: View {
  let sources: [AnswerSource]
  let open: (URL) -> Void

  @Environment(\.appFoundationTheme) private var theme
  @State private var isExpanded = false

  private var visibleSources: ArraySlice<AnswerSource> {
    sources.prefix(isExpanded ? sources.count : min(3, sources.count))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("Sources", systemImage: "link")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.secondaryForegroundColor)

      ForEach(Array(visibleSources.enumerated()), id: \.element.id) { index, source in
        Button {
          open(source.url)
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

      if sources.count > 3 {
        Button(isExpanded ? "Show fewer sources" : "Show all \(sources.count) sources") {
          withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.accentColor)
      }
    }
    .padding(.top, 3)
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
