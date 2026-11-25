import AppKit
import BYOKchatProviderCore
import MacAppFoundation
import SwiftUI

struct MacSettingsView: View {
  static let contentWidth: CGFloat = 640
  static let contentHeight: CGFloat = 440

  let model: MacAppModel
  let purchaseManager: PurchaseManager

  @Environment(\.macAppTheme) private var theme
  @Environment(\.openWindow) private var openWindow
  @Environment(MacSettingsRouter.self) private var settingsRouter
  @State private var selection: MacSettingsTab = .general

  var body: some View {
    TabView(selection: $selection) {
      MacGeneralSettingsView(
        preferences: model.preferences,
        chats: model.chats
      )
      .tabItem {
        Label("General", systemImage: "gearshape")
      }
      .tag(MacSettingsTab.general)

      MacDataSettingsView(model: model)
        .tabItem {
          Label("Data", systemImage: "externaldrive")
        }
        .tag(MacSettingsTab.data)

      ThemePickerView(
        themeStore: model.themeStore,
        purchaseManager: purchaseManager,
        variant: .compact,
        onUpgrade: {
          MacProAccess.requestUpgrade(.themes)
        }
      )
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(theme.canvas)
      .tabItem {
        Label("Theme", systemImage: "paintpalette")
      }
      .tag(MacSettingsTab.theme)

      MacAppPlanSettingsPane(
        purchaseManager: purchaseManager,
        configuration: MacPurchaseStore.planConfiguration,
        onUpgrade: { openWindow(id: MacWindowID.proPaywall) }
      )
      .tabItem {
        Label("Plan", systemImage: "creditcard")
      }
      .tag(MacSettingsTab.plan)

      MacAboutSettingsView()
        .tabItem {
          Label("About", systemImage: "info.circle")
        }
        .tag(MacSettingsTab.about)
    }
    .frame(width: Self.contentWidth, height: Self.contentHeight)
    .background(theme.canvas)
    .foregroundStyle(theme.textPrimary)
    .onAppear {
      consumeRouterRequest()
      MacAppAnalytics.track(.featureOpened, dimension: .settings)
    }
    .onChange(of: settingsRouter.requestID) { _, _ in
      consumeRouterRequest()
    }
    .macProUpsellPresenter()
  }

  private func consumeRouterRequest() {
    if let tab = settingsRouter.consumeRequestedTab() {
      selection = tab
    }
  }
}

struct MacSettingsCard<Content: View>: View {
  @Environment(\.macAppTheme) private var theme
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      content()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      theme.surface,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.border, lineWidth: 1)
    }
  }
}

struct MacSettingsDivider: View {
  @Environment(\.macAppTheme) private var theme

  var body: some View {
    Rectangle()
      .fill(theme.separator.opacity(0.75))
      .frame(height: 1)
  }
}

struct MacSettingsButtonStyle: ButtonStyle {
  var isDestructive = false

  func makeBody(configuration: Configuration) -> some View {
    MacSettingsButtonStyleBody(
      configuration: configuration,
      isDestructive: isDestructive
    )
  }

  private struct MacSettingsButtonStyleBody: View {
    @Environment(\.macAppTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyle.Configuration
    let isDestructive: Bool

    @State private var isHovered = false

    var body: some View {
      configuration.label
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(foregroundColor)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(backgroundColor)
        .clipShape(shape)
        .overlay {
          shape.strokeBorder(borderColor, lineWidth: 1)
        }
        .contentShape(shape)
        .onHover { isHovered = $0 }
    }

    private var shape: RoundedRectangle {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    private var foregroundColor: Color {
      guard isEnabled else {
        return isDestructive ? theme.destructive.opacity(0.45) : theme.textMuted
      }
      return isDestructive ? theme.destructive : theme.textPrimary
    }

    private var backgroundColor: Color {
      if isDestructive {
        guard isEnabled else { return theme.destructive.opacity(0.03) }
        if configuration.isPressed { return theme.destructive.opacity(0.18) }
        if isHovered { return theme.destructive.opacity(0.12) }
        return theme.destructive.opacity(0.06)
      }

      guard isEnabled else {
        return theme.surfaceRaised.opacity(0.45)
      }

      if configuration.isPressed {
        return theme.accentSoft
      }

      if isHovered {
        return theme.selection.opacity(0.75)
      }

      return theme.surfaceRaised
    }

    private var borderColor: Color {
      if isDestructive {
        guard isEnabled else { return theme.destructive.opacity(0.14) }
        if configuration.isPressed { return theme.destructive.opacity(0.45) }
        if isHovered { return theme.destructive.opacity(0.32) }
        return theme.destructive.opacity(0.24)
      }

      guard isEnabled else {
        return theme.border.opacity(0.55)
      }

      if configuration.isPressed {
        return theme.accent.opacity(0.45)
      }

      if isHovered {
        return theme.accent.opacity(0.30)
      }

      return theme.border
    }
  }
}

private struct MacGeneralSettingsView: View {
  @Bindable var preferences: MacPreferencesModel
  let chats: MacChatSessionModel?

  @Environment(\.macAppTheme) private var theme
  @State private var promptDraft: String
  @State private var lastSyncedPrompt: String
  @State private var confirmClearPrompt = false
  @FocusState private var isPromptFocused: Bool

  init(preferences: MacPreferencesModel, chats: MacChatSessionModel?) {
    self.preferences = preferences
    self.chats = chats
    let initial = MacPreferencesModel.normalizedSystemPrompt(preferences.defaultSystemPrompt)
    _promptDraft = State(initialValue: initial)
    _lastSyncedPrompt = State(initialValue: initial)
  }

  private var trimmedPrompt: String {
    MacPreferencesModel.normalizedSystemPrompt(promptDraft)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        MacSettingsCard {
          HStack {
            Text("Keyboard")
              .foregroundStyle(theme.textPrimary)
            Spacer()
            Text("Return sends · Shift-Return new line")
              .font(.caption)
              .foregroundStyle(theme.textSecondary)
          }
        }

        MacSettingsCard {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Default system prompt")
                .foregroundStyle(theme.textPrimary)
              Spacer()
              Button("Clear", role: .destructive) {
                confirmClearPrompt = true
              }
              .buttonStyle(MacSettingsButtonStyle(isDestructive: true))
              .disabled(trimmedPrompt.isEmpty)
            }

            ZStack(alignment: .topLeading) {
              TextEditor(text: $promptDraft)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($isPromptFocused)
                .frame(height: 92)
                .padding(6)
                .accessibilityLabel("Default System Prompt")

              if promptDraft.isEmpty {
                Text("e.g. Be concise, direct, and explain trade-offs clearly.")
                  .font(.system(size: 12.5))
                  .foregroundStyle(theme.textMuted)
                  .padding(.top, 8)
                  .padding(.leading, 11)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
            .background(
              theme.canvas,
              in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                  isPromptFocused ? theme.accent.opacity(0.55) : theme.border,
                  lineWidth: 1
                )
            }

            Text("Copied into new conversations unless a project defines its own instructions. Existing conversations with messages are unchanged.")
              .font(.caption)
              .foregroundStyle(theme.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        MacSettingsCard {
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("Share anonymous usage data")
                .foregroundStyle(theme.textPrimary)
              Spacer()
              Toggle("Share anonymous usage data", isOn: $preferences.shareUsageData)
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Text("Sends anonymous product usage counters to help improve BYOKchat. Messages, prompts, and file names are never collected.")
              .font(.caption)
              .foregroundStyle(theme.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .onChange(of: preferences.shareUsageData) { _, enabled in
          Task { await MacAppAnalytics.setEnabled(enabled) }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .background(theme.canvas)
    .confirmationDialog(
      "Clear default system prompt?",
      isPresented: $confirmClearPrompt,
      titleVisibility: .visible
    ) {
      Button("Clear", role: .destructive) {
        isPromptFocused = false
        promptDraft = ""
        commitPromptIfNeeded()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("New conversations will start without a default system prompt.")
    }
    .task(id: promptDraft) {
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      commitPromptIfNeeded()
    }
    .onChange(of: isPromptFocused) { _, focused in
      if !focused {
        promptDraft = trimmedPrompt
        commitPromptIfNeeded()
      }
    }
    .onChange(of: preferences.defaultSystemPrompt) { _, updated in
      let normalized = MacPreferencesModel.normalizedSystemPrompt(updated)
      guard normalized != lastSyncedPrompt else { return }
      lastSyncedPrompt = normalized
      promptDraft = normalized
    }
    .onDisappear {
      commitPromptIfNeeded()
    }
  }

  private func commitPromptIfNeeded() {
    let normalized = trimmedPrompt
    let previous = MacPreferencesModel.normalizedSystemPrompt(preferences.defaultSystemPrompt)
    lastSyncedPrompt = normalized
    if preferences.defaultSystemPrompt != normalized {
      preferences.defaultSystemPrompt = normalized
    }
    if previous != normalized {
      Task {
        await chats?.syncDefaultSystemPrompt(from: previous, to: normalized)
      }
    }
  }
}

private struct MacDataSettingsView: View {
  let model: MacAppModel

  @Environment(\.macAppTheme) private var theme

  var body: some View {
    if let data = model.dataManagement {
      MacDataManagementView(app: model, data: data)
    } else {
      ContentUnavailableView(
        "Data Management Unavailable",
        systemImage: "externaldrive.badge.exclamationmark",
        description: Text("Finish app startup before importing, exporting, or resetting data.")
      )
      .foregroundStyle(theme.textPrimary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(theme.canvas)
    }
  }
}

private struct MacAboutSettingsView: View {
  @Environment(\.macAppTheme) private var theme

  private var appVersionSummary: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    return "\(version) (\(build))"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        MacSettingsCard {
          HStack {
            Text("Version")
              .foregroundStyle(theme.textPrimary)
            Spacer()
            Text(appVersionSummary)
              .font(.system(size: 12, weight: .medium, design: .monospaced))
              .foregroundStyle(theme.textSecondary)
          }
        }

        MacSettingsCard {
          HStack {
            Text("Website")
              .foregroundStyle(theme.textPrimary)
            Spacer()
            Button("spokiostudio.com/byokchat") {
              NSWorkspace.shared.open(MacPurchaseStore.websiteURL)
            }
            .buttonStyle(MacSettingsButtonStyle())
          }

          MacSettingsDivider()

          HStack {
            Text("Contact and feedback")
              .foregroundStyle(theme.textPrimary)
            Spacer()
            Button("Contact Us") {
              NSWorkspace.shared.open(MacPurchaseStore.contactURL)
            }
            .buttonStyle(MacSettingsButtonStyle())
          }

          MacSettingsDivider()

          HStack {
            Text("Privacy Policy")
              .foregroundStyle(theme.textPrimary)
            Spacer()
            Button("View Policy") {
              NSWorkspace.shared.open(MacPurchaseStore.privacyURL)
            }
            .buttonStyle(MacSettingsButtonStyle())
          }

          MacSettingsDivider()

          HStack {
            Text("Terms of Use")
              .foregroundStyle(theme.textPrimary)
            Spacer()
            Button("View Terms") {
              NSWorkspace.shared.open(MacPurchaseStore.termsURL)
            }
            .buttonStyle(MacSettingsButtonStyle())
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .background(theme.canvas)
  }
}
