import AppKit
import BYOKchatProviderCore
import MacAppFoundation
import SwiftUI

struct MacSettingsView: View {
  let model: MacAppModel
  let purchaseManager: PurchaseManager

  @Environment(\.openWindow) private var openWindow
  @Environment(MacSettingsRouter.self) private var settingsRouter
  @State private var selection: MacSettingsTab = .general

  var body: some View {
    VStack(spacing: 16) {
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
          .frame(height: 440)
          .tabItem {
            Label("Data", systemImage: "externaldrive")
          }
          .tag(MacSettingsTab.data)

        MacThemeSettingsTab(
          themeStore: model.themeStore,
          purchaseManager: purchaseManager,
          onUpgrade: {
            MacProAccess.requestUpgrade(.themes)
          }
        )
        .frame(height: 380)
        .tabItem {
          Label("Theme", systemImage: "paintpalette")
        }
        .tag(MacSettingsTab.theme)

        ProPlanPane(
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
    }
    .padding()
    .frame(width: 500, alignment: .top)
    .fixedSize()
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

struct MacSettingsButtonStyle: ButtonStyle {
  var isDestructive = false

  func makeBody(configuration: Configuration) -> some View {
    MacSettingsButtonStyleBody(
      configuration: configuration,
      isDestructive: isDestructive
    )
  }

  private struct MacSettingsButtonStyleBody: View {
    @Environment(\.macAppTheme) private var mafTheme
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyle.Configuration
    let isDestructive: Bool

    @State private var isHovered = false

    var body: some View {
      configuration.label
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(foregroundColor)
        .lineLimit(1)
        .padding(.horizontal, 9)
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
        return isDestructive ? Color.red.opacity(0.45) : Color.secondary
      }
      return isDestructive ? Color.red : Color.primary
    }

    private var backgroundColor: Color {
      if isDestructive {
        guard isEnabled else { return Color.red.opacity(0.03) }
        if configuration.isPressed { return Color.red.opacity(0.16) }
        if isHovered { return Color.red.opacity(0.10) }
        return Color.red.opacity(0.05)
      }

      guard isEnabled else {
        return Color.primary.opacity(0.03)
      }

      if configuration.isPressed {
        return mafTheme.accent.opacity(0.10)
      }

      if isHovered {
        return Color.primary.opacity(0.06)
      }

      return Color.primary.opacity(0.035)
    }

    private var borderColor: Color {
      if isDestructive {
        guard isEnabled else { return Color.red.opacity(0.12) }
        if configuration.isPressed { return Color.red.opacity(0.40) }
        if isHovered { return Color.red.opacity(0.30) }
        return Color.red.opacity(0.22)
      }

      guard isEnabled else {
        return Color.primary.opacity(0.08)
      }

      if configuration.isPressed {
        return mafTheme.accent.opacity(0.30)
      }

      if isHovered {
        return Color.primary.opacity(0.20)
      }

      return Color.primary.opacity(0.14)
    }
  }
}

private struct MacGeneralSettingsView: View {
  @Bindable var preferences: MacPreferencesModel
  let chats: MacChatSessionModel?

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
    VStack(alignment: .leading, spacing: 16) {
      GroupBox {
        HStack {
          Text("Keyboard")
          Spacer()
          Text("Return sends · Shift-Return new line")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Default system prompt")
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
              .scrollContentBackground(.hidden)
              .focused($isPromptFocused)
              .frame(height: 112)
              .padding(6)
              .accessibilityLabel("Default System Prompt")

            if promptDraft.isEmpty {
              Text("e.g. Be concise, direct, and explain trade-offs clearly.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary.opacity(0.75))
                .padding(.top, 8)
                .padding(.leading, 11)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
          }
          .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
          }

          Text("Copied into new conversations unless a project defines its own instructions. Existing conversations with messages are unchanged.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Share anonymous usage data")
            Spacer()
            Toggle("Share anonymous usage data", isOn: $preferences.shareUsageData)
              .labelsHidden()
              .toggleStyle(.switch)
          }

          Text("Sends anonymous product usage counters to help improve BYOKchat. Messages, prompts, and file names are never collected.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
      }
      .onChange(of: preferences.shareUsageData) { _, enabled in
        Task { await MacAppAnalytics.setEnabled(enabled) }
      }
    }
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

  var body: some View {
    if let data = model.dataManagement {
      MacDataManagementView(app: model, data: data)
    } else {
      ContentUnavailableView(
        "Data Management Unavailable",
        systemImage: "externaldrive.badge.exclamationmark",
        description: Text("Finish app startup before importing, exporting, or resetting data.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// Transparent compact Theme picker matching Spokio's `ThemePickerView` inside
/// the native Settings window chrome without painting an opaque canvas fill.
private struct MacThemeSettingsTab: View {
  @Bindable var themeStore: MacAppThemeStore
  let purchaseManager: PurchaseManager
  let onUpgrade: () -> Void

  @Environment(\.macAppTheme) private var theme

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      let hasPro = purchaseManager.hasPro
      let proThemeIDs = themeStore.configuration.proThemeIDs
      let previewableThemeIDs = hasPro
        ? Set<MacAppThemeID>()
        : Set(proThemeIDs.filter { themeStore.canPreview($0, hasPro: false) })
      let lockedThemeIDs = hasPro
        ? Set<MacAppThemeID>()
        : proThemeIDs.subtracting(previewableThemeIDs)

      ScrollView {
        MacAppThemePicker(
          themes: themeStore.configuration.themes,
          selectedThemeID: themeStore.effectiveThemeID(hasPro: hasPro),
          previewingThemeID: themeStore.isPreviewActive
            ? themeStore.previewTheme?.id
            : nil,
          previewProgress: previewProgress,
          previewableThemeIDs: previewableThemeIDs,
          lockedThemeIDs: lockedThemeIDs,
          compact: true,
          onSelect: { themeID in
            _ = themeStore.select(themeID, hasPro: hasPro)
          },
          onPreviewSelect: { themeID in
            let result = themeStore.choose(themeID, hasPro: hasPro)
            if case .requiresPro = result {
              onUpgrade()
            }
          },
          onLockedSelect: { _ in
            onUpgrade()
          }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .safeAreaInset(edge: .bottom, spacing: 12) {
        if themeStore.isPreviewActive {
          previewStatus(hasPro: hasPro)
            .frame(maxWidth: .infinity)
        }
      }
    }
  }

  private var previewProgress: Double {
    guard themeStore.isPreviewActive else { return 0 }
    let duration = themeStore.configuration.previewBehavior.defaultDuration
    guard duration > 0 else { return 0 }
    return min(1, max(0, Double(themeStore.previewRemainingSeconds) / duration))
  }

  private var countdown: String {
    let seconds = themeStore.previewRemainingSeconds
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  private func previewStatus(hasPro: Bool) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "timer")
        .font(.headline)
        .foregroundStyle(theme.accent)

      VStack(alignment: .leading, spacing: 2) {
        Text("Previewing \(themeStore.previewTheme?.name ?? "Pro theme")")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(theme.textPrimary)

        Text(
          "Returns to \(themeStore.themeAfterPreview(hasPro: hasPro).name) in \(countdown)"
        )
        .font(.caption)
        .foregroundStyle(theme.textSecondary)
      }

      Spacer(minLength: 8)

      Button("Unlock Pro", action: onUpgrade)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

      Button("End") {
        themeStore.endPreview()
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(12)
    .background(
      theme.surfaceRaised,
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(theme.border, lineWidth: 1)
    }
    .shadow(color: theme.shadow, radius: 8, y: 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Previewing \(themeStore.previewTheme?.name ?? "Pro theme"). Returns to \(themeStore.themeAfterPreview(hasPro: hasPro).name) in \(countdown)."
    )
  }
}

private struct MacAboutSettingsView: View {
  private var appVersionSummary: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    return "\(version) (\(build))"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox {
        HStack {
          Text("Version")
          Spacer()
          Text(appVersionSummary)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 8)
      }

      GroupBox {
        HStack {
          Text("Website")
          Spacer()
          Button("spokiostudio.com/byokchat") {
            NSWorkspace.shared.open(MacPurchaseStore.websiteURL)
          }
          .buttonStyle(MacSettingsButtonStyle())
        }
        .padding(.horizontal, 8)

        Divider()

        HStack {
          Text("Contact and feedback")
          Spacer()
          Button("Contact Us") {
            NSWorkspace.shared.open(MacPurchaseStore.contactURL)
          }
          .buttonStyle(MacSettingsButtonStyle())
        }
        .padding(.horizontal, 8)

        Divider()

        HStack {
          Text("Privacy Policy")
          Spacer()
          Button("View Policy") {
            NSWorkspace.shared.open(MacPurchaseStore.privacyURL)
          }
          .buttonStyle(MacSettingsButtonStyle())
        }
        .padding(.horizontal, 8)

        Divider()

        HStack {
          Text("Terms of Use")
          Spacer()
          Button("View Terms") {
            NSWorkspace.shared.open(MacPurchaseStore.termsURL)
          }
          .buttonStyle(MacSettingsButtonStyle())
        }
        .padding(.horizontal, 8)
      }
    }
  }
}
