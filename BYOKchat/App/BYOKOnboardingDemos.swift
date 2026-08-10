import AppFoundation
import SwiftUI

@MainActor
struct BYOKOnboardingChatDemo: View {
  let isSelected: Bool

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var phase = 0
  @State private var visibleWordCount = 0

  private let answer = "Costs fell, context grew, and reliability stayed roughly the same. The biggest change is cheaper long conversations."

  private var answerWords: [Substring] {
    answer.split(separator: " ")
  }

  private var visibleAnswer: String {
    answerWords.prefix(visibleWordCount).joined(separator: " ")
  }

  var body: some View {
    BYOKOnboardingDemoSurface {
      VStack(spacing: 9) {
        modelBar

        userMessage
          .opacity(phase >= 1 ? 1 : 0)
          .offset(x: phase >= 1 ? 0 : 18)

        assistantResponse
          .opacity(phase >= 2 ? 1 : 0)
          .offset(y: phase >= 2 ? 0 : 8)
      }
      .animation(.snappy(duration: 0.32), value: phase)
    }
    .task(id: isSelected) {
      await runLoop()
    }
  }

  private var modelBar: some View {
    HStack(spacing: 9) {
      Image(systemName: "sparkles")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(theme.accentColor)
        .frame(width: 32, height: 32)
        .background(theme.accentColor.opacity(0.11), in: Circle())

      VStack(alignment: .leading, spacing: 1) {
        Text("Claude Sonnet 4")
          .font(.subheadline.bold())
          .foregroundStyle(theme.primaryForegroundColor)
        Text("Anthropic")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
      }

      Spacer()

      Image(systemName: "chevron.down")
        .font(.caption2.bold())
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private var userMessage: some View {
    HStack {
      Spacer(minLength: 58)

      Text("What changed between these reports?")
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(theme.backgroundColor)
        .multilineTextAlignment(.trailing)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.accentColor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
  }

  private var assistantResponse: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Image(systemName: phase >= 3 ? "brain.head.profile.fill" : "ellipsis")
          .contentTransition(.symbolEffect(.replace))
        Text(phase >= 3 ? "Reasoned" : "Thinking…")
      }
      .font(.caption2.bold())
      .foregroundStyle(theme.secondaryForegroundColor)

      Text(visibleAnswer.isEmpty ? " " : visibleAnswer)
        .font(.system(size: 12.5))
        .foregroundStyle(theme.primaryForegroundColor)
        .lineSpacing(2)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)

      Label(
        phase >= 4 ? "Files compared" : "Reading reports…",
        systemImage: phase >= 4 ? "checkmark.circle.fill" : "doc.text.magnifyingglass"
      )
      .font(.caption2.bold())
      .foregroundStyle(theme.accentColor)
      .opacity(phase >= 3 ? 1 : 0)
    }
    .padding(11)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private func runLoop() async {
    guard isSelected else {
      reset()
      return
    }

    if reduceMotion {
      showFinalState()
      return
    }

    while !Task.isCancelled {
      reset()

      guard await pause(.milliseconds(260)) else { return }
      withAnimation { phase = 1 }

      guard await pause(.milliseconds(620)) else { return }
      withAnimation { phase = 2 }

      guard await pause(.milliseconds(520)) else { return }
      withAnimation { phase = 3 }

      for count in stride(from: 3, through: answerWords.count, by: 3) {
        guard await pause(.milliseconds(115)) else { return }
        visibleWordCount = min(count, answerWords.count)
      }
      visibleWordCount = answerWords.count

      withAnimation { phase = 4 }
      guard await pause(.seconds(1.7)) else { return }
    }
  }

  private func reset() {
    phase = 0
    visibleWordCount = 0
  }

  private func showFinalState() {
    phase = 4
    visibleWordCount = answerWords.count
  }
}

@MainActor
struct BYOKOnboardingProvidersDemo: View {
  let isSelected: Bool

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var connectedCount = 0
  @State private var showsDirectConnection = false

  private let providers = [
    DemoProvider(name: "Anthropic", detail: "Claude Sonnet 4", symbol: "sparkles"),
    DemoProvider(name: "OpenRouter", detail: "240+ models", symbol: "bolt.horizontal.fill"),
    DemoProvider(name: "Local Server", detail: "192.168.1.42", symbol: "network"),
  ]

  var body: some View {
    BYOKOnboardingDemoSurface {
      VStack(spacing: 10) {
        providerList
        directConnection
      }
      .animation(.snappy(duration: 0.34), value: connectedCount)
      .animation(.snappy(duration: 0.34), value: showsDirectConnection)
    }
    .task(id: isSelected) {
      await runLoop()
    }
  }

  private var providerList: some View {
    VStack(spacing: 0) {
      ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
        HStack(spacing: 10) {
          Image(systemName: provider.symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(theme.accentColor)
            .frame(width: 30, height: 30)
            .background(theme.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

          VStack(alignment: .leading, spacing: 1) {
            Text(provider.name)
              .font(.caption.bold())
              .foregroundStyle(theme.primaryForegroundColor)
            Text(provider.detail)
              .font(.caption2)
              .foregroundStyle(theme.secondaryForegroundColor)
              .lineLimit(1)
          }

          Spacer()

          Image(systemName: index < connectedCount ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(
              index < connectedCount
                ? theme.accentColor
                : theme.secondaryForegroundColor.opacity(0.28)
            )
            .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)

        if index < providers.count - 1 {
          Divider()
            .overlay(theme.borderColor)
            .padding(.leading, 51)
        }
      }
    }
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private var directConnection: some View {
    HStack(spacing: 9) {
      Image(systemName: "iphone")
        .foregroundStyle(theme.accentColor)

      HStack(spacing: 4) {
        ForEach(0..<4, id: \.self) { index in
          Capsule()
            .fill(theme.accentColor.opacity(showsDirectConnection ? 0.75 : 0.16))
            .frame(maxWidth: .infinity)
            .frame(height: 2)
            .scaleEffect(x: showsDirectConnection ? 1 : 0.3, anchor: .leading)
            .animation(
              .easeOut(duration: 0.28).delay(Double(index) * 0.04),
              value: showsDirectConnection
            )
        }
      }

      Image(systemName: "cloud.fill")
        .foregroundStyle(theme.accentColor)

      VStack(alignment: .leading, spacing: 1) {
        Text("Direct")
          .font(.caption.bold())
          .foregroundStyle(theme.primaryForegroundColor)
        Text("No proxy")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .padding(.horizontal, 10)
    .opacity(showsDirectConnection ? 1 : 0.45)
  }

  private func runLoop() async {
    guard isSelected else {
      reset()
      return
    }

    if reduceMotion {
      connectedCount = providers.count
      showsDirectConnection = true
      return
    }

    while !Task.isCancelled {
      reset()
      guard await pause(.milliseconds(300)) else { return }

      for count in 1...providers.count {
        withAnimation { connectedCount = count }
        guard await pause(.milliseconds(650)) else { return }
      }

      withAnimation { showsDirectConnection = true }
      guard await pause(.seconds(1.8)) else { return }
    }
  }

  private func reset() {
    connectedCount = 0
    showsDirectConnection = false
  }

  private struct DemoProvider {
    let name: String
    let detail: String
    let symbol: String
  }
}

@MainActor
struct BYOKOnboardingWorkspaceDemo: View {
  let isSelected: Bool

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var stage = 0
  @State private var toolRunning = false

  private let bars: [CGFloat] = [0.38, 0.62, 0.46, 0.82, 0.68]

  var body: some View {
    BYOKOnboardingDemoSurface {
      VStack(spacing: 9) {
        projectCard

        toolRow
          .opacity(stage >= 1 ? 1 : 0)
          .offset(y: stage >= 1 ? 0 : 7)

        usageRow
          .opacity(stage >= 3 ? 1 : 0)
          .offset(y: stage >= 3 ? 0 : 7)
      }
      .animation(.snappy(duration: 0.34), value: stage)
      .animation(.snappy(duration: 0.26), value: toolRunning)
    }
    .task(id: isSelected) {
      await runLoop()
    }
  }

  private var projectCard: some View {
    HStack(spacing: 10) {
      Image(systemName: "folder.fill")
        .foregroundStyle(theme.accentColor)
        .frame(width: 34, height: 34)
        .background(theme.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 1) {
        Text("Research")
          .font(.subheadline.bold())
          .foregroundStyle(theme.primaryForegroundColor)
        Text("12 conversations · Sonnet 4")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
      }

      Spacer()

      Image(systemName: "ellipsis")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .padding(11)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private var toolRow: some View {
    HStack(spacing: 9) {
      Image(systemName: toolRunning ? "arrow.trianglehead.2.clockwise.rotate.90" : stage >= 2 ? "checkmark.circle.fill" : "shippingbox.fill")
        .foregroundStyle(theme.accentColor)
        .contentTransition(.symbolEffect(.replace))

      VStack(alignment: .leading, spacing: 1) {
        Text("Search web")
          .font(.caption.bold())
          .foregroundStyle(theme.primaryForegroundColor)
        Text("MCP tool")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
      }

      Spacer()

      Text(toolRunning ? "Running" : stage >= 2 ? "Completed" : "Ready")
        .font(.caption2.bold())
        .foregroundStyle(theme.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.accentColor.opacity(0.10), in: Capsule())
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private var usageRow: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 1) {
        Text("$12.48")
          .font(.system(size: 18, weight: .bold, design: .rounded))
          .foregroundStyle(theme.primaryForegroundColor)
        Text("this month")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
      }

      HStack(alignment: .bottom, spacing: 5) {
        ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
          RoundedRectangle(cornerRadius: 3)
            .fill(index == bars.count - 2 ? theme.accentColor : theme.accentColor.opacity(0.32))
            .frame(maxWidth: .infinity)
            .frame(height: 34 * height)
            .scaleEffect(y: stage >= 3 ? 1 : 0.08, anchor: .bottom)
            .animation(.easeOut(duration: 0.38).delay(Double(index) * 0.04), value: stage)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 35, alignment: .bottom)

      VStack(alignment: .trailing, spacing: 1) {
        Text("842")
          .font(.caption.bold())
          .foregroundStyle(theme.primaryForegroundColor)
        Text("requests")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .padding(11)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private func runLoop() async {
    guard isSelected else {
      reset()
      return
    }

    if reduceMotion {
      stage = 3
      toolRunning = false
      return
    }

    while !Task.isCancelled {
      reset()
      guard await pause(.milliseconds(300)) else { return }

      withAnimation { stage = 1 }
      guard await pause(.milliseconds(620)) else { return }

      toolRunning = true
      guard await pause(.milliseconds(800)) else { return }
      toolRunning = false
      withAnimation { stage = 2 }

      guard await pause(.milliseconds(500)) else { return }
      withAnimation { stage = 3 }

      guard await pause(.seconds(1.8)) else { return }
    }
  }

  private func reset() {
    stage = 0
    toolRunning = false
  }
}

private struct BYOKOnboardingDemoSurface<Content: View>: View {
  @Environment(\.appFoundationTheme) private var theme

  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(11)
      .frame(maxWidth: .infinity)
      .background(
        theme.surfaceColor.opacity(0.92),
        in: RoundedRectangle(cornerRadius: 24, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .strokeBorder(theme.borderColor)
      }
      .shadow(color: theme.appearance.shadow.color.opacity(0.42), radius: 16, y: 8)
  }
}

@MainActor
private func pause(_ duration: Duration) async -> Bool {
  do {
    try await Task.sleep(for: duration)
    return !Task.isCancelled
  } catch {
    return false
  }
}
