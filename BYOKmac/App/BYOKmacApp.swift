import AppKit
import Foundation
import MacAppFoundation
import SwiftUI

enum BYOKmacWindowID {
  static let main = "main"
  static let onboarding = "byokchat.onboarding"
  #if DEBUG
  static let developerTools = "byokchat.developer-tools"
  #endif
}

@main
@MainActor
struct BYOKmacApp: App {
  @Environment(\.openWindow) private var openWindow
  @State private var model = MacAppModel()
  @State private var proGateCenter = MacProGateCenter.shared
  @State private var settingsRouter = MacSettingsRouter.shared
  @State private var onboarding = OnboardingState(
    id: "byokchat",
    stepCount: 3
  )

  private let purchases = MacPurchaseStore.manager
  private let analytics = MacAppAnalytics.client

  var body: some Scene {
    Window("BYOKchat", id: BYOKmacWindowID.main) {
      MacStartupView(model: model)
        .frame(minWidth: 760, minHeight: 520)
        .ignoresSafeArea(edges: .top)
        .background(MacMainWindowConfigurator())
        .macAppTheme(model.themeStore, purchaseManager: purchases)
        .environment(purchases)
        .environment(proGateCenter)
        .environment(settingsRouter)
        .managesPurchases(purchases)
        .managesAnalytics(analytics)
        .managesMacProAccess(
          model: model,
          purchases: purchases,
          proGateCenter: proGateCenter
        )
        .task {
          await model.start()
        }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1_180, height: 760)
    .windowResizability(.contentMinSize)
    .defaultLaunchBehavior(onboarding.mainWindowLaunchBehavior)
    .commands {
      MacCommands(model: model)

      #if DEBUG
      CommandMenu("Developer") {
        Button("Open Developer Tools…") {
          openWindow(id: BYOKmacWindowID.developerTools)
        }
        .keyboardShortcut("d", modifiers: [.command, .option])

        Button("Foundation Developer Tools…") {
          openWindow(id: MacAppFoundationDeveloperTools.windowID)
        }

        Divider()

        Button("Replay Onboarding") {
          onboarding.restart()
          openWindow(id: BYOKmacWindowID.onboarding)
        }

        Divider()

        Button("Use Simulated Purchases") {
          UserDefaults.standard.set(true, forKey: MacPurchaseStore.simulatedModeKey)
          Task { await purchases.setSimulatedPurchasesEnabled(true) }
        }

        Button("Use StoreKit") {
          UserDefaults.standard.set(false, forKey: MacPurchaseStore.simulatedModeKey)
          Task { await purchases.setSimulatedPurchasesEnabled(false) }
        }

        Button("Reset Simulated Purchases", role: .destructive) {
          UserDefaults.standard.set(true, forKey: MacPurchaseStore.simulatedModeKey)
          Task {
            await purchases.setSimulatedPurchasesEnabled(true)
            await purchases.resetSimulatedPurchases()
          }
        }
      }
      #endif
    }

    OnboardingWindow(
      "Welcome to BYOKchat",
      id: BYOKmacWindowID.onboarding,
      state: onboarding,
      defaultWidth: 720,
      defaultHeight: 590
    ) {
      MacBYOKOnboardingView(onboarding: onboarding)
        .macAppTheme(model.themeStore, purchaseManager: purchases)
        .managesAnalytics(analytics)
    }
    .windowStyle(.hiddenTitleBar)

    Window("BYOK Pro", id: MacWindowID.proPaywall) {
      MacProPaywallWindow(purchaseManager: purchases)
        .macAppTheme(model.themeStore, purchaseManager: purchases)
        .environment(purchases)
        .managesAnalytics(analytics)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 860, height: 600)
    .windowResizability(.contentSize)

    #if DEBUG
    Window("Developer Tools", id: BYOKmacWindowID.developerTools) {
      MacDeveloperToolsView(
        model: model,
        purchases: purchases,
        onboarding: onboarding
      )
      .macAppTheme(model.themeStore, purchaseManager: purchases)
      .environment(purchases)
      .environment(proGateCenter)
      .managesAnalytics(analytics)
    }
    .defaultSize(width: 920, height: 680)

    Window(
      MacAppFoundationDeveloperTools.windowTitle,
      id: MacAppFoundationDeveloperTools.windowID
    ) {
      FoundationDeveloperView(
        purchaseManager: purchases,
        configuration: MacPurchaseStore.developerConfiguration
      )
      .macAppTheme(model.themeStore, purchaseManager: purchases)
      .environment(purchases)
      .managesAnalytics(analytics)
    }
    .defaultSize(
      width: MacAppFoundationDeveloperTools.defaultWidth,
      height: MacAppFoundationDeveloperTools.defaultHeight
    )
    #endif

    Settings {
      MacSettingsView(model: model, purchaseManager: purchases)
        .macAppTheme(model.themeStore, purchaseManager: purchases)
        .environment(purchases)
        .environment(proGateCenter)
        .environment(settingsRouter)
        .managesAnalytics(analytics)
        .managesMacProAccess(
          model: model,
          purchases: purchases,
          proGateCenter: proGateCenter
        )
    }
    .windowStyle(.hiddenTitleBar)
  }
}

@MainActor
private struct MacProSceneLifecycleModifier: ViewModifier {
  let model: MacAppModel
  let purchases: PurchaseManager
  let proGateCenter: MacProGateCenter

  @Environment(\.openWindow) private var openWindow

  func body(content: Content) -> some View {
    content
      .onChange(of: proGateCenter.requestID) { _, _ in
        openWindow(id: MacWindowID.proPaywall)
      }
      .onChange(of: purchases.entitlementState) { _, _ in
        reconcileEntitlement()
      }
      .task {
        reconcileEntitlement()
      }
  }

  private func reconcileEntitlement() {
    let access = MacProAccess.entitlementAccess
    if access == .pro {
      // Once the user legitimately unlocks Pro, restored resources become
      // normal existing resources and remain usable under downgrade semantics.
      MacPurchaseStore.restrictions.clear()
    }

    model.chats?.refreshNewChatTargetAfterProviderChanges()
  }
}

@MainActor
private extension View {
  func managesMacProAccess(
    model: MacAppModel,
    purchases: PurchaseManager,
    proGateCenter: MacProGateCenter
  ) -> some View {
    modifier(
      MacProSceneLifecycleModifier(
        model: model,
        purchases: purchases,
        proGateCenter: proGateCenter
      )
    )
  }
}

@MainActor
private struct MacMainWindowConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> MacMainWindowConfigurationView {
    MacMainWindowConfigurationView()
  }

  func updateNSView(_ nsView: MacMainWindowConfigurationView, context: Context) {}
}

@MainActor
private final class MacMainWindowConfigurationView: NSView {
  private static let toolbarIdentifier = NSToolbar.Identifier("BYOKchatTitlebarGeometry")

  private var toolbarVisibilityBeforeFullScreen: Bool?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    toolbarVisibilityBeforeFullScreen = nil
    guard let window else { return }

    window.styleMask.insert(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none

    if window.toolbar == nil {
      let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
      toolbar.allowsUserCustomization = false
      toolbar.autosavesConfiguration = false
      window.toolbar = toolbar
    }
    window.toolbarStyle = .unified

    for name in [
      NSWindow.willEnterFullScreenNotification,
      NSWindow.didEnterFullScreenNotification,
    ] {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(hideToolbarForFullScreen(_:)),
        name: name,
        object: window
      )
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidExitFullScreen(_:)),
      name: NSWindow.didExitFullScreenNotification,
      object: window
    )

    if window.styleMask.contains(.fullScreen) {
      hideToolbarForFullScreen()
    }
  }

  @objc
  private func hideToolbarForFullScreen(_ notification: Notification) {
    hideToolbarForFullScreen()
  }

  private func hideToolbarForFullScreen() {
    guard let toolbar = window?.toolbar else { return }

    if toolbarVisibilityBeforeFullScreen == nil {
      toolbarVisibilityBeforeFullScreen = toolbar.isVisible
    }
    toolbar.isVisible = false
  }

  @objc
  private func windowDidExitFullScreen(_ notification: Notification) {
    if let toolbarVisibilityBeforeFullScreen {
      window?.toolbar?.isVisible = toolbarVisibilityBeforeFullScreen
    }
    toolbarVisibilityBeforeFullScreen = nil
  }
}

@MainActor
private struct MacBYOKOnboardingView: View {
  let onboarding: OnboardingState

  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    OnboardingView {
      content
        .id(onboarding.currentStep)
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
        .padding(34)
        .background(MacDesignTokens.Colors.canvas)
    } leadingActions: {
      HStack(spacing: 8) {
        if onboarding.canGoBack {
          Button("Back") {
            withAnimation(.snappy(duration: 0.22)) {
              onboarding.goBack()
            }
          }
        }

        if !onboarding.isLastStep {
          Button("Skip") {
            completeOnboarding()
          }
        }
      }
    } message: {
      OnboardingStepMessage(
        title: stepTitle,
        currentStep: onboarding.currentStep,
        stepCount: onboarding.stepCount
      )
    } trailingActions: {
      Button(onboarding.isLastStep ? "Get Started" : "Continue") {
        continueFlow()
      }
      .buttonStyle(.borderedProminent)
    }
    .frame(width: 720, height: 590)
    .background(MacDesignTokens.Colors.canvas)
  }

  @ViewBuilder
  private var content: some View {
    switch onboarding.currentStep {
    case 0:
      onboardingPage(
        eyebrow: "WELCOME",
        symbol: "sparkles",
        title: "Chat with any model",
        message: "Streaming answers, reasoning, files, and tools in one native workspace.",
        rows: [
          OnboardingFeature(
            symbol: "bolt.horizontal.fill",
            title: "Fast native chat",
            detail: "Stream responses directly from the provider you choose."
          ),
          OnboardingFeature(
            symbol: "brain",
            title: "Reasoning when available",
            detail: "Choose supported reasoning modes and effort per conversation."
          ),
          OnboardingFeature(
            symbol: "paperclip",
            title: "Files in context",
            detail: "Attach local files, saved Library items, and project sources."
          ),
        ]
      ) {
        MacOnboardingStreamingDemoCard()
      }

    case 1:
      onboardingPage(
        eyebrow: "PROVIDERS",
        symbol: "key.horizontal",
        title: "Your providers. Your API keys.",
        message: "Connect cloud models, private endpoints, and local servers directly.",
        rows: [
          OnboardingFeature(
            symbol: "server.rack",
            title: "Multiple providers",
            detail: "Use built-in providers or OpenAI-compatible endpoints."
          ),
          OnboardingFeature(
            symbol: "key.fill",
            title: "Credentials stay in Keychain",
            detail: "BYOKchat stores provider secrets using macOS Keychain."
          ),
          OnboardingFeature(
            symbol: "slider.horizontal.3",
            title: "Pick the model per chat",
            detail: "Switch provider, model, reasoning, and effort without leaving the conversation."
          ),
        ]
      ) {
        MacOnboardingProviderPillDemoCard()
      }

    default:
      onboardingPage(
        eyebrow: "WORKSPACE",
        symbol: "square.grid.2x2",
        title: "More than chat",
        message: "Projects, tools, saved files, and usage insights stay together in one focused workspace.",
        rows: [
          OnboardingFeature(
            symbol: "folder",
            title: "Projects",
            detail: "Group chats, instructions, sources, prompt presets, and tool defaults."
          ),
          OnboardingFeature(
            symbol: "puzzlepiece.extension",
            title: "MCP tools",
            detail: "Connect tool servers and control permissions per chat or project."
          ),
          OnboardingFeature(
            symbol: "books.vertical",
            title: "Library & analytics",
            detail: "Reuse saved files and understand local usage, cost, and reliability."
          ),
        ]
      ) {
        MacOnboardingWorkspaceDemoCard()
      }
    }
  }

  private func onboardingPage<Demo: View>(
    eyebrow: String,
    symbol: String,
    title: String,
    message: String,
    rows: [OnboardingFeature],
    @ViewBuilder demo: () -> Demo
  ) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .top, spacing: 16) {
        Image(systemName: symbol)
          .font(.system(size: 26, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.accent)
          .frame(width: 52, height: 52)
          .background(
            MacDesignTokens.Colors.accentSoft,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
          )

        VStack(alignment: .leading, spacing: 5) {
          Text(eyebrow)
            .font(.caption.weight(.bold))
            .tracking(1.2)
            .foregroundStyle(MacDesignTokens.Colors.accent)

          Text(title)
            .font(.system(size: 26, weight: .bold, design: .rounded))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)

          Text(message)
            .font(.callout)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack(alignment: .top, spacing: 16) {
        VStack(spacing: 10) {
          ForEach(rows) { row in
            onboardingRow(row)
          }
        }
        .frame(maxWidth: .infinity)

        demo()
          .frame(width: 286)
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func onboardingRow(_ feature: OnboardingFeature) -> some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: feature.symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .frame(width: 30, height: 30)
        .background(
          MacDesignTokens.Colors.accentSoft.opacity(0.75),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )

      VStack(alignment: .leading, spacing: 2) {
        Text(feature.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        Text(feature.detail)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.82), lineWidth: 1)
    }
  }

  private var stepTitle: String {
    switch onboarding.currentStep {
    case 0: "Chat"
    case 1: "Providers"
    default: "Workspace"
    }
  }

  private func continueFlow() {
    guard onboarding.isLastStep else {
      withAnimation(.snappy(duration: 0.22)) {
        onboarding.goForward()
      }
      return
    }

    completeOnboarding()
  }

  private func completeOnboarding() {
    if !onboarding.isCompleted {
      MacAppAnalytics.track(.onboardingCompleted)
    }
    onboarding.complete()
    openWindow(id: BYOKmacWindowID.main)
    dismissWindow(id: BYOKmacWindowID.onboarding)
  }
}

@MainActor
private struct MacOnboardingStreamingDemoCard: View {
  private enum Mode: String, CaseIterable, Identifiable {
    case reasoning = "Reasoning"
    case markdown = "Markdown"
    var id: String { rawValue }
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var mode: Mode = .reasoning
  @State private var visibleWordCount = 0
  @State private var replayID = 0

  private var previewText: String {
    switch mode {
    case .reasoning:
      "Compared Q3 vs Q4 latency: median TTFT dropped 28% while prompt cache hits doubled."
    case .markdown:
      "Native rendering handles **tables**, `code blocks`, Mermaid diagrams, and inline LaTeX smoothly."
    }
  }

  private var words: [Substring] {
    previewText.split(separator: " ")
  }

  private var streamedText: String {
    words.prefix(visibleWordCount).joined(separator: " ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        ForEach(Mode.allCases) { item in
          Button {
            withAnimation(.snappy(duration: 0.2)) {
              mode = item
              replayID &+= 1
            }
          } label: {
            Text(item.rawValue)
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 9)
              .padding(.vertical, 4)
              .background(
                mode == item ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.canvas,
                in: Capsule()
              )
              .foregroundStyle(
                mode == item ? Color.white : MacDesignTokens.Colors.textMuted
              )
          }
          .buttonStyle(.plain)
        }
        Spacer()
        Button {
          replayID &+= 1
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.caption.weight(.semibold))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .buttonStyle(.plain)
        .help("Replay streaming preview")
      }

      HStack {
        Spacer(minLength: 28)
        Text(mode == .reasoning ? "Compare Q3 & Q4 latency?" : "Show formatted output?")
          .font(.caption.weight(.medium))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(MacDesignTokens.Colors.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      }

      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 5) {
          Image(systemName: mode == .reasoning ? "brain" : "doc.richtext")
            .foregroundStyle(MacDesignTokens.Colors.accent)
          Text(mode == .reasoning ? "Thought for 1.2s · Medium" : "Markdown & Code Ready")
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .font(.caption2.weight(.semibold))

        Text(previewText)
          .font(.caption)
          .opacity(0)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .overlay(alignment: .topLeading) {
            Text(streamedText)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .frame(maxWidth: .infinity, alignment: .topLeading)
          }

        if mode == .markdown {
          Text("let stream = runtime.stream(request)")
            .font(.caption2.monospaced())
            .foregroundStyle(MacDesignTokens.Colors.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MacDesignTokens.Colors.codeSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
      }
      .padding(11)
      .background(MacDesignTokens.Colors.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.7), lineWidth: 1)
      }

      HStack(spacing: 6) {
        Image(systemName: "sparkles")
          .font(.caption2.weight(.bold))
          .foregroundStyle(MacDesignTokens.Colors.accent)
        Text("Claude Sonnet · Direct Stream")
          .font(.caption2.weight(.medium))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        Spacer()
        Text("340 ms TTFT")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    }
    .padding(14)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.85), lineWidth: 1)
    }
    .task(id: "\(mode.rawValue)-\(replayID)-\(reduceMotion)") {
      if reduceMotion {
        visibleWordCount = words.count
        return
      }
      visibleWordCount = 0
      for count in 1...words.count {
        try? await Task.sleep(for: .milliseconds(55))
        if Task.isCancelled { return }
        visibleWordCount = count
      }
    }
  }
}

@MainActor
private struct MacOnboardingProviderPillDemoCard: View {
  private struct SampleProvider: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: String
    let models: String
    let authBadge: String
    let symbol: String
  }

  private let providers: [SampleProvider] = [
    SampleProvider(
      id: "anthropic",
      name: "Anthropic",
      endpoint: "api.anthropic.com",
      models: "Claude Sonnet · Opus",
      authBadge: "Keychain · Direct TLS",
      symbol: "sparkles"
    ),
    SampleProvider(
      id: "openai",
      name: "OpenAI",
      endpoint: "api.openai.com",
      models: "GPT-5 · o3 · o4-mini",
      authBadge: "Keychain · Direct TLS",
      symbol: "bolt.fill"
    ),
    SampleProvider(
      id: "gemini",
      name: "Gemini",
      endpoint: "generativelanguage.googleapis.com",
      models: "Gemini 2.5 Pro · Flash",
      authBadge: "Keychain · Direct TLS",
      symbol: "wand.and.stars"
    ),
    SampleProvider(
      id: "ollama",
      name: "Ollama",
      endpoint: "localhost:11434/v1",
      models: "Qwen 3 · Llama · Local",
      authBadge: "No API Key · Local",
      symbol: "desktopcomputer"
    ),
  ]

  @State private var selectedID = "anthropic"

  private var selectedProvider: SampleProvider {
    providers.first { $0.id == selectedID } ?? providers[0]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("PREVIEW CONNECTIONS")
        .font(.caption2.weight(.bold))
        .tracking(0.8)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
        ForEach(providers) { provider in
          Button {
            withAnimation(.snappy(duration: 0.2)) {
              selectedID = provider.id
            }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: provider.symbol)
                .font(.caption2.weight(.semibold))
              Text(provider.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
              selectedID == provider.id
                ? MacDesignTokens.Colors.accent
                : MacDesignTokens.Colors.canvas,
              in: Capsule()
            )
            .foregroundStyle(
              selectedID == provider.id ? Color.white : MacDesignTokens.Colors.textPrimary
            )
          }
          .buttonStyle(.plain)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label(selectedProvider.name, systemImage: selectedProvider.symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          Spacer()
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(MacDesignTokens.Colors.accent)
        }

        LabeledContent("Endpoint") {
          Text(selectedProvider.endpoint)
            .font(.caption2.monospaced())
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .font(.caption)

        LabeledContent("Models", value: selectedProvider.models)
          .font(.caption)

        HStack(spacing: 6) {
          Image(systemName: "lock.shield.fill")
            .foregroundStyle(MacDesignTokens.Colors.accent)
          Text(selectedProvider.authBadge)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          Spacer()
          Text("No proxy")
            .font(.caption2)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .padding(.top, 2)
      }
      .padding(11)
      .background(MacDesignTokens.Colors.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.7), lineWidth: 1)
      }
    }
    .padding(14)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.85), lineWidth: 1)
    }
  }
}

@MainActor
private struct MacOnboardingWorkspaceDemoCard: View {
  @State private var requireToolApproval = true
  @State private var keepKeysLocal = true

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Text("PRIVACY & TOOLS PREVIEW")
        .font(.caption2.weight(.bold))
        .tracking(0.8)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)

      VStack(alignment: .leading, spacing: 8) {
        Toggle(isOn: $requireToolApproval) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Ask before MCP tools")
              .font(.caption.weight(.semibold))
            Text(requireToolApproval ? "Prompt before each remote tool call" : "Auto-allow trusted server tools")
              .font(.caption2)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }
        .toggleStyle(.switch)
        .controlSize(.small)

        Divider()

        Toggle(isOn: $keepKeysLocal) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Local-only Keychain")
              .font(.caption.weight(.semibold))
            Text("Secrets never leave macOS Keychain")
              .font(.caption2)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(true)
      }
      .padding(10)
      .background(MacDesignTokens.Colors.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.7), lineWidth: 1)
      }

      HStack(spacing: 8) {
        Image(systemName: requireToolApproval ? "hand.raised.fill" : "checkmark.seal.fill")
          .foregroundStyle(MacDesignTokens.Colors.accent)
        VStack(alignment: .leading, spacing: 1) {
          Text("search_docs · MCP")
            .font(.caption.weight(.semibold))
          Text(requireToolApproval ? "Waiting for your approval" : "Approved automatically")
            .font(.caption2)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        Spacer()
        Text(requireToolApproval ? "Ask" : "Allow")
          .font(.caption2.weight(.bold))
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(MacDesignTokens.Colors.accentSoft, in: Capsule())
          .foregroundStyle(MacDesignTokens.Colors.accent)
      }
      .padding(10)
      .background(MacDesignTokens.Colors.canvas, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

      HStack(spacing: 0) {
        metricCell(value: "$12.48", label: "Local Spend")
        Divider().frame(height: 24)
        metricCell(value: "340 ms", label: "TTFT")
        Divider().frame(height: 24)
        metricCell(value: "99.4%", label: "Success")
      }
      .padding(.vertical, 8)
      .background(MacDesignTokens.Colors.canvas, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
    .padding(14)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.85), lineWidth: 1)
    }
  }

  private func metricCell(value: String, label: String) -> some View {
    VStack(spacing: 1) {
      Text(value)
        .font(.caption.weight(.bold).monospacedDigit())
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      Text(label)
        .font(.caption2)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct OnboardingFeature: Identifiable {
  let symbol: String
  let title: String
  let detail: String

  var id: String { title }
}
