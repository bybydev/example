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
          DefaultSystemPromptView(preferences: model.preferences)
        } label: {
          LabeledContent("Default System Prompt") {
            Text(model.preferences.defaultSystemPrompt.isEmpty ? "None" : "Configured")
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
  @Environment(\.appFoundationTheme) private var theme
  @State private var text: String

  init(preferences: AppPreferencesModel) {
    self.preferences = preferences
    _text = State(initialValue: preferences.defaultSystemPrompt)
  }

  var body: some View {
    Form {
      Section {
        TextEditor(text: $text)
          .frame(minHeight: 220)
      } footer: {
        Text("This prompt is copied into new conversations. Existing conversations are unchanged.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

      Section {
        Button("Clear", role: .destructive) { text = "" }
      }
      .listRowBackground(theme.surfaceColor)
    }
    .scrollDismissesKeyboard(.interactively)
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Default Prompt")
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: text) { _, value in preferences.defaultSystemPrompt = value }
  }
}
