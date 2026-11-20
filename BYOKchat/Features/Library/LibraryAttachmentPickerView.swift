import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// Multi-select picker for the chat composer's "From Library…" action.
/// Two tabs: explicitly saved library entries, and files already attached to
/// past chat messages.
struct LibraryAttachmentPickerView: View {
  let library: LibraryManagementModel
  let chats: ChatManagementModel
  let pendingAttachments: [ChatAttachment]
  /// Receives the chosen attachments (validated by the caller on append).
  let onAdd: ([ChatAttachment]) -> Void

  private enum Tab: String, CaseIterable, Identifiable {
    case saved = "Saved"
    case fromChats = "From Chats"

    var id: String { rawValue }
  }

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var tab: Tab = .saved
  @State private var selectedSavedIDs: Set<LibraryEntryID> = []
  @State private var selectedChatItemIDs: Set<String> = []
  @State private var cachedChatItems: [ChatLibraryItem] = []
  @State private var isPreparing = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Picker("Source", selection: $tab) {
          ForEach(Tab.allCases) { tab in
            Text(tab.rawValue).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .disabled(isPreparing)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)

        if let capacityNote {
          Text(capacityNote)
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }

        content
      }
      .background(theme.backgroundColor.ignoresSafeArea())
      .navigationTitle("Attach from Library")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isPreparing)
        }
        ToolbarItem(placement: .primaryAction) {
          if isPreparing {
            ProgressView()
              .controlSize(.small)
          } else {
            Button(totalSelectionCount == 0 ? "Add" : "Add (\(totalSelectionCount))") {
              Task { await addSelection() }
            }
            .disabled(totalSelectionCount == 0)
          }
        }
      }
    }
    .interactiveDismissDisabled(isPreparing)
    .onAppear {
      refreshChatItems()
    }
    .onChange(of: attachedIDs) { _, ids in
      selectedSavedIDs = selectedSavedIDs.filter { !ids.contains($0.rawValue) }
      selectedChatItemIDs.subtract(ids)
      refreshChatItems()
    }
    .onChange(of: chatHistoryFingerprint) { _, _ in
      refreshChatItems()
    }
    .alert("Attachment Error", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Unknown error")
    }
  }

  @ViewBuilder
  private var content: some View {
    switch tab {
    case .saved:
      if savedEntries.isEmpty {
        ContentUnavailableView(
          "Library is Empty",
          systemImage: "books.vertical",
          description: Text("Files you save will be available here.")
        )
      } else {
        list {
          ForEach(savedEntries) { entry in
            savedRow(entry)
          }
        }
      }
    case .fromChats:
      if cachedChatItems.isEmpty {
        ContentUnavailableView(
          "No Chat Attachments",
          systemImage: "paperclip",
          description: Text("Attachments you send in chats will appear here.")
        )
      } else {
        list {
          ForEach(cachedChatItems) { item in
            chatRow(item)
          }
        }
      }
    }
  }

  private func list(@ViewBuilder rows: () -> some View) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        rows()
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 20)
    }
  }

  private func savedRow(_ entry: LibraryEntry) -> some View {
    let isSelected = selectedUniqueIDs.contains(entry.id.rawValue)
    return selectableRow(
      title: entry.filename,
      detail: entry.byteCountText,
      isSelected: isSelected
    ) {
      toggleSaved(entry.id)
    } leading: {
      LibraryEntryThumbnailView(entry: entry, library: library, sideLength: 44)
    }
  }

  private func chatRow(_ item: ChatLibraryItem) -> some View {
    let isSelected = selectedUniqueIDs.contains(item.id)
    return selectableRow(
      title: item.attachment.filename,
      detail: "\(item.conversationTitle) · \(item.byteCountText)",
      isSelected: isSelected
    ) {
      toggleChat(item.id)
    } leading: {
      chatThumbnail(item)
    }
  }

  @ViewBuilder
  private func chatThumbnail(_ item: ChatLibraryItem) -> some View {
    if item.attachment.isImage {
      AsyncAttachmentThumbnail(
        attachment: item.attachment,
        sideLength: 44,
        height: 44,
        cornerRadius: 9,
        loadThumbnail: chats.attachmentThumbnail
      )
    } else {
      Image(systemName: "doc")
        .font(.system(size: 17))
        .foregroundStyle(theme.secondaryForegroundColor)
        .frame(width: 44, height: 44)
        .background(
          theme.surfaceColor,
          in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }
  }

  private func selectableRow(
    title: String,
    detail: String,
    isSelected: Bool,
    action: @escaping () -> Void,
    @ViewBuilder leading: () -> some View
  ) -> some View {
    let atCapacity = !isSelected && remainingSlots == 0
    return Button(action: action) {
      HStack(spacing: 12) {
        leading()

        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.body.weight(.medium))
            .foregroundStyle(theme.primaryForegroundColor)
            .lineLimit(1)
          Text(detail)
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 20))
          .foregroundStyle(isSelected ? theme.accentColor : theme.secondaryForegroundColor)
          .symbolRenderingMode(.hierarchical)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .opacity(atCapacity ? 0.45 : 1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isPreparing || atCapacity)
    .accessibilityLabel("\(title), \(detail)")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  // MARK: - Data

  private var attachedIDs: Set<String> {
    Set(pendingAttachments.map(\.id))
  }

  private var savedEntries: [LibraryEntry] {
    library.entries.filter { !attachedIDs.contains($0.id.rawValue) }
  }

  private var selectedUniqueIDs: Set<String> {
    Set(selectedSavedIDs.map(\.rawValue)).union(selectedChatItemIDs)
  }

  private var totalSelectionCount: Int {
    selectedUniqueIDs.count
  }

  private var maxSelectableCount: Int {
    max(0, ChatComposerLayoutPolicy.maxAttachmentCount - pendingAttachments.count)
  }

  private var remainingSlots: Int {
    max(0, maxSelectableCount - totalSelectionCount)
  }

  private var capacityNote: String? {
    if remainingSlots == 0 {
      return "Maximum of \(ChatComposerLayoutPolicy.maxAttachmentCount) attachments reached."
    }
    if pendingAttachments.count > 0 || totalSelectionCount > 0 {
      return "You can select up to \(remainingSlots) more \(remainingSlots == 1 ? "attachment" : "attachments")."
    }
    return nil
  }

  private var chatHistoryFingerprint: [String] {
    chats.conversations.map {
      "\($0.id.rawValue):\($0.messages.count):\($0.updatedAt.timeIntervalSinceReferenceDate)"
    }
  }

  private struct ChatLibraryItem: Identifiable {
    let id: String
    let attachment: ChatAttachment
    let conversationTitle: String
    let date: Date

    var byteCountText: String {
      ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
    }
  }

  private func refreshChatItems() {
    var items: [ChatLibraryItem] = []
    var seenIDs = attachedIDs
    for conversation in chats.conversations {
      for message in conversation.messages {
        // Rows are metadata-only; presence is decided by ID, not by bytes.
        for attachment in message.attachments ?? [] where seenIDs.insert(attachment.id).inserted {
          items.append(
            ChatLibraryItem(
              id: attachment.id,
              attachment: attachment,
              conversationTitle: conversation.title,
              date: message.createdAt
            )
          )
        }
      }
    }
    cachedChatItems = items.sorted { $0.date > $1.date }
  }

  private func toggleSaved(_ id: LibraryEntryID) {
    if selectedUniqueIDs.contains(id.rawValue) {
      selectedSavedIDs.remove(id)
      selectedChatItemIDs.remove(id.rawValue)
    } else if remainingSlots > 0 {
      selectedSavedIDs.insert(id)
    }
  }

  private func toggleChat(_ id: String) {
    if selectedUniqueIDs.contains(id) {
      selectedChatItemIDs.remove(id)
      selectedSavedIDs.remove(LibraryEntryID(rawValue: id))
    } else if remainingSlots > 0 {
      selectedChatItemIDs.insert(id)
    }
  }

  private func addSelection() async {
    guard !isPreparing else { return }
    isPreparing = true
    defer { isPreparing = false }

    // Snapshot the complete selection across both tabs using metadata. No
    // original blob read occurs until the combined batch passes preflight.
    let selectedEntries = selectedSavedIDs.isEmpty
      ? []
      : savedEntries.filter { selectedSavedIDs.contains($0.id) }
    let coveredSavedRawIDs = Set(selectedEntries.map(\.id.rawValue))
    let selectedItems = selectedChatItemIDs.isEmpty
      ? []
      : cachedChatItems.filter {
        selectedChatItemIDs.contains($0.id) && !coveredSavedRawIDs.contains($0.id)
      }
    let selectedByteCounts = selectedEntries.map(\.byteCount)
      + selectedItems.map { $0.attachment.byteCount }
    guard !selectedByteCounts.isEmpty, selectedByteCounts.count == totalSelectionCount else {
      errorMessage = "The selection changed or includes an item already attached. Please select again."
      return
    }
    guard preflight(selectedByteCounts) else { return }

    var result: [ChatAttachment] = []
    for entry in selectedEntries {
      guard let data = await library.data(for: entry), !data.isEmpty else {
        BYOKAppAnalytics.reportError("attachment_import_failed", component: "attachments")
        errorMessage = "The file '\(entry.filename)' could not be loaded."
        return
      }
      // Same-ID reuse keeps blob storage deduplicated.
      result.append(
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
      // Rows hold metadata only; fetch the original now that it is
      // actually being attached.
      guard let data = await chats.attachmentData(item.id), !data.isEmpty else {
        BYOKAppAnalytics.reportError("attachment_import_failed", component: "attachments")
        errorMessage = "The file '\(item.attachment.filename)' could not be loaded."
        return
      }
      var attachment = item.attachment
      attachment.data = data
      result.append(attachment)
    }
    guard !result.isEmpty else { return }
    onAdd(result)
    dismiss()
  }

  private func preflight(_ selectedByteCounts: [Int]) -> Bool {
    guard pendingAttachments.count + selectedByteCounts.count <= ChatComposerLayoutPolicy.maxAttachmentCount else {
      errorMessage = "A message can include at most \(ChatComposerLayoutPolicy.maxAttachmentCount) attachments."
      return false
    }
    let byteCounts = pendingAttachments.map(\.byteCount) + selectedByteCounts
    guard byteCounts.allSatisfy({ $0 > 0 && $0 <= ChatComposerLayoutPolicy.maxAttachmentByteCount }) else {
      errorMessage = "Each attachment must contain bytes and be no larger than 20 MB."
      return false
    }
    // Per-item/count bounds above keep this sum bounded as well.
    guard byteCounts.reduce(0, +) <= ChatComposerLayoutPolicy.maxTotalAttachmentByteCount else {
      errorMessage = "Attachments in one message cannot exceed 40 MB total."
      return false
    }
    return true
  }
}
