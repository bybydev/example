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
    TabView(selection: $selection) {
      Tab("General", systemImage: "gearshape", value: MacSettingsTab.general) {
        MacGeneralSettingsView(
          preferences: model.preferences,
          chats: model.chats
        )
      }

      Tab("Data", systemImage: "externaldrive", value: MacSettingsTab.data) {
        MacDataSettingsView(model: model)
      }

      Tab("Theme", systemImage: "paintpalette", value: MacSettingsTab.theme) {
        MacAppThemeSettingsPane(
          themeStore: model.themeStore,
          purchaseManager: purchaseManager,
          variant: .compact,
          onUpgrade: {
            MacProAccess.requestUpgrade(.themes)
          }
        )
      }

      Tab("Plan", systemImage: "creditcard", value: MacSettingsTab.plan) {
        ZStack {
          MacDesignTokens.Colors.canvas
          ProPlanPane(
            purchaseManager: purchaseManager,
            configuration: MacPurchaseStore.planConfiguration,
            onUpgrade: { openWindow(id: MacWindowID.proPaywall) }
          )
          .padding(20)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }

      Tab("About", systemImage: "info.circle", value: MacSettingsTab.about) {
        MacAboutSettingsView()
      }
    }
    .frame(minWidth: 640, idealWidth: 680, minHeight: 520, idealHeight: 560)
    .background(MacDesignTokens.Colors.canvas)
    .groupBoxStyle(MacSettingsGroupBoxStyle())
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

private struct MacSettingsGroupBoxStyle: GroupBoxStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      configuration.label
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)

      configuration.content
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
    }
    .padding(16)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.82), lineWidth: 1)
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
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox("Chat") {
          LabeledContent("Keyboard") {
            Text("Return sends · Shift-Return inserts a line")
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }

        GroupBox("Default System Prompt") {
          VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
              TextEditor(text: $promptDraft)
                .font(.system(size: 13))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($isPromptFocused)
                .frame(minHeight: 160)
                .padding(8)
                .accessibilityLabel("Default System Prompt")

              if promptDraft.isEmpty {
                Text("e.g. Be concise, direct, and explain trade-offs clearly.")
                  .font(.system(size: 13))
                  .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.65))
                  .padding(.top, 10)
                  .padding(.leading, 13)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
            .background(
              MacDesignTokens.Colors.codeSurface,
              in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
                .stroke(MacDesignTokens.Colors.separator.opacity(0.82), lineWidth: 1)
            }

            HStack(alignment: .center, spacing: 12) {
              Text("Copied into new conversations unless a project defines its own instructions. Existing conversations with messages are unchanged.")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

              Spacer(minLength: 12)

              Button("Clear Prompt", role: .destructive) {
                confirmClearPrompt = true
              }
              .disabled(trimmedPrompt.isEmpty)
            }
          }
        }

        GroupBox("Privacy") {
          VStack(alignment: .leading, spacing: 8) {
            Toggle("Share Anonymous Usage Data", isOn: $preferences.shareUsageData)
              .onChange(of: preferences.shareUsageData) { _, enabled in
                Task { await MacAppAnalytics.setEnabled(enabled) }
              }

            Text("Sends anonymous product usage counters to help improve BYOKchat. Messages, prompts, and file names are never collected.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(MacDesignTokens.Colors.canvas)
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
      .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(MacDesignTokens.Colors.canvas)
    }
  }
}

private struct MacAboutSettingsView: View {
  private var appVersionSummary: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    return "Version \(version) (\(build))"
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        VStack(spacing: 10) {
          let appIcon: NSImage? = NSApplication.shared.applicationIconImage
          if let appIcon {
            Image(nsImage: appIcon)
              .resizable()
              .interpolation(.high)
              .frame(width: 68, height: 68)
              .accessibilityHidden(true)
          }

          VStack(spacing: 4) {
            Text("BYOKchat")
              .font(.title2.weight(.semibold))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)

            Text(appVersionSummary)
              .font(.callout)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }

          Text("Private, native AI chat powered by your own cloud and local model connections.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        .padding(.top, 8)

        GroupBox("Links & Legal") {
          VStack(spacing: 4) {
            MacAboutLinkRow(
              title: "Website",
              systemImage: "globe",
              destination: MacPurchaseStore.websiteURL
            )
            MacAboutLinkRow(
              title: "Contact Us",
              systemImage: "envelope",
              destination: MacPurchaseStore.contactURL
            )
            MacAboutLinkRow(
              title: "Privacy Policy",
              systemImage: "hand.raised",
              destination: MacPurchaseStore.privacyURL
            )
            MacAboutLinkRow(
              title: "Terms of Use",
              systemImage: "doc.text",
              destination: MacPurchaseStore.termsURL
            )
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity)
    }
    .background(MacDesignTokens.Colors.canvas)
  }
}

private struct MacAboutLinkRow: View {
  let title: String
  let systemImage: String
  let destination: URL

  @State private var isHovered = false

  var body: some View {
    Link(destination: destination) {
      HStack(spacing: 8) {
        Label(title, systemImage: systemImage)
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(
            isHovered ? MacDesignTokens.Colors.textPrimary : MacDesignTokens.Colors.textMuted
          )
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .background(
        Color.primary.opacity(isHovered ? MacDesignTokens.Control.hoverOpacity : 0),
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(
      .easeOut(duration: MacDesignTokens.Control.interactionDuration),
      value: isHovered
    )
  }
}
