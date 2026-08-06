import BYOKchatProviderCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @Bindable var model: AppModel

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

  private enum ImportKind {
    case backup
    case providers
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("AI Providers") {
          NavigationLink {
            ProviderListView(model: model.providers)
          } label: {
            Label("Providers & Accounts", systemImage: "key.horizontal")
          }

          NavigationLink {
            ProviderConsoleView(model: model.providers)
          } label: {
            Label("Provider Console", systemImage: "terminal")
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

        Section("Data Portability") {
          Button("Export Full Backup", systemImage: "archivebox") {
            Task {
              guard let document = await model.dataPortability.makeBackupDocument() else { return }
              backupDocument = document
              showBackupExporter = true
            }
          }

          Button("Import Full Backup", systemImage: "square.and.arrow.down") {
            importKind = .backup
            showImportStrategy = true
          }

          Button("Export Provider Configuration", systemImage: "key.viewfinder") {
            Task {
              guard
                let document = await model.dataPortability.makeProviderConfigurationDocument()
              else { return }
              providerDocument = document
              showProviderExporter = true
            }
          }

          Button("Import Provider Configuration", systemImage: "key.radiowaves.forward") {
            importKind = .providers
            showImportStrategy = true
          }
        } footer: {
          Text("Backups and provider configuration never include API keys or secret headers.")
        }

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

        Section("About") {
          LabeledContent("Storage", value: "Local on this iPhone")
          LabeledContent("Credentials", value: "Keychain")
          Text("Requests go directly to the provider account selected for each conversation.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Settings")
    }
    .confirmationDialog("How should imported data be applied?", isPresented: $showImportStrategy) {
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
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else {
        if case .failure(let error) = result {
          model.dataPortability.errorMessage = error.localizedDescription
        }
        return
      }
      Task {
        switch importKind {
        case .backup:
          await model.dataPortability.importBackup(from: url, strategy: importStrategy)
        case .providers:
          await model.dataPortability.importProviderConfiguration(
            from: url, strategy: importStrategy)
        }
      }
    }
    .fileExporter(
      isPresented: $showBackupExporter,
      document: backupDocument,
      contentType: .json,
      defaultFilename: "BYOKchat-backup"
    ) { result in
      if case .failure(let error) = result {
        model.dataPortability.errorMessage = error.localizedDescription
      }
    }
    .fileExporter(
      isPresented: $showProviderExporter,
      document: providerDocument,
      contentType: .json,
      defaultFilename: "BYOKchat-providers"
    ) { result in
      if case .failure(let error) = result {
        model.dataPortability.errorMessage = error.localizedDescription
      }
    }
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
      Text("Provider accounts remain configured, but every API key must be entered again.")
    }
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
