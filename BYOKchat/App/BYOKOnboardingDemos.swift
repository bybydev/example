import AppFoundation
import SwiftUI

private struct OnboardingDemoLoopID: Equatable {
  let isSelected: Bool
  let reduceMotion: Bool
  let isActive: Bool
}

@MainActor
struct BYOKOnboardingChatDemo: View {
  let isSelected: Bool

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  @State private var phase = 0
  @State private var visibleWordCount = 0
  @State private var loopOpacity = 1.0

  private let answer =
    "Costs fell, context grew, and reliability held steady. The biggest win is cheaper long conversations."

  private var answerWords: [Substring] {
    answer.split(separator: " ")
  }

  private var visibleAnswer: String {
    answerWords.prefix(visibleWordCount).joined(separator: " ")
  }

  private var loopID: OnboardingDemoLoopID {
    OnboardingDemoLoopID(
      isSelected: isSelected,
      reduceMotion: reduceMotion,
      isActive: scenePhase == .active
    )
  }

  var body: some View {
    VStack(spacing: 9) {
      userMessage
        .opacity(phase >= 1 ? 1 : 0)
        .offset(x: phase >= 1 ? 0 : 14)

      assistantResponse
        .opacity(phase >= 2 ? 1 : 0)
        .offset(y: phase >= 2 ? 0 : 8)

      composerModelPill
    }
    .frame(maxWidth: .infinity)
    .opacity(loopOpacity)
    .animation(.snappy(duration: 0.32), value: phase)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Preview of a chat showing a question, file comparison, reasoning, and a streaming response from Claude Sonnet 4.5."
    )
    .task(id: loopID) {
      await runLoop()
    }
  }

  private var userMessage: some View {
    HStack {
      Spacer(minLength: 48)

      Text("What changed between these reports?")
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(theme.primaryForegroundColor)
        .multilineTextAlignment(.trailing)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          theme.accentColor.opacity(0.16),
          in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 15, style: .continuous)
            .strokeBorder(theme.accentColor.opacity(0.32))
        }
    }
  }

  private var assistantResponse: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Label(
          phase >= 3 ? "Reasoned" : "Thinking…",
          systemImage: phase >= 3 ? "brain.head.profile.fill" : "ellipsis"
        )
        .contentTransition(.symbolEffect(.replace))
        .foregroundStyle(theme.secondaryForegroundColor)

        Spacer(minLength: 4)

        Label(
          phase >= 3 ? "Files compared" : "Reading reports…",
          systemImage: phase >= 3 ? "checkmark.circle.fill" : "doc.text.magnifyingglass"
        )
        .contentTransition(.symbolEffect(.replace))
        .foregroundStyle(theme.accentColor)
      }
      .font(.caption2.bold())
      .lineLimit(1)

      // Reserve the full wrapped answer height invisibly so streaming text never
      // shifts the card or headline vertically on any width or Dynamic Type size.
      Text(answer)
        .font(.system(size: 12.5))
        .lineSpacing(2)
        .opacity(0)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
          Text(visibleAnswer)
            .font(.system(size: 12.5))
            .foregroundStyle(theme.primaryForegroundColor)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    .padding(11)
    .background(
      theme.elevatedSurfaceColor,
      in: RoundedRectangle(cornerRadius: 17, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private var composerModelPill: some View {
    HStack(spacing: 8) {
      Image(systemName: "sparkles")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(theme.accentColor)
        .frame(width: 28, height: 28)
        .background(theme.accentColor.opacity(0.11), in: Circle())

      VStack(alignment: .leading, spacing: 1) {
        Text("Claude Sonnet 4.5")
          .font(.caption.bold())
          .foregroundStyle(theme.primaryForegroundColor)
          .lineLimit(1)
        Text("Anthropic · Reasoning: Medium")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
          .lineLimit(1)
      }

      Spacer(minLength: 6)

      Image(systemName: "chevron.up.chevron.down")
        .font(.caption2.bold())
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      theme.elevatedSurfaceColor,
      in: RoundedRectangle(cornerRadius: 15, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 15, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private func runLoop() async {
    guard isSelected else {
      reset()
      loopOpacity = 1
      return
    }

    if reduceMotion {
      showFinalState()
      loopOpacity = 1
      return
    }

    guard scenePhase == .active else { return }

    var isFirstCycle = true
    while !Task.isCancelled {
      if !isFirstCycle {
        withAnimation(.easeOut(duration: 0.22)) { loopOpacity = 0 }
        guard await pause(.milliseconds(240)) else { return }
      }
      isFirstCycle = false

      var resetTransaction = Transaction()
      resetTransaction.disablesAnimations = true
      withTransaction(resetTransaction) {
        reset()
      }
      if loopOpacity < 1 {
        withAnimation(.easeIn(duration: 0.2)) { loopOpacity = 1 }
      }

      guard await pause(.milliseconds(240)) else { return }
      withAnimation { phase = 1 }

      guard await pause(.milliseconds(540)) else { return }
      withAnimation { phase = 2 }

      guard await pause(.milliseconds(700)) else { return }
      withAnimation { phase = 3 }

      for count in stride(from: 3, through: answerWords.count, by: 3) {
        guard await pause(.milliseconds(115)) else { return }
        visibleWordCount = min(count, answerWords.count)
      }
      visibleWordCount = answerWords.count

      guard await pause(.seconds(2.0)) else { return }
    }
  }

  private func reset() {
    phase = 0
    visibleWordCount = 0
  }

  private func showFinalState() {
    phase = 3
    visibleWordCount = answerWords.count
  }
}

@MainActor
struct BYOKOnboardingProvidersDemo: View {
  let isSelected: Bool

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  @State private var connectedCount = 0
  @State private var showsDirectConnection = false
  @State private var loopOpacity = 1.0

  private let providers = [
    DemoProvider(name: "Anthropic", detail: "Claude Sonnet 4.5", symbol: "sparkles"),
    DemoProvider(name: "OpenRouter", detail: "Multi-provider catalog", symbol: "bolt.horizontal.fill"),
    DemoProvider(name: "Ollama & LM Studio", detail: "Local network servers", symbol: "desktopcomputer"),
  ]

  private var loopID: OnboardingDemoLoopID {
    OnboardingDemoLoopID(
      isSelected: isSelected,
      reduceMotion: reduceMotion,
      isActive: scenePhase == .active
    )
  }

  var body: some View {
    VStack(spacing: 10) {
      providerList
      directConnection
    }
    .frame(maxWidth: .infinity)
    .opacity(loopOpacity)
    .animation(.snappy(duration: 0.34), value: connectedCount)
    .animation(.snappy(duration: 0.34), value: showsDirectConnection)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Preview of connected AI providers including Anthropic, OpenRouter, and local servers with Keychain-stored API keys and direct requests."
    )
    .task(id: loopID) {
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
              .lineLimit(1)
            Text(provider.detail)
              .font(.caption2)
              .foregroundStyle(theme.secondaryForegroundColor)
              .lineLimit(1)
          }

          Spacer(minLength: 6)

          Image(systemName: index < connectedCount ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(
              index < connectedCount
                ? theme.accentColor
                : theme.secondaryForegroundColor.opacity(0.28)
            )
            .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)

        if index < providers.count - 1 {
          Divider()
            .overlay(theme.borderColor)
            .padding(.leading, 51)
        }
      }
    }
    .background(
      theme.elevatedSurfaceColor,
      in: RoundedRectangle(cornerRadius: 17, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private var directConnection: some View {
    HStack(spacing: 9) {
      Image(systemName: "lock.shield.fill")
        .foregroundStyle(theme.accentColor)

      HStack(spacing: 4) {
        ForEach(0..<4, id: \.self) { index in
          Capsule()
            .fill(theme.accentColor.opacity(showsDirectConnection ? 0.78 : 0.16))
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
        Text("Keychain · Direct")
          .font(.caption.bold())
          .foregroundStyle(theme.primaryForegroundColor)
          .lineLimit(1)
        Text("No proxy server")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(
      theme.elevatedSurfaceColor,
      in: RoundedRectangle(cornerRadius: 15, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 15, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
    .opacity(showsDirectConnection ? 1 : 0.52)
  }

  private func runLoop() async {
    guard isSelected else {
      reset()
      loopOpacity = 1
      return
    }

    if reduceMotion {
      connectedCount = providers.count
      showsDirectConnection = true
      loopOpacity = 1
      return
    }

    guard scenePhase == .active else { return }

    var isFirstCycle = true
    while !Task.isCancelled {
      if !isFirstCycle {
        withAnimation(.easeOut(duration: 0.22)) { loopOpacity = 0 }
        guard await pause(.milliseconds(240)) else { return }
      }
      isFirstCycle = false

      var resetTransaction = Transaction()
      resetTransaction.disablesAnimations = true
      withTransaction(resetTransaction) {
        reset()
      }
      if loopOpacity < 1 {
        withAnimation(.easeIn(duration: 0.2)) { loopOpacity = 1 }
      }

      guard await pause(.milliseconds(280)) else { return }

      for count in 1...providers.count {
        withAnimation { connectedCount = count }
        guard await pause(.milliseconds(580)) else { return }
      }

      withAnimation { showsDirectConnection = true }
      guard await pause(.seconds(2.0)) else { return }
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
  @Environment(\.scenePhase) private var scenePhase

  @State private var stage = 0
  @State private var toolRunning = false
  @State private var loopOpacity = 1.0

  private var loopID: OnboardingDemoLoopID {
    OnboardingDemoLoopID(
      isSelected: isSelected,
      reduceMotion: reduceMotion,
      isActive: scenePhase == .active
    )
  }

  var body: some View {
    VStack(spacing: 9) {
      projectCard

      toolRow
        .opacity(stage >= 1 ? 1 : 0)
        .offset(y: stage >= 1 ? 0 : 7)

      usageRow
        .opacity(stage >= 3 ? 1 : 0)
        .offset(y: stage >= 3 ? 0 : 7)
    }
    .frame(maxWidth: .infinity)
    .opacity(loopOpacity)
    .animation(.snappy(duration: 0.34), value: stage)
    .animation(.snappy(duration: 0.26), value: toolRunning)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Preview of workspace features including a Research project, an approved MCP tool call, and on-device spend, latency, and reliability analytics."
    )
    .task(id: loopID) {
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
          .lineLimit(1)
        Text("12 chats · Claude Sonnet 4.5")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
          .lineLimit(1)
      }

      Spacer(minLength: 6)

      Text("3 files")
        .font(.caption2.weight(.medium))
        .foregroundStyle(theme.secondaryForegroundColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(theme.surfaceColor, in: Capsule())
    }
    .padding(11)
    .background(
      theme.elevatedSurfaceColor,
      in: RoundedRectangle(cornerRadius: 17, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private var toolRow: some View {
    HStack(spacing: 9) {
      Image(
        systemName: toolRunning
          ? "arrow.trianglehead.2.clockwise.rotate.90"
          : stage >= 2 ? "checkmark.circle.fill" : "wrench.and.screwdriver.fill"
      )
      .foregroundStyle(theme.accentColor)
      .contentTransition(.symbolEffect(.replace))
      .symbolEffect(.rotate, isActive: toolRunning && !reduceMotion)

      VStack(alignment: .leading, spacing: 1) {
        Text("Search web")
          .font(.caption.bold())
          .foregroundStyle(theme.primaryForegroundColor)
          .lineLimit(1)
        Text("MCP tool · Ask before running")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
          .lineLimit(1)
      }

      Spacer(minLength: 6)

      Text(toolRunning ? "Running" : stage >= 2 ? "Approved" : "Ready")
        .font(.caption2.bold())
        .foregroundStyle(theme.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.accentColor.opacity(0.10), in: Capsule())
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(
      theme.elevatedSurfaceColor,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private var usageRow: some View {
    HStack(spacing: 0) {
      usageMetric(value: "$12.48", label: "Spend")
      Divider()
        .frame(height: 28)
        .overlay(theme.borderColor)
      usageMetric(value: "340 ms", label: "Median TTFT")
      Divider()
        .frame(height: 28)
        .overlay(theme.borderColor)
      usageMetric(value: "99.4%", label: "Success")
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 6)
    .background(
      theme.elevatedSurfaceColor,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }

  private func usageMetric(value: String, label: String) -> some View {
    VStack(spacing: 2) {
      Text(value)
        .font(.system(size: 14, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(theme.primaryForegroundColor)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Text(label)
        .font(.caption2)
        .foregroundStyle(theme.secondaryForegroundColor)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
  }

  private func runLoop() async {
    guard isSelected else {
      reset()
      loopOpacity = 1
      return
    }

    if reduceMotion {
      stage = 3
      toolRunning = false
      loopOpacity = 1
      return
    }

    guard scenePhase == .active else { return }

    var isFirstCycle = true
    while !Task.isCancelled {
      if !isFirstCycle {
        withAnimation(.easeOut(duration: 0.22)) { loopOpacity = 0 }
        guard await pause(.milliseconds(240)) else { return }
      }
      isFirstCycle = false

      var resetTransaction = Transaction()
      resetTransaction.disablesAnimations = true
      withTransaction(resetTransaction) {
        reset()
      }
      if loopOpacity < 1 {
        withAnimation(.easeIn(duration: 0.2)) { loopOpacity = 1 }
      }

      guard await pause(.milliseconds(280)) else { return }

      withAnimation { stage = 1 }
      guard await pause(.milliseconds(580)) else { return }

      toolRunning = true
      guard await pause(.milliseconds(820)) else { return }
      toolRunning = false
      withAnimation { stage = 2 }

      guard await pause(.milliseconds(480)) else { return }
      withAnimation { stage = 3 }

      guard await pause(.seconds(2.0)) else { return }
    }
  }

  private func reset() {
    stage = 0
    toolRunning = false
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
