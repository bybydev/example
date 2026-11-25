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
      VStack(alignment: .leading, spacing: 18) {
        storageUsageSection

        GroupBox("Full Backup") {
          VStack(alignment: .leading, spacing: 12) {
            Text("A portable JSON backup includes conversations, attachments, projects, Library items, MCP configuration, connection configuration, and the default system prompt.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)

            HStack(spacing: 8) {
              Button("Export Full Backup…", systemImage: "archivebox") {
                exportBackup()
              }
              .buttonStyle(MacActionButtonStyle(.secondary))
              Button("Import Full Backup…", systemImage: "square.and.arrow.down") {
                chooseImport(kind: .backup)
              }
              .buttonStyle(MacActionButtonStyle(.secondary))
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

            HStack(spacing: 8) {
              Button("Export Connections…", systemImage: "key.viewfinder") {
                exportProviderConfiguration()
              }
              .buttonStyle(MacActionButtonStyle(.secondary))
              Button("Import Connections…", systemImage: "key.radiowaves.forward") {
                chooseImport(kind: .providers)
              }
              .buttonStyle(MacActionButtonStyle(.secondary))
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

            HStack(spacing: 8) {
              Button("Show Data in Finder", systemImage: "folder") {
                app.revealDataDirectory()
              }
              .buttonStyle(MacActionButtonStyle(.secondary))
              if app.lastRecoveryBackupURL != nil {
                Button("Show Last Recovery Backup", systemImage: "clock.arrow.circlepath") {
                  app.revealRecoveryBackup()
                }
                .buttonStyle(MacActionButtonStyle(.secondary))
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
            .buttonStyle(MacActionButtonStyle(.destructive))

            Button("Delete All Credentials", systemImage: "key.slash", role: .destructive) {
              confirmDeleteCredentials = true
            }
            .buttonStyle(MacActionButtonStyle(.destructive))

            Divider()

            Button("Reset All Application Data…", systemImage: "arrow.counterclockwise.circle", role: .destructive) {
              confirmResetApplication = true
            }
            .buttonStyle(MacActionButtonStyle(.destructive))

            Text("Reset moves the workspace to a recovery folder first, then removes provider/MCP credentials and telemetry. Keychain credentials cannot be recovered from the workspace backup.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .disabled(data.isBusy)
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
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Storage Usage")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)

          Spacer()

          if data.isMeasuringStorage {
            ProgressView()
              .controlSize(.small)
          }

          Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await data.refreshStorageUsage() }
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
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

        if let report {
          VStack(alignment: .leading, spacing: 8) {
            sizeRow("Chats (\(conversationCount))", bytes: report.conversationsBytes)
            sizeRow("Files & Attachments", bytes: report.attachmentsBytes)
            sizeRow("Cached Thumbnails", bytes: report.thumbnailCacheBytes)
            sizeRow("Search Index", bytes: report.searchIndexBytes)
            sizeRow("Analytics & Settings", bytes: report.analyticsBytes + report.otherBytes)
            if report.quarantinedBytes > 0 || quarantinedCount > 0 {
              sizeRow("Quarantined Files", bytes: report.quarantinedBytes)
            }

            Divider()

            LabeledContent("Total Used") {
              Text(formattedBytes(report.totalBytes))
                .fontWeight(.semibold)
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            }

            if let available = report.availableDeviceBytes {
              LabeledContent("Available on Mac") {
                Text(formattedBytes(available))
                  .foregroundStyle(
                    report.isDeviceSpaceLow ? Color.orange : MacDesignTokens.Colors.textMuted
                  )
              }
            }
          }
        } else {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Calculating storage…")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }

        Divider()

        HStack(spacing: 10) {
          Button("Clear Cached Thumbnails…", systemImage: "photo.on.rectangle.angled") {
            confirmClearThumbnails = true
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          .disabled(data.isBusy || (report?.thumbnailCacheBytes ?? 0) == 0)

          Button("Clear Search Index…", systemImage: "magnifyingglass") {
            confirmClearSearchIndex = true
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          .disabled(data.isBusy || (report?.searchIndexBytes ?? 0) == 0)

          if quarantinedCount > 0 {
            Button(
              "Remove Unreadable Shards (\(quarantinedCount))…",
              systemImage: "trash",
              role: .destructive
            ) {
              confirmPurgeQuarantined = true
            }
            .buttonStyle(MacActionButtonStyle(.destructive, size: .small))
            .disabled(data.isBusy)
          }
        }

        Text("Cached thumbnails and the search index regenerate automatically when needed. Clearing cached thumbnails never deletes your chats, original attachments, or Library files.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
  }

  private func sizeRow(_ title: String, bytes: Int64) -> some View {
    LabeledContent(title) {
      Text(formattedBytes(bytes))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
  }

  private func warningRow(icon: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.orange)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        Text(detail)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.orange.opacity(0.1),
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
        .stroke(Color.orange.opacity(0.28), lineWidth: 1)
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
