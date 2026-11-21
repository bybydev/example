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

enum MermaidDiagramSupport {
  enum CanvasRole {
    case inlineCard
    case fullScreen
  }

  struct Analysis: Equatable, Sendable {
    let renderSource: String
    let title: String?
    let kindLabel: String
    let displayTitle: String
    let unsupportedKindName: String?
    let isEmpty: Bool

    var headerLabel: String {
      if let title, !title.isEmpty {
        return "\(kindLabel) · \(title)"
      }
      return kindLabel
    }
  }

  static let defaultInlineHeight: CGFloat = 180
  static let minInlineHeight: CGFloat = 110
  static let maxInlineHeight: CGFloat = 420
  static let inlineVerticalPadding: CGFloat = 20

  /// Analyzes Mermaid source to strip leading YAML frontmatter (which
  /// BeautifulMermaid 1.0.4 does not parse), extract an optional title,
  /// classify the diagram type, and flag unsupported Mermaid diagram types.
  static func analyze(_ source: String) -> Analysis {
    let (strippedSource, frontmatterTitle) = stripLeadingFrontmatter(from: source)
    let trimmed = strippedSource.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return Analysis(
        renderSource: "",
        title: frontmatterTitle,
        kindLabel: "DIAGRAM",
        displayTitle: "Diagram",
        unsupportedKindName: nil,
        isEmpty: true
      )
    }

    let firstDirective = firstDiagramDirectiveLine(in: strippedSource)
    let firstToken = firstDirective?
      .split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "{" })
      .first
      .map { String($0).lowercased() } ?? ""

    let classification = classify(token: firstToken, line: firstDirective?.lowercased() ?? "")
    return Analysis(
      renderSource: strippedSource,
      title: frontmatterTitle,
      kindLabel: classification.kindLabel,
      displayTitle: classification.displayTitle,
      unsupportedKindName: classification.unsupportedKindName,
      isEmpty: false
    )
  }

  /// Computes a proportional height for the inline diagram card after fitting
  /// `diagramBounds` into `availableWidth`, avoiding large vertical dead space
  /// on wide horizontal diagrams while keeping tall diagrams compact.
  static func inlineHeight(for diagramBounds: CGRect, availableWidth: CGFloat) -> CGFloat {
    guard diagramBounds.width > 0, diagramBounds.height > 0 else {
      return defaultInlineHeight
    }
    let usableWidth = max(160, availableWidth)
    let fitScale = min(1.0, usableWidth / diagramBounds.width)
    let fittedHeight = ceil(diagramBounds.height * fitScale) + inlineVerticalPadding
    return min(max(fittedHeight, minInlineHeight), maxInlineHeight)
  }

  /// Computes a crisp Retina scale factor capped so huge diagrams never
  /// allocate an oversized bitmap (>4096 px on the longest side).
  static func renderScale(
    for diagramSize: CGSize,
    desiredScale: CGFloat = 3.0,
    maxPixelDimension: CGFloat = 4096
  ) -> CGFloat {
    let safeDesired = max(1.0, min(desiredScale, 3.0))
    let maxDim = max(diagramSize.width, diagramSize.height)
    guard maxDim > 0 else { return safeDesired }
    return max(1.0, min(safeDesired, maxPixelDimension / maxDim))
  }

  /// Builds a `DiagramTheme` matched to the active BYOKchat theme so diagrams
  /// blend seamlessly into all 10 Dark and Light palettes.
  @MainActor
  static func diagramTheme(
    from theme: AppTheme,
    colorScheme: ColorScheme,
    canvas: CanvasRole
  ) -> DiagramTheme {
    let canvasColor: Color
    let nodeSurfaceColor: Color

    switch (canvas, colorScheme) {
    case (.inlineCard, .dark):
      canvasColor = theme.surfaceColor
      nodeSurfaceColor = theme.elevatedSurfaceColor
    case (.inlineCard, _):
      canvasColor = theme.surfaceColor
      nodeSurfaceColor = theme.backgroundColor
    case (.fullScreen, .dark):
      canvasColor = theme.backgroundColor
      nodeSurfaceColor = theme.surfaceColor
    case (.fullScreen, _):
      canvasColor = theme.backgroundColor
      nodeSurfaceColor = theme.elevatedSurfaceColor
    }

    return DiagramTheme(
      background: UIColor(canvasColor),
      foreground: UIColor(theme.primaryForegroundColor),
      line: nil,
      accent: UIColor(theme.accentColor),
      muted: UIColor(theme.secondaryForegroundColor),
      surface: UIColor(nodeSurfaceColor),
      border: UIColor(theme.borderColor)
    )
  }

  static func renderImage(
    source: String,
    theme: DiagramTheme,
    desiredScale: CGFloat = 3.0
  ) async throws -> UIImage? {
    try await Task.detached(priority: .userInitiated) {
      let positioned = try MermaidRenderer.layout(source)
      let scale = renderScale(
        for: CGSize(width: positioned.width, height: positioned.height),
        desiredScale: desiredScale
      )
      let renderer = MermaidImageRenderer(theme: theme)
      return renderer.renderImage(from: positioned, scale: scale)
    }.value
  }

  private struct Classification {
    let kindLabel: String
    let displayTitle: String
    let unsupportedKindName: String?
  }

  private static func classify(token: String, line: String) -> Classification {
    if token == "graph" || token.hasPrefix("flowchart") {
      return Classification(kindLabel: "FLOWCHART", displayTitle: "Flowchart", unsupportedKindName: nil)
    }
    if token.hasPrefix("sequencediagram") {
      return Classification(
        kindLabel: "SEQUENCE",
        displayTitle: "Sequence Diagram",
        unsupportedKindName: nil
      )
    }
    if token.hasPrefix("statediagram") {
      return Classification(
        kindLabel: "STATE",
        displayTitle: "State Diagram",
        unsupportedKindName: nil
      )
    }
    if token.hasPrefix("classdiagram") {
      return Classification(
        kindLabel: "CLASS",
        displayTitle: "Class Diagram",
        unsupportedKindName: nil
      )
    }
    if token.hasPrefix("erdiagram") {
      return Classification(
        kindLabel: "ER DIAGRAM",
        displayTitle: "ER Diagram",
        unsupportedKindName: nil
      )
    }
    if token.hasPrefix("xychart") {
      return Classification(kindLabel: "XY CHART", displayTitle: "XY Chart", unsupportedKindName: nil)
    }

    // Known Mermaid diagram types not supported by BeautifulMermaid 1.0.4.
    switch token {
    case "pie":
      return Classification(kindLabel: "PIE CHART", displayTitle: "Pie Chart", unsupportedKindName: "Pie charts")
    case "gantt":
      return Classification(kindLabel: "GANTT", displayTitle: "Gantt Chart", unsupportedKindName: "Gantt charts")
    case "mindmap":
      return Classification(kindLabel: "MINDMAP", displayTitle: "Mindmap", unsupportedKindName: "Mindmaps")
    case "timeline":
      return Classification(kindLabel: "TIMELINE", displayTitle: "Timeline", unsupportedKindName: "Timelines")
    case "gitgraph":
      return Classification(kindLabel: "GIT GRAPH", displayTitle: "Git Graph", unsupportedKindName: "Git graphs")
    case "journey":
      return Classification(
        kindLabel: "JOURNEY",
        displayTitle: "User Journey",
        unsupportedKindName: "User journey diagrams"
      )
    case "quadrantchart":
      return Classification(
        kindLabel: "QUADRANT",
        displayTitle: "Quadrant Chart",
        unsupportedKindName: "Quadrant charts"
      )
    case "sankey", "sankey-beta":
      return Classification(
        kindLabel: "SANKEY",
        displayTitle: "Sankey Diagram",
        unsupportedKindName: "Sankey diagrams"
      )
    case "requirementdiagram":
      return Classification(
        kindLabel: "REQUIREMENT",
        displayTitle: "Requirement Diagram",
        unsupportedKindName: "Requirement diagrams"
      )
    case "block", "block-beta":
      return Classification(
        kindLabel: "BLOCK",
        displayTitle: "Block Diagram",
        unsupportedKindName: "Block diagrams"
      )
    case "architecture", "architecture-beta":
      return Classification(
        kindLabel: "ARCHITECTURE",
        displayTitle: "Architecture Diagram",
        unsupportedKindName: "Architecture diagrams"
      )
    case "kanban":
      return Classification(
        kindLabel: "KANBAN",
        displayTitle: "Kanban Board",
        unsupportedKindName: "Kanban boards"
      )
    case "packet", "packet-beta":
      return Classification(
        kindLabel: "PACKET",
        displayTitle: "Packet Diagram",
        unsupportedKindName: "Packet diagrams"
      )
    case "radar", "radar-beta":
      return Classification(
        kindLabel: "RADAR",
        displayTitle: "Radar Chart",
        unsupportedKindName: "Radar charts"
      )
    default:
      if token.hasPrefix("c4") || line.hasPrefix("c4") {
        return Classification(
          kindLabel: "C4 DIAGRAM",
          displayTitle: "C4 Diagram",
          unsupportedKindName: "C4 diagrams"
        )
      }
      return Classification(kindLabel: "DIAGRAM", displayTitle: "Diagram", unsupportedKindName: nil)
    }
  }

  private static func stripLeadingFrontmatter(from source: String) -> (String, String?) {
    let lines = source.components(separatedBy: .newlines)
    guard let firstNonEmptyIndex = lines.firstIndex(where: {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) else {
      return (source, nil)
    }

    guard lines[firstNonEmptyIndex].trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
      return (source, nil)
    }

    var closingIndex: Int?
    var title: String?
    for index in (firstNonEmptyIndex + 1)..<lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == "---" || trimmed == "..." {
        closingIndex = index
        break
      }
      if title == nil, trimmed.lowercased().hasPrefix("title:") {
        let rawTitle = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted = stripMatchingQuotes(rawTitle)
        if !unquoted.isEmpty {
          title = unquoted
        }
      }
    }

    guard let closingIndex else {
      return (source, nil)
    }

    let remainder = lines[(closingIndex + 1)...].joined(separator: "\n")
    return (remainder, title)
  }

  private static func stripMatchingQuotes(_ value: String) -> String {
    guard value.count >= 2 else { return value }
    if (value.hasPrefix("\"") && value.hasSuffix("\""))
      || (value.hasPrefix("'") && value.hasSuffix("'"))
    {
      return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value
  }

  private static func firstDiagramDirectiveLine(in source: String) -> String? {
    var inInitDirective = false
    for rawLine in source.components(separatedBy: .newlines) {
      let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if inInitDirective {
        if trimmed.contains("}%%") {
          inInitDirective = false
        }
        continue
      }
      if trimmed.hasPrefix("%%{") {
        if !trimmed.contains("}%%") {
          inInitDirective = true
        }
        continue
      }
      if trimmed.hasPrefix("%%") { continue }
      return trimmed
    }
    return nil
  }
}

struct MermaidAnswerView: View {
  let source: String
  var isComplete: Bool = true

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @ScaledMetric(relativeTo: .callout) private var sourceFontSize: CGFloat = 13
  @State private var parseError: Error?
  @State private var diagramBounds = CGRect.zero
  @State private var cardWidth: CGFloat = 340
  @State private var showFullScreen = false
  @State private var showSource = false
  @State private var isSourceExpanded = false

  var body: some View {
    let analysis = MermaidDiagramSupport.analyze(source)
    let canRenderDiagram = isComplete && !analysis.isEmpty && analysis.unsupportedKindName == nil && parseError == nil
    let inlineTheme = MermaidDiagramSupport.diagramTheme(
      from: theme,
      colorScheme: colorScheme,
      canvas: .inlineCard
    )
    let availableDiagramWidth = max(160, cardWidth - 16)
    let diagramHeight = MermaidDiagramSupport.inlineHeight(
      for: diagramBounds,
      availableWidth: availableDiagramWidth
    )
    let isScaledDown = diagramBounds.width > availableDiagramWidth * 1.15

    VStack(spacing: 0) {
      header(analysis: analysis, canRenderDiagram: canRenderDiagram)

      Rectangle().fill(theme.borderColor).frame(height: 0.5)

      if !isComplete {
        streamingBody
      } else if analysis.isEmpty {
        Text("Empty diagram block.")
          .font(.footnote)
          .foregroundStyle(theme.secondaryForegroundColor)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
      } else if let unsupportedKindName = analysis.unsupportedKindName {
        unsupportedBody(kindName: unsupportedKindName)
      } else if let parseError {
        errorBody(error: parseError)
      } else if showSource {
        collapsibleSourceBody(content: source)
      } else {
        // BeautifulMermaid exposes the diagram's natural pixel size through
        // intrinsicContentSize. Under the transcript's ideal-size passes that
        // value escapes as this block's reported width, widening the message
        // column and pushing sibling code blocks past the screen edge — pin
        // the representable to an explicit slot so only the offered proposal
        // reaches layout.
        ZStack(alignment: .bottomTrailing) {
          GeometryReader { proxy in
            MermaidDiagramView(
              source: analysis.renderSource,
              theme: inlineTheme,
              parseError: $parseError,
              diagramBounds: $diagramBounds
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
          }
          .frame(height: diagramHeight)
          .padding(8)

          if isScaledDown {
            Label("Tap to zoom", systemImage: "plus.magnifyingglass")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(theme.secondaryForegroundColor)
              .padding(.horizontal, 9)
              .padding(.vertical, 5)
              .background(
                theme.elevatedSurfaceColor.opacity(0.92),
                in: Capsule()
              )
              .overlay(
                Capsule()
                  .stroke(theme.borderColor, lineWidth: 0.6)
              )
              .padding(10)
              .allowsHitTesting(false)
          }
        }
        .contentShape(Rectangle())
        .onTapGesture {
          showFullScreen = true
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(analysis.displayTitle). Double tap to open full screen and zoom.")
      }
    }
    .background(theme.surfaceColor)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(parseError != nil ? Color.red.opacity(0.38) : theme.borderColor, lineWidth: 0.75)
    )
    .shadow(color: theme.appearance.shadow.color.opacity(0.28), radius: 8, y: 3)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { newWidth in
      if newWidth > 1, abs(newWidth - cardWidth) > 1 {
        cardWidth = newWidth
      }
    }
    .onChange(of: source) { _, _ in
      parseError = nil
      diagramBounds = .zero
      showSource = false
      isSourceExpanded = false
    }
    .onChange(of: isComplete) { _, complete in
      if complete {
        parseError = nil
        diagramBounds = .zero
      }
    }
    .sheet(isPresented: $showFullScreen) {
      FullScreenMermaidView(source: source, analysis: analysis)
    }
  }

  private func header(
    analysis: MermaidDiagramSupport.Analysis,
    canRenderDiagram: Bool
  ) -> some View {
    HStack(spacing: 4) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(theme.accentColor)
        .accessibilityHidden(true)

      Text(analysis.headerLabel)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(theme.secondaryForegroundColor)
        .lineLimit(1)
        .padding(.leading, 3)

      Spacer(minLength: 8)

      if canRenderDiagram {
        Button(
          showSource ? "Show Diagram" : "Show Source",
          systemImage: showSource ? "eye" : "chevron.left.forwardslash.chevron.right"
        ) {
          withAnimation(.snappy(duration: 0.2)) {
            showSource.toggle()
          }
        }
        .labelStyle(.iconOnly)
        .frame(width: 36, height: 38)
        .contentShape(Rectangle())
      }

      Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
        showFullScreen = true
      }
      .labelStyle(.iconOnly)
      .frame(width: 36, height: 38)
      .contentShape(Rectangle())
      .disabled(!canRenderDiagram)
      .opacity(canRenderDiagram ? 1 : 0.35)

      CopyButton(text: source, accessibilityTitle: "Copy Mermaid Source", size: .compact)
    }
    .font(.system(size: 13, weight: .semibold))
    .foregroundStyle(theme.secondaryForegroundColor)
    .buttonStyle(.plain)
    .padding(.leading, 13)
    .padding(.trailing, 4)
    .frame(minHeight: 42)
    .background(theme.elevatedSurfaceColor)
  }

  private var streamingBody: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Rendering diagram…")
          .font(.caption.weight(.medium))
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      if !source.isEmpty {
        ScrollView([.horizontal, .vertical]) {
          Text(source)
            .font(.system(size: sourceFontSize, design: .monospaced))
            .foregroundStyle(theme.secondaryForegroundColor)
            .fixedSize(horizontal: true, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
  }

  private func unsupportedBody(kindName: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "info.circle.fill")
          .font(.subheadline)
          .foregroundStyle(theme.accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text("\(kindName) aren’t supported for preview yet")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.primaryForegroundColor)
          Text("You can still copy or inspect the Mermaid source below.")
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)

      Rectangle().fill(theme.borderColor).frame(height: 0.5)

      collapsibleSourceBody(content: source)
    }
  }

  private func errorBody(error: Error) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(Color.red)
          Text("Could not render this diagram")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.primaryForegroundColor)
        }
        Text(error.localizedDescription)
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)

      Rectangle().fill(theme.borderColor).frame(height: 0.5)

      collapsibleSourceBody(content: source)
    }
  }

  @ViewBuilder
  private func collapsibleSourceBody(content: String) -> some View {
    let preview = HighlightedCodeBlockSupport.preview(for: content, isExpanded: isSourceExpanded)

    VStack(spacing: 0) {
      ScrollView(.horizontal) {
        Text(preview.displayedContent)
          .font(.system(size: sourceFontSize, design: .monospaced))
          .foregroundStyle(theme.primaryForegroundColor)
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: true)
          .padding(14)
      }
      .scrollIndicators(.visible)

      if preview.isLong {
        Rectangle()
          .fill(theme.borderColor)
          .frame(height: 0.5)

        Button {
          withAnimation(.snappy(duration: 0.2)) { isSourceExpanded.toggle() }
        } label: {
          Label(
            preview.toggleLabel,
            systemImage: isSourceExpanded ? "chevron.up" : "chevron.down"
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
  }
}

private struct FullScreenMermaidView: View {
  private enum ViewMode {
    case diagram
    case source
  }

  private struct RenderKey: Equatable {
    let source: String
    let themeID: String
    let isDark: Bool
    let scale: Int
  }

  let source: String
  let analysis: MermaidDiagramSupport.Analysis

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.openURL) private var openURL
  @ScaledMetric(relativeTo: .callout) private var sourceFontSize: CGFloat = 14

  @State private var viewMode: ViewMode = .diagram
  @State private var renderedImage: UIImage?
  @State private var renderError: Error?
  @State private var isRendering = false
  @State private var isSavingToPhotos = false
  @State private var statusBanner: String?
  @State private var statusBannerRevision = 0
  @State private var saveErrorMessage: String?
  @State private var isPhotoPermissionDenied = false

  private var navigationTitle: String {
    if let title = analysis.title, !title.isEmpty {
      return title
    }
    return analysis.displayTitle
  }

  private var renderKey: RenderKey {
    RenderKey(
      source: analysis.renderSource,
      themeID: theme.id,
      isDark: colorScheme == .dark,
      scale: Int(max(displayScale, 3.0).rounded())
    )
  }

  var body: some View {
    NavigationStack {
      ZStack(alignment: .bottom) {
        Group {
          if viewMode == .source {
            sourceView
          } else if let renderedImage {
            ZoomableImageView(image: renderedImage)
              .ignoresSafeArea(edges: .bottom)
          } else if let renderError {
            ContentUnavailableView {
              Label("Diagram Error", systemImage: "exclamationmark.triangle")
            } description: {
              Text(renderError.localizedDescription)
            } actions: {
              Button("View Mermaid Source") {
                viewMode = .source
              }
              .buttonStyle(.borderedProminent)
              .tint(theme.accentColor)
            }
            .padding()
          } else if isRendering {
            VStack(spacing: 10) {
              ProgressView()
              Text("Preparing diagram…")
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            MermaidDiagramView(
              source: analysis.renderSource,
              theme: MermaidDiagramSupport.diagramTheme(
                from: theme,
                colorScheme: colorScheme,
                canvas: .fullScreen
              )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
          }
        }

        if let statusBanner {
          Label(statusBanner, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.primaryForegroundColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(theme.elevatedSurfaceColor, in: Capsule())
            .overlay(Capsule().stroke(theme.borderColor, lineWidth: 0.75))
            .shadow(color: theme.appearance.shadow.color.opacity(0.35), radius: 8, y: 3)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.easeInOut(duration: 0.2), value: statusBanner)
      .background(theme.backgroundColor.ignoresSafeArea())
      .navigationTitle(navigationTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", systemImage: "xmark") {
            dismiss()
          }
          .labelStyle(.iconOnly)
        }

        ToolbarItemGroup(placement: .primaryAction) {
          Button(
            viewMode == .diagram ? "View Source" : "View Diagram",
            systemImage: viewMode == .diagram ? "chevron.left.forwardslash.chevron.right" : "eye"
          ) {
            withAnimation(.snappy(duration: 0.2)) {
              viewMode = viewMode == .diagram ? .source : .diagram
            }
          }
          .labelStyle(.iconOnly)
          .accessibilityLabel(viewMode == .diagram ? "View Mermaid Source" : "View Rendered Diagram")

          if viewMode == .source {
            CopyButton(text: source, accessibilityTitle: "Copy Mermaid Source", size: .toolbar)
          } else if let renderedImage {
            if isSavingToPhotos {
              ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Saving to Photos")
            } else {
              Button(
                "Save to Photos",
                systemImage: statusBanner == "Saved to Photos" ? "checkmark" : "square.and.arrow.down"
              ) {
                Task { await saveToPhotos(renderedImage) }
              }
              .labelStyle(.iconOnly)
              .accessibilityLabel("Save Diagram to Photos")
            }
          }

          Menu {
            if let renderedImage {
              ShareLink(
                item: Image(uiImage: renderedImage),
                preview: SharePreview(navigationTitle, image: Image(uiImage: renderedImage))
              ) {
                Label("Share Image", systemImage: "photo")
              }
            }
            ShareLink(item: source) {
              Label("Share Mermaid Source", systemImage: "doc.plaintext")
            }
            Button("Copy Mermaid Source", systemImage: "doc.on.doc") {
              UIPasteboard.general.string = source
              UIImpactFeedbackGenerator(style: .light).impactOccurred()
              showStatusBanner("Copied Mermaid Source")
            }
          } label: {
            Image(systemName: "square.and.arrow.up")
          }
          .accessibilityLabel("Share or Copy Diagram")
        }
      }
      .task(id: renderKey) {
        await renderDiagram()
      }
      .task(id: statusBannerRevision) {
        guard statusBannerRevision > 0 else { return }
        try? await Task.sleep(for: .seconds(1.8))
        guard !Task.isCancelled else { return }
        statusBanner = nil
      }
      .alert(
        "Could Not Save Image",
        isPresented: Binding(
          get: { saveErrorMessage != nil },
          set: {
            if !$0 {
              saveErrorMessage = nil
              isPhotoPermissionDenied = false
            }
          }
        )
      ) {
        if isPhotoPermissionDenied,
          let settingsURL = URL(string: UIApplication.openSettingsURLString)
        {
          Button("Open Settings") {
            saveErrorMessage = nil
            isPhotoPermissionDenied = false
            openURL(settingsURL)
          }
        }
        Button("OK", role: .cancel) {
          saveErrorMessage = nil
          isPhotoPermissionDenied = false
        }
      } message: {
        Text(saveErrorMessage ?? "Unknown error")
      }
    }
    .tint(theme.accentColor)
  }

  private var sourceView: some View {
    ScrollView([.horizontal, .vertical]) {
      Text(source)
        .font(.system(size: sourceFontSize, design: .monospaced))
        .foregroundStyle(theme.primaryForegroundColor)
        .textSelection(.enabled)
        .fixedSize(horizontal: true, vertical: true)
        .padding(20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func renderDiagram() async {
    renderError = nil
    isRendering = true
    let diagramTheme = MermaidDiagramSupport.diagramTheme(
      from: theme,
      colorScheme: colorScheme,
      canvas: .fullScreen
    )
    let desiredScale = max(displayScale, 3.0)
    do {
      let image = try await MermaidDiagramSupport.renderImage(
        source: analysis.renderSource,
        theme: diagramTheme,
        desiredScale: desiredScale
      )
      guard !Task.isCancelled else { return }
      renderedImage = image
      isRendering = false
    } catch {
      guard !Task.isCancelled else { return }
      renderedImage = nil
      renderError = error
      isRendering = false
    }
  }

  private func saveToPhotos(_ image: UIImage) async {
    guard !isSavingToPhotos else { return }
    isSavingToPhotos = true
    do {
      try await LibraryPhotoWriter.save(image)
      isSavingToPhotos = false
      showStatusBanner("Saved to Photos")
    } catch {
      isSavingToPhotos = false
      isPhotoPermissionDenied = (error as? LibraryPhotoWriteError) == .permissionDenied
      saveErrorMessage = error.localizedDescription
    }
  }

  private func showStatusBanner(_ message: String) {
    statusBanner = message
    statusBannerRevision += 1
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
