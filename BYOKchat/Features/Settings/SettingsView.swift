import AppFoundation
import BYOKchatProviderCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @Bindable var model: AppModel
  let purchases: BYOKPurchaseStore

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @AppStorage("byokchat.onboarding.completed.v1") private var hasCompletedOnboarding = true
  @State private var backupDocument: JSONExportDocument?
  @State private var providerDocument: JSONExportDocument?
  @State private var showBackupExporter = false
  @State private var showProviderExporter = false
  @State private var showImporter = false
  @State private var showImportStrategy = false
  @State private var importKind: ImportKind = .backup
  @State private var importStrategy: ProviderImportStrategy = .keepExisting
  @State private var confirmDeleteConversations = false
  @State private var confirmDeleteCredentials = false
  @State private var showThemeUpsell = false

  private enum ImportKind {
    case backup
    case providers
  }

  var body: some View {
    failureAlertView
      .sheet(isPresented: $showThemeUpsell) {
        BYOKProUpsellFlow(feature: .themes)
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

  private var importConfiguredView: some View {
    navigationContent
      .confirmationDialog(
        "How should imported data be applied?",
        isPresented: $showImportStrategy
      ) {
        Button("Merge, Keep Existing") {
          importStrategy = .keepExisting
          showImporter = true
        }
        Button("Replace Existing", role: .destructive) {
          importStrategy = .replaceExisting
          showImporter = true
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Replace removes matching local configuration. Imported credentials must be entered again."
        )
      }
      .fileImporter(
        isPresented: $showImporter,
        allowedContentTypes: [.json],
        allowsMultipleSelection: false,
        onCompletion: handleImportResult
      )
  }

  private var exportConfiguredView: some View {
    importConfiguredView
      .fileExporter(
        isPresented: $showBackupExporter,
        document: backupDocument,
        contentType: .json,
        defaultFilename: "BYOKchat-backup",
        onCompletion: handleExportResult
      )
      .fileExporter(
        isPresented: $showProviderExporter,
        document: providerDocument,
        contentType: .json,
        defaultFilename: "BYOKchat-providers",
        onCompletion: handleExportResult
      )
  }

  private var deletionConfiguredView: some View {
    exportConfiguredView
      .alert("Delete all conversations?", isPresented: $confirmDeleteConversations) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) {
          Task { await model.dataPortability.deleteAllConversations() }
        }
      } message: {
        Text("This removes every locally stored conversation and cannot be undone without a backup.")
      }
      .alert("Delete all credentials?", isPresented: $confirmDeleteCredentials) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) {
          Task { await model.dataPortability.deleteAllCredentials() }
        }
      } message: {
        Text("Connections remain configured, but every API key and MCP credential must be entered again.")
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
      Section("Appearance") {
        ThemePickerView(
          manager: model.themeManager,
          title: nil,
          onRequestUpgrade: { showThemeUpsell = true }
        )
      }

      Section("AI") {
        NavigationLink {
          ConnectionsView(model: model.providers)
        } label: {
          Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
        }
      }

      Section("Tools & MCP") {
        NavigationLink {
          MCPServerListView(model: model.mcp)
        } label: {
          Label("MCP Servers", systemImage: "shippingbox.and.arrow.backward")
        }
      }

      Section("New Chats") {
        NavigationLink {
          DefaultSystemPromptView(preferences: model.preferences)
        } label: {
          LabeledContent("Default System Prompt") {
            Text(model.preferences.defaultSystemPrompt.isEmpty ? "None" : "Configured")
              .foregroundStyle(.secondary)
          }
        }
      }

      Section {
        Toggle(
          "Sync Projects with iCloud",
          isOn: Binding(
            get: { model.projectSync.isEnabled },
            set: { enabled in
              Task { @MainActor in await model.projectSync.setEnabled(enabled) }
            }
          )
        )
        .disabled(model.projectSync.isSyncing)

        LabeledContent("Status", value: projectSyncStatusText)

        if model.projectSync.isEnabled {
          Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
            Task { @MainActor in await model.projectSync.syncNow() }
          }
          .disabled(model.projectSync.isSyncing)
        }
      } header: {
        Text("iCloud Projects")
      } footer: {
        Text("Syncs project instructions, files, presets, and tool defaults. Chat history and credentials remain local to this device.")
      }

      Section {
        Button("Export Full Backup", systemImage: "archivebox") {
          exportBackup()
        }

        Button("Import Full Backup", systemImage: "square.and.arrow.down") {
          importKind = .backup
          showImportStrategy = true
        }

        Button("Export Connection Configuration", systemImage: "key.viewfinder") {
          exportProviderConfiguration()
        }

        Button("Import Connection Configuration", systemImage: "key.radiowaves.forward") {
          importKind = .providers
          showImportStrategy = true
        }
      } header: {
        Text("Data Portability")
      } footer: {
        Text("Backups and connection configuration never include API keys or secret headers.")
      }

      TelemetrySettingsSection()

      Section("Destructive Actions") {
        Button("Delete All Conversations", systemImage: "trash", role: .destructive) {
          confirmDeleteConversations = true
        }
        Button("Delete All Credentials", systemImage: "key.slash", role: .destructive) {
          confirmDeleteCredentials = true
        }
      }

      if let status = model.dataPortability.statusMessage {
        Section("Last Data Operation") {
          Text(status)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      #if DEBUG
      DeveloperSettingsSection(purchases: purchases) {
        hasCompletedOnboarding = false
        dismiss()
      }

      Section("Developer Tools") {
        NavigationLink {
          ProviderConsoleView(model: model.providers)
        } label: {
          Label("Provider Console", systemImage: "terminal")
        }
      }
      #endif

      Section("About") {
        LabeledContent("Storage", value: "Local on this iPhone")
        LabeledContent("Credentials", value: "Keychain")
        Text("Requests go directly through the connection or remote MCP endpoint selected by the app.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .scrollContentBackground(.hidden)
    .background(theme.backgroundColor)
  }

  private var projectSyncStatusText: String {
    if model.projectSync.isSyncing { return "Syncing…" }
    if !model.projectSync.isEnabled { return "Off" }
    if let date = model.projectSync.lastSyncedAt {
      return "Last synced \(date.formatted(.relative(presentation: .named)))"
    }
    return "On"
  }

  private func exportBackup() {
    Task { @MainActor in
      guard let document = await model.dataPortability.makeBackupDocument() else { return }
      backupDocument = document
      showBackupExporter = true
    }
  }

  private func exportProviderConfiguration() {
    Task { @MainActor in
      guard let document = await model.dataPortability.makeProviderConfigurationDocument() else {
        return
      }
      providerDocument = document
      showProviderExporter = true
    }
  }

  private func handleImportResult(_ result: Result<[URL], any Error>) {
    guard case .success(let urls) = result, let url = urls.first else {
      if case .failure(let error) = result {
        model.dataPortability.errorMessage = error.localizedDescription
      }
      return
    }

    Task { @MainActor in
      switch importKind {
      case .backup:
        await model.dataPortability.importBackup(from: url, strategy: importStrategy)
      case .providers:
        await model.dataPortability.importProviderConfiguration(
          from: url,
          strategy: importStrategy
        )
      }
    }
  }

  private func handleExportResult(_ result: Result<URL, any Error>) {
    if case .failure(let error) = result {
      model.dataPortability.errorMessage = error.localizedDescription
    }
  }
}

private struct DefaultSystemPromptView: View {
  @Bindable var preferences: AppPreferencesModel
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
      }
      Section {
        Button("Clear", role: .destructive) { text = "" }
      }
    }
    .navigationTitle("Default Prompt")
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: text) { _, value in preferences.defaultSystemPrompt = value }
  }
}
