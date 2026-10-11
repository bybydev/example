import AppKit
import Foundation
import MacAppFoundation
import SwiftUI

private enum BYOKmacWindowID {
  static let main = "main"
  static let onboarding = "byokchat.onboarding"
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
        Button("Developer Tools…") {
          openWindow(id: MacAppFoundationDeveloperTools.windowID)
        }
        .keyboardShortcut("d", modifiers: [.command, .option])

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
      defaultWidth: 680,
      defaultHeight: 540
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
        .padding(40)
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
    .frame(width: 680, height: 540)
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
      )

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
      )

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
      )
    }
  }

  private func onboardingPage(
    eyebrow: String,
    symbol: String,
    title: String,
    message: String,
    rows: [OnboardingFeature]
  ) -> some View {
    VStack(alignment: .leading, spacing: 26) {
      HStack(alignment: .top, spacing: 18) {
        Image(systemName: symbol)
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.accent)
          .frame(width: 58, height: 58)
          .background(
            MacDesignTokens.Colors.accentSoft,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
          )

        VStack(alignment: .leading, spacing: 7) {
          Text(eyebrow)
            .font(.caption.weight(.bold))
            .tracking(1.2)
            .foregroundStyle(MacDesignTokens.Colors.accent)

          Text(title)
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)

          Text(message)
            .font(.title3)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(spacing: 12) {
        ForEach(rows) { row in
          onboardingRow(row)
        }
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func onboardingRow(_ feature: OnboardingFeature) -> some View {
    HStack(alignment: .top, spacing: 13) {
      Image(systemName: feature.symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .frame(width: 34, height: 34)
        .background(
          MacDesignTokens.Colors.accentSoft.opacity(0.75),
          in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )

      VStack(alignment: .leading, spacing: 3) {
        Text(feature.title)
          .font(.headline)
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        Text(feature.detail)
          .font(.callout)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(14)
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

private struct OnboardingFeature: Identifiable {
  let symbol: String
  let title: String
  let detail: String

  var id: String { title }
}