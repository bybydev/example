import AppKit
import BYOKchatProviderCore
import SwiftUI
import UniformTypeIdentifiers

struct MacDataManagementView: View {
  let app: MacAppModel
  @Bindable var data: MacDataManagementModel

  @State private var pendingImport: PendingImport?
  @State private var confirmClearThumbnails = false
  @State private var confirmClearSearchIndex = false
  @State private var confirmPurgeQuarantined = false
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

  private var report: BYOKStorageUsageReport? {
    data.storageReport
  }

  private var quarantinedCount: Int {
    max(report?.quarantinedCount ?? 0, data.quarantinedShardCount)
  }

  private var conversationCount: Int {
    app.chats?.conversationSummaries.count ?? 0
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        storageUsageSection

        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Full backup")
              Text("Portable JSON backup of conversations, attachments, projects, Library items, MCP configuration, connections, and default system prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 8) {
              Spacer()
              Button("Export…") {
                exportBackup()
              }
              .buttonStyle(MacSettingsButtonStyle())

              Button("Import…") {
                chooseImport(kind: .backup)
              }
              .buttonStyle(MacSettingsButtonStyle())
            }
            .disabled(data.isBusy)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Connection configuration")
              Text("Export or import provider account configuration without chat history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 8) {
              Spacer()
              Button("Export…") {
                exportProviderConfiguration()
              }
              .buttonStyle(MacSettingsButtonStyle())

              Button("Import…") {
                chooseImport(kind: .providers)
              }
              .buttonStyle(MacSettingsButtonStyle())
            }
            .disabled(data.isBusy)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Workspace location")
              Text(app.storageEnvironment.rootDirectory.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Divider()

            HStack(spacing: 8) {
              Spacer()
              if app.lastRecoveryBackupURL != nil {
                Button("Last Recovery Backup") {
                  app.revealRecoveryBackup()
                }
                .buttonStyle(MacSettingsButtonStyle())
              }

              Button("Show in Finder") {
                app.revealDataDirectory()
              }
              .buttonStyle(MacSettingsButtonStyle())
            }

            Text("Startup recovery and full reset preserve the previous workspace by moving it aside before creating a fresh one.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("Delete all conversations")
              Spacer()
              Button("Delete…", role: .destructive) {
                confirmDeleteConversations = true
              }
              .buttonStyle(MacSettingsButtonStyle(isDestructive: true))
            }

            Divider()

            HStack {
              Text("Delete all credentials")
              Spacer()
              Button("Delete…", role: .destructive) {
                confirmDeleteCredentials = true
              }
              .buttonStyle(MacSettingsButtonStyle(isDestructive: true))
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text("Reset all application data")
                Spacer()
                Button("Reset…", role: .destructive) {
                  confirmResetApplication = true
                }
                .buttonStyle(MacSettingsButtonStyle(isDestructive: true))
              }

              Text("Moves the workspace to a recovery folder first, then removes provider/MCP credentials and telemetry. Keychain credentials cannot be recovered from the workspace backup.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .disabled(data.isBusy)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
        }

        if data.isBusy {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 4)
        } else if let status = data.statusMessage {
          Label(status, systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }

        Text("Backups and connection exports never include API keys, secret headers, or MCP credentials.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
      }
      .padding(.vertical, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task {
      await data.refreshStorageUsage()
    }
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
      "Clear cached thumbnails?",
      isPresented: $confirmClearThumbnails,
      titleVisibility: .visible
    ) {
      Button("Clear Cached Thumbnails", role: .destructive) {
        Task { await data.clearThumbnailCache() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Thumbnails regenerate automatically when needed. Your chats, original attachments, and Library files are not deleted.")
    }
    .confirmationDialog(
      "Clear search index?",
      isPresented: $confirmClearSearchIndex,
      titleVisibility: .visible
    ) {
      Button("Clear Search Index", role: .destructive) {
        Task { await data.clearSearchIndex() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The full-text search index will be deleted and rebuilt automatically the next time you search conversations.")
    }
    .confirmationDialog(
      "Remove unreadable chat files?",
      isPresented: $confirmPurgeQuarantined,
      titleVisibility: .visible
    ) {
      Button("Remove Unreadable Shards", role: .destructive) {
        Task { await data.purgeQuarantinedConversations() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently deletes \(quarantinedCount) quarantined file\(quarantinedCount == 1 ? "" : "s") that could not be decoded. Healthy conversations are unaffected.")
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

  private var storageUsageSection: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Storage usage")
          Spacer()
          if data.isMeasuringStorage {
            ProgressView()
              .controlSize(.small)
          }
          Button("Refresh") {
            Task { await data.refreshStorageUsage() }
          }
          .buttonStyle(MacSettingsButtonStyle())
          .disabled(data.isMeasuringStorage || data.isBusy)
        }

        if let report, report.hasCleanupWarning || quarantinedCount > 0 {
          VStack(alignment: .leading, spacing: 8) {
            if report.isDeviceSpaceLow {
              warningRow(
                icon: "externaldrive.badge.exclamationmark",
                title: "Mac storage is running low",
                detail: "Less than 250 MB is available on this Mac. Clear cached thumbnails or remove large chats and files to avoid failed saves."
              )
            }
            if report.isStorageLarge {
              warningRow(
                icon: "internaldrive",
                title: "Local data is over 500 MB",
                detail: "Consider clearing cached thumbnails or removing older conversations and unused Library files you no longer need."
              )
            }
            if quarantinedCount > 0 {
              warningRow(
                icon: "doc.badge.exclamationmark",
                title: "\(quarantinedCount) unreadable chat \(quarantinedCount == 1 ? "file" : "files") quarantined",
                detail: "Corrupted conversation files were set aside so the rest of your history stays safe. You can remove them below to reclaim space."
              )
            }
          }
        }

        Divider()

        if let report {
          VStack(alignment: .leading, spacing: 6) {
            sizeRow("Chats (\(conversationCount))", bytes: report.conversationsBytes)
            sizeRow("Files & attachments", bytes: report.attachmentsBytes)
            sizeRow("Cached thumbnails", bytes: report.thumbnailCacheBytes)
            sizeRow("Search index", bytes: report.searchIndexBytes)
            sizeRow("Analytics & settings", bytes: report.analyticsBytes + report.otherBytes)
            if report.quarantinedBytes > 0 || quarantinedCount > 0 {
              sizeRow("Quarantined files", bytes: report.quarantinedBytes)
            }

            Divider()
              .padding(.vertical, 2)

            HStack {
              Text("Total used")
                .fontWeight(.medium)
              Spacer()
              Text(formattedBytes(report.totalBytes))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }

            if let available = report.availableDeviceBytes {
              HStack {
                Text("Available on Mac")
                  .foregroundStyle(.secondary)
                Spacer()
                Text(formattedBytes(available))
                  .font(.system(size: 12, weight: .medium, design: .monospaced))
                  .foregroundStyle(report.isDeviceSpaceLow ? Color.orange : Color.secondary)
              }
            }
          }
        } else {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Calculating storage…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Divider()

        HStack {
          Text("Cached thumbnails")
          Spacer()
          Button("Clear…") {
            confirmClearThumbnails = true
          }
          .buttonStyle(MacSettingsButtonStyle())
          .disabled(data.isBusy || (report?.thumbnailCacheBytes ?? 0) == 0)
        }

        Divider()

        HStack {
          Text("Search index")
          Spacer()
          Button("Clear…") {
            confirmClearSearchIndex = true
          }
          .buttonStyle(MacSettingsButtonStyle())
          .disabled(data.isBusy || (report?.searchIndexBytes ?? 0) == 0)
        }

        if quarantinedCount > 0 {
          Divider()

          HStack {
            Text("Unreadable shards (\(quarantinedCount))")
            Spacer()
            Button("Remove…", role: .destructive) {
              confirmPurgeQuarantined = true
            }
            .buttonStyle(MacSettingsButtonStyle(isDestructive: true))
            .disabled(data.isBusy)
          }
        }

        Text("Cached thumbnails and the search index regenerate automatically when needed. Clearing cached thumbnails never deletes your chats, original attachments, or Library files.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
    }
  }

  private func sizeRow(_ title: String, bytes: Int64) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(formattedBytes(bytes))
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
    }
  }

  private func warningRow(icon: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: icon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.orange)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.orange.opacity(0.1),
      in: RoundedRectangle(cornerRadius: 6, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(Color.orange.opacity(0.28), lineWidth: 1)
    }
  }

  private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
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
      MacAppAnalytics.reportError("data_export_write_failed", component: "data")
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
