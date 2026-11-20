import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel
  let purchases: BYOKPurchaseStore

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var confirmDeleteConversations = false
  @State private var confirmDeleteCredentials = false
  @State private var showThemeUpsell = false
  @State private var showPaywall = false
  @State private var toastCenter = BYOKToastCenter()
  @AppStorage(BYOKAppAnalytics.preferenceKey) private var shareUsageData = true

  var body: some View {
    failureAlertView
      .byokToastOverlay(toastCenter)
      .onAppear {
        model.dataPortability.statusMessage = nil
      }
      .onChange(of: model.dataPortability.statusMessage) { _, message in
        guard let message else { return }
        model.dataPortability.statusMessage = nil
        guard model.dataPortability.errorMessage == nil else { return }
        toastCenter.success(message)
      }
      .onChange(of: model.dataPortability.errorMessage) { _, message in
        if message != nil { toastCenter.dismiss() }
      }
      .onDisappear {
        toastCenter.dismiss()
      }
      .sheet(isPresented: $showThemeUpsell) {
        BYOKProUpsellFlow(feature: .themes)
      }
      .sheet(isPresented: $showPaywall) {
        ProPaywallView(
          purchases: purchases.manager,
          configuration: BYOKPurchaseStore.paywallConfiguration,
          initialSelectedProductID: BYOKPurchaseStore.yearlyProductID
        )
        .environment(purchases.manager)
      }
  }

  private var navigationContent: some View {
    NavigationStack {
      settingsForm
        .navigationTitle("Settings")
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button("Close", systemImage: "xmark") {
              dismiss()
            }
          }
        }
    }
  }

  private var deletionConfiguredView: some View {
    navigationContent
      .alert("Delete all conversations?", isPresented: $confirmDeleteConversations) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) {
          Task { await model.dataPortability.deleteAllConversations() }
        }
      } message: {
        Text(
          "This removes every locally stored conversation on this device and cannot be undone. Your connections, projects, and Library files are kept."
        )
      }
      .alert("Delete all credentials?", isPresented: $confirmDeleteCredentials) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) {
          Task { await model.dataPortability.deleteAllCredentials() }
        }
      } message: {
        Text(
          "Connections and MCP servers remain configured, but every API key and MCP credential must be entered again."
        )
      }
  }

  private var failureAlertView: some View {
    deletionConfiguredView
      .alert(
        "Data Operation Failed",
        isPresented: Binding(
          get: { model.dataPortability.errorMessage != nil },
          set: { if !$0 { model.dataPortability.errorMessage = nil } }
        )
      ) {
        Button("OK") { model.dataPortability.errorMessage = nil }
      } message: {
        Text(model.dataPortability.errorMessage ?? "Unknown error")
      }
  }

  private var settingsForm: some View {
    Form {
      ProPlanSettingsSection(
        purchaseManager: purchases.manager,
        onUpgrade: { showPaywall = true }
      )
      .listRowBackground(theme.surfaceColor)

      Section("Appearance") {
        ThemePickerView(
          manager: model.themeManager,
          title: nil,
          onRequestUpgrade: { showThemeUpsell = true }
        )
      }
      .listRowBackground(theme.surfaceColor)

      Section("New Chats") {
        NavigationLink {
          DefaultSystemPromptView(preferences: model.preferences, chats: model.chats)
        } label: {
          LabeledContent("Default System Prompt") {
            Text(model.preferences.hasDefaultSystemPrompt ? "Configured" : "None")
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        }
      }
      .listRowBackground(theme.surfaceColor)

      Section {
        Button("Delete All Conversations", systemImage: "trash", role: .destructive) {
          confirmDeleteConversations = true
        }
        Button("Delete All Credentials", systemImage: "key.slash", role: .destructive) {
          confirmDeleteCredentials = true
        }

        if model.dataPortability.isBusy {
          HStack(spacing: 10) {
            ProgressView()
            Text("Working…")
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        }
      } header: {
        Text("Data Management")
      } footer: {
        Text(
          "Deleting conversations keeps your connections, projects, and Library files. Deleting credentials removes stored API keys and MCP tokens from Keychain."
        )
        .foregroundStyle(theme.secondaryForegroundColor)
      }
      .disabled(model.dataPortability.isBusy)
      .listRowBackground(theme.surfaceColor)

      Section {
        Toggle("Share Anonymous Usage Data", isOn: $shareUsageData)
          .onChange(of: shareUsageData) { _, enabled in
            Task { await BYOKAppAnalytics.setEnabled(enabled) }
          }
      } header: {
        Text("Analytics")
      } footer: {
        Text("Sends anonymous product usage counters to help improve BYOKchat. Messages, prompts, and file names are never collected.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

      Section("About") {
        Link(destination: URL(string: "https://spokiostudio.com/byokchat")!) {
          Label("Website", systemImage: "globe")
        }
        Link(destination: URL(string: "https://spokiostudio.com/byokchat/contact")!) {
          Label("Contact Us", systemImage: "envelope")
        }
        Link(destination: URL(string: "https://spokiostudio.com/byokchat/privacy")!) {
          Label("Privacy Policy", systemImage: "hand.raised")
        }
        Link(destination: URL(string: "https://spokiostudio.com/byokchat/terms")!) {
          Label("Terms of Use", systemImage: "doc.text")
        }
        LabeledContent {
          Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"))")
            .foregroundStyle(theme.secondaryForegroundColor)
        } label: {
          Label("App Version", systemImage: "info.circle")
        }
      }
      .listRowBackground(theme.surfaceColor)

      #if DEBUG
      Section("Developer") {
        NavigationLink {
          BYOKDeveloperToolsView(purchases: purchases)
        } label: {
          Label("Developer Tools", systemImage: "hammer")
        }
      }
      .listRowBackground(theme.surfaceColor)
      #endif
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
  }
}

private struct DefaultSystemPromptView: View {
  @Bindable var preferences: AppPreferencesModel
  let chats: ChatManagementModel

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @State private var text: String
  @State private var lastSyncedPreference: String
  @State private var confirmClear = false
  @FocusState private var isEditorFocused: Bool

  init(preferences: AppPreferencesModel, chats: ChatManagementModel) {
    self.preferences = preferences
    self.chats = chats
    let initial = AppPreferencesModel.normalizedSystemPrompt(preferences.defaultSystemPrompt)
    _text = State(initialValue: initial)
    _lastSyncedPreference = State(initialValue: initial)
  }

  private var trimmedText: String {
    AppPreferencesModel.normalizedSystemPrompt(text)
  }

  var body: some View {
    Form {
      Section {
        ZStack(alignment: .topLeading) {
          TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 220)
            .focused($isEditorFocused)
            .accessibilityLabel("Default System Prompt")

          if text.isEmpty {
            Text("e.g. Be concise, direct, and explain trade-offs clearly.")
              .font(.body)
              .foregroundStyle(theme.secondaryForegroundColor.opacity(0.65))
              .padding(.top, 8)
              .padding(.leading, 5)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
      } footer: {
        Text(
          "Copied into new conversations unless a project defines its own instructions. Existing conversations with messages are unchanged."
        )
        .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

      Section {
        Button("Clear Prompt", role: .destructive) {
          confirmClear = true
        }
        .disabled(trimmedText.isEmpty)
      }
      .listRowBackground(theme.surfaceColor)
    }
    .scrollDismissesKeyboard(.interactively)
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Default System Prompt")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if isEditorFocused {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            isEditorFocused = false
            text = trimmedText
            commitIfNeeded()
          }
          .fontWeight(.semibold)
        }
      }
    }
    .alert("Clear default system prompt?", isPresented: $confirmClear) {
      Button("Cancel", role: .cancel) {}
      Button("Clear", role: .destructive) {
        isEditorFocused = false
        text = ""
        commitIfNeeded()
      }
    } message: {
      Text("New conversations will start without a default system prompt.")
    }
    .task(id: text) {
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      commitIfNeeded()
    }
    .onChange(of: preferences.defaultSystemPrompt) { _, updated in
      let normalized = AppPreferencesModel.normalizedSystemPrompt(updated)
      guard normalized != lastSyncedPreference else { return }
      lastSyncedPreference = normalized
      text = normalized
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active {
        commitIfNeeded()
      }
    }
    .onDisappear {
      commitIfNeeded()
    }
  }

  private func commitIfNeeded() {
    let normalized = trimmedText
    let previous = AppPreferencesModel.normalizedSystemPrompt(preferences.defaultSystemPrompt)
    lastSyncedPreference = normalized
    if preferences.defaultSystemPrompt != normalized {
      preferences.defaultSystemPrompt = normalized
    }
    if previous != normalized {
      Task {
        await chats.syncDefaultSystemPrompt(from: previous, to: normalized)
      }
    }
  }
}
