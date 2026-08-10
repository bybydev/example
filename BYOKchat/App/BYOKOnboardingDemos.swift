import AppFoundation
import SwiftUI

@MainActor
struct BYOKOnboardingChatDemo: View {
  let isSelected: Bool

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var phase = 0
  @State private var visibleWordCount = 0
  @State private var composerPulse = false

  private let answer = "The new report cuts inference cost, expands the context window, and keeps reliability roughly unchanged. The largest practical difference is lower cost for long conversations."

  private var answerWords: [Substring] {
    answer.split(separator: " ")
  }

  private var visibleAnswer: String {
    answerWords.prefix(visibleWordCount).joined(separator: " ")
  }

  var body: some View {
    BYOKOnboardingDemoSurface {
      VStack(spacing: 10) {
        modelBar
          .opacity(phase >= 1 ? 1 : 0)
          .offset(y: phase >= 1 ? 0 : -8)

        userMessage
          .opacity(phase >= 2 ? 1 : 0)
          .offset(x: phase >= 2 ? 0 : 24)

        assistantResponse
          .opacity(phase >= 3 ? 1 : 0)
          .offset(y: phase >= 3 ? 0 : 10)

        composer
      }
      .animation(.snappy(duration: 0.34), value: phase)
    }
    .task(id: isSelected) {
      await runLoop()
    }
  }

  private var modelBar: some View {
    HStack(spacing: 10) {
      Image(systemName: "sparkles")
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(theme.accentColor)
        .frame(width: 34, height: 34)
        .background(theme.accentColor.opacity(0.12), in: Circle())

      VStack(alignment: .leading, spacing: 1) {
        Text("Claude Sonnet 4")
          .font(.subheadline.bold())
          .foregroundStyle(theme.primaryForegroundColor)
        Text("Anthropic · Personal")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
      }

      Spacer()

      Label("3 tools", systemImage: "shippingbox.fill")
        .font(.caption2.bold())
        .foregroundStyle(theme.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(theme.accentColor.opacity(0.10), in: Capsule())
    }
    .padding(11)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private var userMessage: some View {
    HStack {
      Spacer(minLength: 54)

      VStack(alignment: .trailing, spacing: 6) {
        HStack(spacing: 5) {
          Label("report-q2.pdf", systemImage: "doc.fill")
          Label("report-q3.pdf", systemImage: "doc.fill")
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(theme.secondaryForegroundColor)

        Text("Compare these two reports and tell me what actually changed.")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(theme.backgroundColor)
          .multilineTextAlignment(.trailing)
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .background(theme.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
    }
  }

  private var assistantResponse: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: phase >= 4 ? "brain.head.profile.fill" : "ellipsis")
          .contentTransition(.symbolEffect(.replace))
        Text(phase >= 4 ? "Reasoned for 8s" : "Thinking…")
      }
      .font(.caption2.bold())
      .foregroundStyle(theme.secondaryForegroundColor)

      Text(visibleAnswer.isEmpty ? " " : visibleAnswer)
        .font(.system(size: 12.5, weight: .regular))
        .foregroundStyle(theme.primaryForegroundColor)
        .lineSpacing(2)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .contentTransition(.numericText())

      HStack(spacing: 8) {
        Image(systemName: phase >= 5 ? "checkmark.circle.fill" : "doc.text.magnifyingglass")
          .foregroundStyle(theme.accentColor)
          .contentTransition(.symbolEffect(.replace))

        VStack(alignment: .leading, spacing: 1) {
          Text("Read attached files")
            .font(.caption.bold())
          Text(phase >= 5 ? "Completed" : "Comparing 2 reports…")
            .font(.caption2)
            .foregroundStyle(theme.secondaryForegroundColor)
        }

        Spacer()
      }
      .opacity(phase >= 4 ? 1 : 0)
      .offset(y: phase >= 4 ? 0 : 8)
    }
    .padding(12)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private var composer: some View {
    HStack(spacing: 9) {
      Image(systemName: "plus")
      Text("Message Claude Sonnet 4")
        .lineLimit(1)
      Spacer()
      Image(systemName: "mic.fill")
      Image(systemName: "arrow.up.circle.fill")
        .font(.title3)
        .foregroundStyle(theme.accentColor)
    }
    .font(.caption)
    .foregroundStyle(theme.secondaryForegroundColor)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .strokeBorder(
          composerPulse ? theme.accentColor.opacity(0.62) : theme.borderColor,
          lineWidth: composerPulse ? 1.4 : 1
        )
    }
    .shadow(
      color: composerPulse ? theme.accentColor.opacity(0.20) : .clear,
      radius: composerPulse ? 12 : 0
    )
    .animation(.easeInOut(duration: 0.8), value: composerPulse)
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

      guard await pause(.milliseconds(180)) else { return }
      withAnimation { phase = 1 }

      guard await pause(.milliseconds(450)) else { return }
      withAnimation { phase = 2 }

      guard await pause(.milliseconds(620)) else { return }
      withAnimation { phase = 3 }

      guard await pause(.milliseconds(520)) else { return }
      withAnimation { phase = 4 }

      for count in stride(from: 4, through: answerWords.count, by: 4) {
        guard await pause(.milliseconds(105)) else { return }
        visibleWordCount = min(count, answerWords.count)
      }
      visibleWordCount = answerWords.count

      withAnimation { phase = 5 }
      guard await pause(.milliseconds(480)) else { return }

      composerPulse = true
      guard await pause(.milliseconds(720)) else { return }
      composerPulse = false

      guard await pause(.seconds(1.2)) else { return }
    }
  }

  private func reset() {
    phase = 0
    visibleWordCount = 0
    composerPulse = false
  }

  private func showFinalState() {
    phase = 5
    visibleWordCount = answerWords.count
    composerPulse = false
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
    DemoProvider(name: "OpenRouter", detail: "240+ models", symbol: "bolt.horizontal.fill"),
    DemoProvider(name: "Anthropic", detail: "Claude Sonnet 4", symbol: "sparkles"),
    DemoProvider(name: "Gemini", detail: "Gemini 2.5 Pro", symbol: "diamond.fill"),
    DemoProvider(name: "Local Server", detail: "192.168.1.42", symbol: "network"),
  ]

  private var selectedModel: String {
    switch connectedCount {
    case 0, 1: "Claude Sonnet 4"
    case 2: "Gemini 2.5 Pro"
    case 3: "DeepSeek V3"
    default: "Qwen3 30B · Local"
    }
  }

  var body: some View {
    BYOKOnboardingDemoSurface {
      VStack(spacing: 11) {
        LazyVGrid(
          columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
          spacing: 10
        ) {
          ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
            providerCard(provider, isConnected: index < connectedCount)
          }
        }

        HStack(spacing: 10) {
          Image(systemName: "cpu.fill")
            .foregroundStyle(theme.accentColor)
            .frame(width: 30, height: 30)
            .background(theme.accentColor.opacity(0.10), in: Circle())

          VStack(alignment: .leading, spacing: 2) {
            Text("Current model")
              .font(.caption2)
              .foregroundStyle(theme.secondaryForegroundColor)
            Text(selectedModel)
              .font(.subheadline.bold())
              .foregroundStyle(theme.primaryForegroundColor)
              .contentTransition(.numericText())
          }

          Spacer()

          Image(systemName: "chevron.up.chevron.down")
            .font(.caption.bold())
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .padding(11)
        .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 17, style: .continuous)
            .strokeBorder(theme.borderColor)
        }

        HStack(spacing: 11) {
          Image(systemName: "iphone")
          connectionLine
          Image(systemName: "cloud.fill")
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(theme.accentColor)
        .padding(.top, 1)
        .opacity(showsDirectConnection ? 1 : 0.25)

        VStack(spacing: 2) {
          Text("Direct connection")
            .font(.caption.bold())
            .foregroundStyle(theme.primaryForegroundColor)
          Text("No BYOK account. No proxy.")
            .font(.caption2)
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .opacity(showsDirectConnection ? 1 : 0)
        .offset(y: showsDirectConnection ? 0 : 6)
      }
      .animation(.snappy(duration: 0.38), value: connectedCount)
      .animation(.snappy(duration: 0.38), value: showsDirectConnection)
    }
    .task(id: isSelected) {
      await runLoop()
    }
  }

  private func providerCard(_ provider: DemoProvider, isConnected: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: provider.symbol)
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(theme.accentColor)
          .frame(width: 34, height: 34)
          .background(theme.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))

        Spacer()

        Image(systemName: isConnected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isConnected ? theme.accentColor : theme.secondaryForegroundColor.opacity(0.35))
          .contentTransition(.symbolEffect(.replace))
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(provider.name)
          .font(.caption.bold())
          .foregroundStyle(theme.primaryForegroundColor)
        Text(provider.detail)
          .font(.system(size: 9.5, weight: .medium))
          .foregroundStyle(theme.secondaryForegroundColor)
          .lineLimit(1)
      }
    }
    .padding(11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .strokeBorder(isConnected ? theme.accentColor.opacity(0.34) : theme.borderColor)
    }
    .scaleEffect(isConnected ? 1 : 0.975)
  }

  private var connectionLine: some View {
    HStack(spacing: 4) {
      ForEach(0..<5, id: \.self) { index in
        Capsule()
          .fill(theme.accentColor.opacity(showsDirectConnection ? 0.82 : 0.20))
          .frame(maxWidth: .infinity)
          .frame(height: 2)
          .scaleEffect(x: showsDirectConnection ? 1 : 0.35, anchor: .leading)
          .animation(.easeOut(duration: 0.32).delay(Double(index) * 0.045), value: showsDirectConnection)
      }
    }
    .frame(maxWidth: .infinity)
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
      guard await pause(.milliseconds(260)) else { return }

      for count in 1...providers.count {
        withAnimation { connectedCount = count }
        guard await pause(.milliseconds(620)) else { return }
      }

      guard await pause(.milliseconds(320)) else { return }
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

  private let bars: [CGFloat] = [0.42, 0.58, 0.36, 0.72, 0.63, 0.88, 0.76]

  var body: some View {
    BYOKOnboardingDemoSurface {
      VStack(spacing: 10) {
        projectHeader

        recentChat
          .opacity(stage >= 1 ? 1 : 0)
          .offset(x: stage >= 1 ? 0 : 18)

        toolCard
          .opacity(stage >= 2 ? 1 : 0)
          .offset(y: stage >= 2 ? 0 : 10)

        analyticsCard
          .opacity(stage >= 4 ? 1 : 0)
          .offset(y: stage >= 4 ? 0 : 10)
      }
      .animation(.snappy(duration: 0.36), value: stage)
      .animation(.snappy(duration: 0.28), value: toolRunning)
    }
    .task(id: isSelected) {
      await runLoop()
    }
  }

  private var projectHeader: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 10) {
        Image(systemName: "folder.fill")
          .foregroundStyle(theme.accentColor)
          .frame(width: 36, height: 36)
          .background(theme.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))

        VStack(alignment: .leading, spacing: 1) {
          Text("Research")
            .font(.headline)
            .foregroundStyle(theme.primaryForegroundColor)
          Text("12 conversations")
            .font(.caption2)
            .foregroundStyle(theme.secondaryForegroundColor)
        }

        Spacer()

        Image(systemName: "ellipsis.circle")
          .foregroundStyle(theme.secondaryForegroundColor)
      }

      HStack(spacing: 6) {
        BYOKOnboardingDemoChip(text: "Sonnet 4", systemImage: "sparkles")
        BYOKOnboardingDemoChip(text: "3 tools", systemImage: "shippingbox.fill")
        BYOKOnboardingDemoChip(text: "6 files", systemImage: "paperclip")
      }
    }
    .padding(11)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private var recentChat: some View {
    HStack(spacing: 10) {
      Image(systemName: "bubble.left.fill")
        .foregroundStyle(theme.accentColor)
        .frame(width: 30)

      VStack(alignment: .leading, spacing: 1) {
        Text("Compare model pricing")
          .font(.caption.bold())
          .foregroundStyle(theme.primaryForegroundColor)
        Text("Just now · Research")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
      }

      Spacer()

      Image(systemName: "chevron.right")
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

  private var toolCard: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Label("MCP Tools", systemImage: "shippingbox.fill")
          .font(.caption.bold())
          .foregroundStyle(theme.primaryForegroundColor)
        Spacer()
        Text("Per chat")
          .font(.caption2.bold())
          .foregroundStyle(theme.secondaryForegroundColor)
      }

      HStack(spacing: 8) {
        Image(systemName: toolRunning ? "arrow.trianglehead.2.clockwise.rotate.90" : stage >= 3 ? "checkmark.circle.fill" : "magnifyingglass")
          .foregroundStyle(theme.accentColor)
          .contentTransition(.symbolEffect(.replace))

        Text("Search web")
          .font(.caption.bold())
          .foregroundStyle(theme.primaryForegroundColor)

        Spacer()

        Text(toolRunning ? "Running" : stage >= 3 ? "Completed" : "Always")
          .font(.caption2.bold())
          .foregroundStyle(theme.accentColor)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(theme.accentColor.opacity(0.10), in: Capsule())
      }

      HStack(spacing: 8) {
        Image(systemName: "doc.text.fill")
          .foregroundStyle(theme.accentColor)
        Text("Read files")
          .font(.caption.bold())
          .foregroundStyle(theme.primaryForegroundColor)
        Spacer()
        Text("Ask")
          .font(.caption2.bold())
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .padding(11)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private var analyticsCard: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("$12.48")
          .font(.system(size: 19, weight: .bold, design: .rounded))
          .foregroundStyle(theme.primaryForegroundColor)
        Text("842 requests")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .frame(width: 82, alignment: .leading)

      HStack(alignment: .bottom, spacing: 4) {
        ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
          RoundedRectangle(cornerRadius: 3)
            .fill(index == bars.count - 2 ? theme.accentColor : theme.accentColor.opacity(0.34))
            .frame(maxWidth: .infinity)
            .frame(height: 44 * height)
            .scaleEffect(y: stage >= 4 ? 1 : 0.08, anchor: .bottom)
            .animation(.easeOut(duration: 0.42).delay(Double(index) * 0.045), value: stage)
        }
      }
      .frame(height: 46, alignment: .bottom)

      VStack(alignment: .trailing, spacing: 2) {
        Text("1.2s")
          .font(.caption.bold())
          .foregroundStyle(theme.primaryForegroundColor)
        Text("Anthropic")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(theme.secondaryForegroundColor)
      }
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
      stage = 4
      toolRunning = false
      return
    }

    while !Task.isCancelled {
      reset()
      guard await pause(.milliseconds(300)) else { return }

      withAnimation { stage = 1 }
      guard await pause(.milliseconds(650)) else { return }

      withAnimation { stage = 2 }
      guard await pause(.milliseconds(550)) else { return }

      toolRunning = true
      guard await pause(.milliseconds(850)) else { return }
      toolRunning = false
      withAnimation { stage = 3 }

      guard await pause(.milliseconds(520)) else { return }
      withAnimation { stage = 4 }

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
      .padding(13)
      .frame(maxWidth: .infinity)
      .background(
        theme.surfaceColor.opacity(0.92),
        in: RoundedRectangle(cornerRadius: 26, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .strokeBorder(theme.borderColor)
      }
      .shadow(color: theme.appearance.shadow.color.opacity(0.54), radius: 22, y: 12)
  }
}

private struct BYOKOnboardingDemoChip: View {
  let text: String
  let systemImage: String

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.system(size: 9.5, weight: .bold))
      .foregroundStyle(theme.accentColor)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(theme.accentColor.opacity(0.10), in: Capsule())
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
