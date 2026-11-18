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
            Button("Add \(selectionCount == 0 ? "" : "(\(selectionCount))")") {
              Task { await addSelection() }
            }
            .disabled(selectionCount == 0)
          }
        }
      }
    }
    .interactiveDismissDisabled(isPreparing)
    .onChange(of: attachedIDs) { _, ids in
      selectedSavedIDs = selectedSavedIDs.filter { !ids.contains($0.rawValue) }
      selectedChatItemIDs.subtract(ids)
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
      if chatItems.isEmpty {
        ContentUnavailableView(
          "No Chat Attachments",
          systemImage: "paperclip",
          description: Text("Attachments you send in chats will appear here.")
        )
      } else {
        list {
          ForEach(chatItems) { item in
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
    selectableRow(
      title: entry.filename,
      detail: entry.byteCountText,
      isSelected: selectedSavedIDs.contains(entry.id)
    ) {
      toggleSaved(entry.id)
    } leading: {
      LibraryEntryThumbnailView(entry: entry, library: library, sideLength: 44)
    }
  }

  private func chatRow(_ item: ChatLibraryItem) -> some View {
    selectableRow(
      title: item.attachment.filename,
      detail: "\(item.conversationTitle) · \(item.byteCountText)",
      isSelected: selectedChatItemIDs.contains(item.id)
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
    Button(action: action) {
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
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isPreparing)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  // MARK: - Data

  private var attachedIDs: Set<String> {
    Set(pendingAttachments.map(\.id))
  }

  private var savedEntries: [LibraryEntry] {
    library.entries.filter { !attachedIDs.contains($0.id.rawValue) }
  }

  private var selectionCount: Int {
    switch tab {
    case .saved: selectedSavedIDs.count
    case .fromChats: selectedChatItemIDs.count
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

  private var chatItems: [ChatLibraryItem] {
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
    return items.sorted { $0.date > $1.date }
  }

  private func toggleSaved(_ id: LibraryEntryID) {
    if !selectedSavedIDs.insert(id).inserted {
      selectedSavedIDs.remove(id)
    }
  }

  private func toggleChat(_ id: String) {
    if !selectedChatItemIDs.insert(id).inserted {
      selectedChatItemIDs.remove(id)
    }
  }

  private func addSelection() async {
    guard !isPreparing else { return }
    isPreparing = true
    defer { isPreparing = false }

    // Snapshot the complete selection using metadata. No original blob read
    // occurs until the whole batch (including the composer) passes preflight.
    let selectedEntries = savedEntries.filter { selectedSavedIDs.contains($0.id) }
    let selectedItems = chatItems.filter { selectedChatItemIDs.contains($0.id) }
    let selectedByteCounts: [Int]
    switch tab {
    case .saved: selectedByteCounts = selectedEntries.map(\.byteCount)
    case .fromChats: selectedByteCounts = selectedItems.map { $0.attachment.byteCount }
    }
    guard !selectedByteCounts.isEmpty, selectedByteCounts.count == selectionCount else {
      errorMessage = "The selection changed or includes an item already attached. Please select again."
      return
    }
    guard preflight(selectedByteCounts) else { return }

    var result: [ChatAttachment] = []
    switch tab {
    case .fromChats:
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
    case .saved:
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
    }
    guard !result.isEmpty else { return }
    onAdd(result)
    dismiss()
  }

  private func preflight(_ selectedByteCounts: [Int]) -> Bool {
    guard pendingAttachments.count + selectedByteCounts.count <= 8 else {
      errorMessage = "A message can include at most 8 attachments."
      return false
    }
    let byteCounts = pendingAttachments.map(\.byteCount) + selectedByteCounts
    guard byteCounts.allSatisfy({ $0 > 0 && $0 <= 20 * 1_024 * 1_024 }) else {
      errorMessage = "Each attachment must contain bytes and be no larger than 20 MB."
      return false
    }
    // Per-item/count bounds above keep this sum bounded as well.
    guard byteCounts.reduce(0, +) <= 40 * 1_024 * 1_024 else {
      errorMessage = "Attachments in one message cannot exceed 40 MB total."
      return false
    }
    return true
  }
}
