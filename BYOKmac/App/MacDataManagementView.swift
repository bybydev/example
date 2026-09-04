import AppKit
import BYOKchatProviderCore
import SwiftUI
import UniformTypeIdentifiers

struct MacDataManagementView: View {
  let app: MacAppModel
  @Bindable var data: MacDataManagementModel

  @State private var pendingImport: PendingImport?
  @State private var confirmDeleteConversations = false
  @State private var confirmDeleteCredentials = false
  @State private var confirmResetApplication = false

  private struct PendingImport: Identifiable {
    enum Kind: Equatable {
      case backup
      case providers

      var title: String {
        switch self {
        case .backup: "Import Full Backup"
        case .providers: "Import Connection Configuration"
        }
      }
    }

    let id = UUID()
    let kind: Kind
    let url: URL
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        GroupBox("Full Backup") {
          VStack(alignment: .leading, spacing: 12) {
            Text("A portable JSON backup includes conversations, attachments, projects, Library items, MCP configuration, connection configuration, and the default system prompt.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)

            HStack {
              Button("Export Full Backup…", systemImage: "archivebox") {
                exportBackup()
              }
              Button("Import Full Backup…", systemImage: "square.and.arrow.down") {
                chooseImport(kind: .backup)
              }
            }
            .disabled(data.isBusy)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
        }

        GroupBox("Connection Configuration") {
          VStack(alignment: .leading, spacing: 12) {
            Text("Export or import provider account configuration without chat history.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)

            HStack {
              Button("Export Connections…", systemImage: "key.viewfinder") {
                exportProviderConfiguration()
              }
              Button("Import Connections…", systemImage: "key.radiowaves.forward") {
                chooseImport(kind: .providers)
              }
            }
            .disabled(data.isBusy)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
        }

        GroupBox("Local Storage & Recovery") {
          VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Storage") {
              Text(app.storageEnvironment.rootDirectory.path)
                .font(.caption.monospaced())
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            HStack {
              Button("Show Data in Finder", systemImage: "folder") {
                app.revealDataDirectory()
              }
              if app.lastRecoveryBackupURL != nil {
                Button("Show Last Recovery Backup", systemImage: "clock.arrow.circlepath") {
                  app.revealRecoveryBackup()
                }
              }
            }

            Text("Startup recovery and full reset preserve the previous workspace by moving it aside before creating a fresh one.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
        }

        GroupBox("Destructive Actions") {
          VStack(alignment: .leading, spacing: 12) {
            Button("Delete All Conversations", systemImage: "trash", role: .destructive) {
              confirmDeleteConversations = true
            }

            Button("Delete All Credentials", systemImage: "key.slash", role: .destructive) {
              confirmDeleteCredentials = true
            }

            Divider()

            Button("Reset All Application Data…", systemImage: "arrow.counterclockwise.circle", role: .destructive) {
              confirmResetApplication = true
            }

            Text("Reset moves the workspace to a recovery folder first, then removes provider/MCP credentials and telemetry. Keychain credentials cannot be recovered from the workspace backup.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
        }

        if data.isBusy {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        } else if let status = data.statusMessage {
          Label(status, systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        Text("Backups and connection exports never include API keys, secret headers, or MCP credentials.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .padding(20)
      .frame(maxWidth: 720, alignment: .leading)
    }
    .background(MacDesignTokens.Colors.canvas)
    .confirmationDialog(
      pendingImport?.kind.title ?? "Import Data",
      isPresented: Binding(
        get: { pendingImport != nil },
        set: { if !$0 { pendingImport = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Merge with Existing") {
        runPendingImport(strategy: .keepExisting)
      }
      Button("Replace Existing", role: .destructive) {
        runPendingImport(strategy: .replaceExisting)
      }
      Button("Cancel", role: .cancel) { pendingImport = nil }
    } message: {
      if pendingImport?.kind == .backup {
        Text("Merge keeps existing local data where possible. Replace uses the backup as the authoritative provider/chat/project/library state. Credentials are never imported.")
      } else {
        Text("Merge keeps existing connections. Replace uses the imported connection configuration as authoritative. Credentials are never imported.")
      }
    }
    .confirmationDialog(
      "Delete all conversations?",
      isPresented: $confirmDeleteConversations,
      titleVisibility: .visible
    ) {
      Button("Delete All Conversations", role: .destructive) {
        Task { await data.deleteAllConversations() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Projects, provider connections, Library items, and credentials remain. Conversation history cannot be recovered unless it exists in a backup.")
    }
    .confirmationDialog(
      "Delete all credentials?",
      isPresented: $confirmDeleteCredentials,
      titleVisibility: .visible
    ) {
      Button("Delete All Credentials", role: .destructive) {
        Task { await data.deleteAllCredentials() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Connections and MCP servers remain configured, but every API key and MCP credential must be entered again.")
    }
    .confirmationDialog(
      "Reset all BYOKchat data?",
      isPresented: $confirmResetApplication,
      titleVisibility: .visible
    ) {
      Button("Reset and Keep Workspace Backup", role: .destructive) {
        Task { await data.resetApplicationDataKeepingBackup() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The current workspace is moved to a recovery folder before reset. Provider/MCP credentials and telemetry are then deleted and cannot be recovered from that folder.")
    }
    .alert(
      "Data Operation Failed",
      isPresented: Binding(
        get: { data.errorMessage != nil },
        set: { if !$0 { data.errorMessage = nil } }
      )
    ) {
      Button("OK") { data.errorMessage = nil }
    } message: {
      Text(data.errorMessage ?? "Unknown error")
    }
  }

  private func exportBackup() {
    Task { @MainActor in
      guard let bytes = await data.makeBackupData() else { return }
      saveJSON(bytes, suggestedName: "BYOKchat-backup")
    }
  }

  private func exportProviderConfiguration() {
    Task { @MainActor in
      guard let bytes = await data.makeProviderConfigurationData() else { return }
      saveJSON(bytes, suggestedName: "BYOKchat-connections")
    }
  }

  private func saveJSON(_ dataBytes: Data, suggestedName: String) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "\(suggestedName)-\(Self.fileDate).json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try dataBytes.write(to: url, options: .atomic)
      data.statusMessage = "Exported \(url.lastPathComponent)"
    } catch {
      data.errorMessage = error.localizedDescription
    }
  }

  private func chooseImport(kind: PendingImport.Kind) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    pendingImport = PendingImport(kind: kind, url: url)
  }

  private func runPendingImport(strategy: ProviderImportStrategy) {
    guard let pending = pendingImport else { return }
    pendingImport = nil
    Task { @MainActor in
      switch pending.kind {
      case .backup:
        await data.importBackup(from: pending.url, strategy: strategy)
      case .providers:
        await data.importProviderConfiguration(from: pending.url, strategy: strategy)
      }
    }
  }

  private static var fileDate: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: .now)
  }
}
