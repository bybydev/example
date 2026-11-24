import AppKit
import BYOKchatProviderCore
import Foundation
import SwiftUI

enum MacLibraryAttachmentPickerSupport {
  struct PreflightResult: Equatable, Sendable {
    let errorMessage: String?

    var isValid: Bool { errorMessage == nil }
  }

  static func capacityNote(existingCount: Int, selectedCount: Int) -> String {
    let maxSelectable = max(0, MacAttachmentImporter.maximumCount - existingCount)
    let remaining = max(0, maxSelectable - selectedCount)
    if remaining == 0 {
      return "Maximum of \(MacAttachmentImporter.maximumCount) attachments reached."
    }
    let noun = remaining == 1 ? "attachment" : "attachments"
    if existingCount > 0 || selectedCount > 0 {
      return "You can select up to \(remaining) more \(noun)."
    }
    return "You can select up to \(remaining) \(noun)."
  }

  static func preflight(
    existingCount: Int,
    existingBytes: Int,
    selectedByteCounts: [Int]
  ) -> PreflightResult {
    guard existingCount + selectedByteCounts.count <= MacAttachmentImporter.maximumCount else {
      return PreflightResult(
        errorMessage: "A message can include at most \(MacAttachmentImporter.maximumCount) attachments."
      )
    }
    guard selectedByteCounts.allSatisfy({ $0 > 0 && $0 <= MacAttachmentImporter.maximumFileBytes }) else {
      return PreflightResult(
        errorMessage: "Each attachment must contain bytes and be no larger than 20 MB."
      )
    }
    let totalBytes = existingBytes + selectedByteCounts.reduce(0, +)
    guard totalBytes <= MacAttachmentImporter.maximumTotalBytes else {
      return PreflightResult(
        errorMessage: "Attachments in one message cannot exceed 40 MB total."
      )
    }
    return PreflightResult(errorMessage: nil)
  }
}

struct MacLibraryAttachmentPickerView: View {
  @Bindable var workspace: MacWorkspaceModel
  let excludedIDs: Set<String>
  var existingAttachmentByteCount: Int = 0
  let attach: ([ChatAttachment]) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(MacChatSessionModel.self) private var chats
  @State private var tab: Tab = .saved
  @State private var savedSelection: Set<LibraryEntryID> = []
  @State private var chatSelection: Set<String> = []
  @State private var searchText = ""
  @State private var isLoading = false
  @State private var errorMessage: String?

  private enum Tab: String, CaseIterable, Identifiable {
    case saved = "Saved"
    case fromChats = "From Chats"

    var id: String { rawValue }
  }

  private struct ChatItem: Identifiable {
    let attachment: ChatAttachment
    let conversationTitle: String
    let date: Date

    var id: String { attachment.id }
  }

  private var allAvailableEntries: [LibraryEntry] {
    workspace.libraryEntries
      .filter { !excludedIDs.contains($0.id.rawValue) }
      .sorted { $0.createdAt > $1.createdAt }
  }

  private var availableEntries: [LibraryEntry] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return allAvailableEntries }
    return allAvailableEntries.filter {
      $0.filename.localizedCaseInsensitiveContains(query)
    }
  }

  /// Conversation summaries retain attachment metadata in the v2 index, so
  /// this list does not hydrate every chat just to populate the picker.
  private var allChatItems: [ChatItem] {
    var seen: Set<String> = []
    var values: [ChatItem] = []

    for conversation in chats.conversationSummaries {
      for message in conversation.messages {
        for attachment in message.attachments ?? []
        where !excludedIDs.contains(attachment.id) && seen.insert(attachment.id).inserted
        {
          let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
          values.append(
            ChatItem(
              attachment: attachment,
              conversationTitle: title.isEmpty ? "Chat" : title,
              date: message.createdAt
            )
          )
        }
      }
    }
    return values.sorted { $0.date > $1.date }
  }

  private var chatItems: [ChatItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return allChatItems }
    return allChatItems.filter { item in
      item.attachment.filename.localizedCaseInsensitiveContains(query)
        || item.conversationTitle.localizedCaseInsensitiveContains(query)
    }
  }

  private var activeSavedSelection: Set<LibraryEntryID> {
    savedSelection.intersection(Set(allAvailableEntries.map(\.id)))
  }

  private var activeChatSelection: Set<String> {
    chatSelection.intersection(Set(allChatItems.map(\.id)))
  }

  private var selectedUniqueIDs: Set<String> {
    Set(activeSavedSelection.map(\.rawValue)).union(activeChatSelection)
  }

  private var totalSelectionCount: Int {
    selectedUniqueIDs.count
  }

  private var maxSelectableCount: Int {
    max(0, MacAttachmentImporter.maximumCount - excludedIDs.count)
  }

  private var remainingSlots: Int {
    max(0, maxSelectableCount - totalSelectionCount)
  }

  private var capacityNote: String {
    MacLibraryAttachmentPickerSupport.capacityNote(
      existingCount: excludedIDs.count,
      selectedCount: totalSelectionCount
    )
  }

  private var activeErrorMessage: String? {
    errorMessage ?? workspace.errorMessage
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Attach from Library")
          .font(.headline)
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isLoading)
        Button(totalSelectionCount == 0 ? "Attach" : "Attach (\(totalSelectionCount))") { commit() }
          .keyboardShortcut(.defaultAction)
          .disabled(totalSelectionCount == 0 || isLoading)
      }
      .padding(16)

      Divider()

      VStack(spacing: 8) {
        Picker("Source", selection: $tab) {
          ForEach(Tab.allCases) { tab in
            Text(tab.rawValue).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .disabled(isLoading)

        HStack(spacing: 7) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Search files", text: $searchText)
            .textFieldStyle(.plain)
          if !searchText.isEmpty {
            Button {
              searchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search")
          }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
          RoundedRectangle(cornerRadius: 7)
            .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
        }

        Text(capacityNote)
          .font(.caption)
          .foregroundStyle(remainingSlots == 0 ? Color.orange : MacDesignTokens.Colors.textMuted)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(12)

      Divider()
      content
    }
    .frame(width: 600, height: 500)
    .background(MacDesignTokens.Colors.canvas)
    .overlay {
      if isLoading {
        ProgressView()
          .padding(12)
          .background(.regularMaterial, in: Capsule())
      }
    }
    .onChange(of: tab) { _, _ in
      searchText = ""
    }
    .onChange(of: excludedIDs) { _, ids in
      savedSelection = savedSelection.filter { !ids.contains($0.rawValue) }
      chatSelection.subtract(ids)
    }
    .alert(
      "Attachment Error",
      isPresented: Binding(
        get: { activeErrorMessage != nil },
        set: {
          if !$0 {
            errorMessage = nil
            workspace.errorMessage = nil
          }
        }
      )
    ) {
      Button("OK") {
        errorMessage = nil
        workspace.errorMessage = nil
      }
    } message: {
      Text(activeErrorMessage ?? "Unknown error")
    }
  }

  @ViewBuilder
  private var content: some View {
    switch tab {
    case .saved:
      if availableEntries.isEmpty {
        ContentUnavailableView(
          searchText.isEmpty ? "No Available Library Items" : "No Matches",
          systemImage: searchText.isEmpty ? "books.vertical" : "magnifyingglass",
          description: Text(searchText.isEmpty
            ? "Import files into Library or remove an already selected attachment."
            : "Try a different file name.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(availableEntries) { entry in
              savedRow(entry)
            }
          }
          .padding(10)
        }
      }

    case .fromChats:
      if chatItems.isEmpty {
        ContentUnavailableView(
          searchText.isEmpty ? "No Chat Attachments" : "No Matches",
          systemImage: searchText.isEmpty ? "paperclip" : "magnifyingglass",
          description: Text(searchText.isEmpty
            ? "Files attached to earlier chat messages will appear here."
            : "Try a different file or chat name.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(chatItems) { item in
              chatRow(item)
            }
          }
          .padding(10)
        }
      }
    }
  }

  private func savedRow(_ entry: LibraryEntry) -> some View {
    let isSelected = selectedUniqueIDs.contains(entry.id.rawValue)
    return selectableRow(
      title: entry.filename,
      detail: "\(entry.byteCountText) · \(entry.mimeType)",
      isSelected: isSelected,
      action: { toggleSaved(entry.id) }
    ) {
      MacLibraryPickerThumbnail(
        attachment: ChatAttachment(
          id: entry.id.rawValue,
          kind: entry.kind,
          filename: entry.filename,
          mimeType: entry.mimeType,
          data: Data(),
          declaredByteCount: entry.byteCount
        ),
        loadThumbnail: { _, size in
          await workspace.libraryThumbnail(entry, maxPixelSize: size)
        }
      )
    }
  }

  private func chatRow(_ item: ChatItem) -> some View {
    let isSelected = selectedUniqueIDs.contains(item.id)
    return selectableRow(
      title: item.attachment.filename,
      detail: "\(item.conversationTitle) · \(byteCountText(item.attachment.byteCount))",
      isSelected: isSelected,
      action: { toggleChat(item.id) }
    ) {
      MacLibraryPickerThumbnail(
        attachment: item.attachment,
        loadThumbnail: { id, size in
          await chats.attachmentThumbnail(id, maxPixelSize: size)
        }
      )
    }
  }

  private func selectableRow<Leading: View>(
    title: String,
    detail: String,
    isSelected: Bool,
    action: @escaping () -> Void,
    @ViewBuilder leading: () -> Leading
  ) -> some View {
    let atCapacity = !isSelected && remainingSlots == 0
    return Button(action: action) {
      HStack(spacing: 10) {
        leading()
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .lineLimit(1)
          Text(detail)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 18))
          .foregroundStyle(isSelected ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted)
          .symbolRenderingMode(.hierarchical)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        isSelected ? MacDesignTokens.Colors.accent.opacity(0.10) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .opacity(atCapacity ? 0.45 : 1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isLoading || atCapacity)
    .accessibilityLabel("\(title), \(detail)")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private func toggleSaved(_ id: LibraryEntryID) {
    if selectedUniqueIDs.contains(id.rawValue) {
      savedSelection.remove(id)
      chatSelection.remove(id.rawValue)
    } else if remainingSlots > 0 {
      savedSelection.insert(id)
    }
  }

  private func toggleChat(_ id: String) {
    if selectedUniqueIDs.contains(id) {
      chatSelection.remove(id)
      savedSelection.remove(LibraryEntryID(rawValue: id))
    } else if remainingSlots > 0 {
      chatSelection.insert(id)
    }
  }

  private func commit() {
    guard totalSelectionCount > 0, !isLoading else { return }
    isLoading = true
    Task { @MainActor in
      defer { isLoading = false }

      // Snapshot the complete selection across both tabs using metadata so no
      // blob bytes are read until the combined batch passes preflight.
      let selectedEntries = activeSavedSelection.isEmpty
        ? []
        : allAvailableEntries.filter { activeSavedSelection.contains($0.id) }
      let coveredSavedRawIDs = Set(selectedEntries.map(\.id.rawValue))
      let selectedItems = activeChatSelection.isEmpty
        ? []
        : allChatItems.filter {
          activeChatSelection.contains($0.id) && !coveredSavedRawIDs.contains($0.id)
        }

      let selectedByteCounts = selectedEntries.map(\.byteCount)
        + selectedItems.map { $0.attachment.byteCount }
      guard !selectedByteCounts.isEmpty, selectedByteCounts.count == totalSelectionCount else {
        errorMessage = "The selection changed or includes an item already attached. Please select again."
        return
      }

      let preflight = MacLibraryAttachmentPickerSupport.preflight(
        existingCount: excludedIDs.count,
        existingBytes: existingAttachmentByteCount,
        selectedByteCounts: selectedByteCounts
      )
      guard preflight.isValid else {
        errorMessage = preflight.errorMessage
        return
      }

      var values: [ChatAttachment] = []
      values.reserveCapacity(selectedByteCounts.count)

      for entry in selectedEntries {
        guard let data = await workspace.libraryData(entry), !data.isEmpty else {
          MacAppAnalytics.reportError("attachment_import_failed", component: "attachments")
          errorMessage = "The file '\(entry.filename)' could not be loaded."
          return
        }
        values.append(
          ChatAttachment(
            id: entry.id.rawValue,
            kind: entry.kind,
            filename: entry.filename,
            mimeType: entry.mimeType,
            data: data
          )
        )
      }

      for item in selectedItems {
        guard let data = await chats.attachmentData(item.id), !data.isEmpty else {
          MacAppAnalytics.reportError("attachment_import_failed", component: "attachments")
          errorMessage = "The file '\(item.attachment.filename)' could not be loaded."
          return
        }
        var attachment = item.attachment
        attachment.data = data
        values.append(attachment)
      }

      let loadedPreflight = MacLibraryAttachmentPickerSupport.preflight(
        existingCount: excludedIDs.count,
        existingBytes: existingAttachmentByteCount,
        selectedByteCounts: values.map(\.byteCount)
      )
      guard loadedPreflight.isValid else {
        errorMessage = loadedPreflight.errorMessage
        return
      }

      guard !values.isEmpty else { return }
      attach(values)
      dismiss()
    }
  }

  private func byteCountText(_ byteCount: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
  }
}

private struct MacLibraryPickerThumbnail: View {
  let attachment: ChatAttachment
  let loadThumbnail: (String, CGFloat) async -> Data?
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: attachment.isImage ? "photo" : "doc")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.accent)
      }
    }
    .frame(width: 40, height: 40)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .task(id: attachment.id) {
      guard attachment.isImage else {
        image = nil
        return
      }
      let data = await loadThumbnail(attachment.id, 96)
      image = data.flatMap(NSImage.init(data:))
    }
  }
}
