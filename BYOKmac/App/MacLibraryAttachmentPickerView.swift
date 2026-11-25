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
  @State private var cachedChatItems: [ChatItem] = []
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

  private var trimmedSearchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var allAvailableEntries: [LibraryEntry] {
    workspace.libraryEntries
      .filter { !excludedIDs.contains($0.id.rawValue) }
      .sorted { $0.createdAt > $1.createdAt }
  }

  private var availableEntries: [LibraryEntry] {
    let query = trimmedSearchQuery
    guard !query.isEmpty else { return allAvailableEntries }
    return allAvailableEntries.filter {
      $0.filename.localizedCaseInsensitiveContains(query)
        || $0.mimeType.localizedCaseInsensitiveContains(query)
    }
  }

  private var chatItems: [ChatItem] {
    let query = trimmedSearchQuery
    guard !query.isEmpty else { return cachedChatItems }
    return cachedChatItems.filter { item in
      item.attachment.filename.localizedCaseInsensitiveContains(query)
        || item.attachment.mimeType.localizedCaseInsensitiveContains(query)
        || item.conversationTitle.localizedCaseInsensitiveContains(query)
    }
  }

  private var activeSavedSelection: Set<LibraryEntryID> {
    savedSelection.intersection(Set(allAvailableEntries.map(\.id)))
  }

  private var activeChatSelection: Set<String> {
    chatSelection.intersection(Set(cachedChatItems.map(\.id)))
  }

  private var selectedUniqueIDs: Set<String> {
    Set(activeSavedSelection.map(\.rawValue)).union(activeChatSelection)
  }

  private var totalSelectionCount: Int {
    selectedUniqueIDs.count
  }

  private var selectedByteCounts: [Int] {
    var coveredSavedRawIDs = Set<String>()
    var counts: [Int] = []
    if !activeSavedSelection.isEmpty {
      for entry in allAvailableEntries where activeSavedSelection.contains(entry.id) {
        coveredSavedRawIDs.insert(entry.id.rawValue)
        counts.append(entry.byteCount)
      }
    }
    if !activeChatSelection.isEmpty {
      for item in cachedChatItems
      where activeChatSelection.contains(item.id) && !coveredSavedRawIDs.contains(item.id) {
        counts.append(item.attachment.byteCount)
      }
    }
    return counts
  }

  private var projectedTotalBytes: Int {
    existingAttachmentByteCount + selectedByteCounts.reduce(0, +)
  }

  private var livePreflight: MacLibraryAttachmentPickerSupport.PreflightResult {
    MacLibraryAttachmentPickerSupport.preflight(
      existingCount: excludedIDs.count,
      existingBytes: existingAttachmentByteCount,
      selectedByteCounts: selectedByteCounts
    )
  }

  private var maxSelectableCount: Int {
    max(0, MacAttachmentImporter.maximumCount - excludedIDs.count)
  }

  private var remainingSlots: Int {
    max(0, maxSelectableCount - totalSelectionCount)
  }

  private var capacityNote: String {
    if let error = livePreflight.errorMessage {
      return error
    }
    return MacLibraryAttachmentPickerSupport.capacityNote(
      existingCount: excludedIDs.count,
      selectedCount: totalSelectionCount
    )
  }

  private var sizeNote: String? {
    guard totalSelectionCount > 0 || existingAttachmentByteCount > 0 else { return nil }
    let used = byteCountText(projectedTotalBytes)
    let limit = byteCountText(MacAttachmentImporter.maximumTotalBytes)
    return "\(used) / \(limit)"
  }

  private var activeErrorMessage: String? {
    errorMessage ?? workspace.errorMessage
  }

  private var chatSummariesSignature: [String] {
    chats.conversationSummaries.map { summary in
      let attachmentCount = summary.messages.reduce(0) { $0 + ($1.attachments?.count ?? 0) }
      return "\(summary.id.rawValue):\(attachmentCount)"
    }
  }

  private func tabTitle(_ option: Tab) -> String {
    switch option {
    case .saved:
      let count = activeSavedSelection.count
      return count > 0 ? "Saved (\(count))" : option.rawValue
    case .fromChats:
      let count = activeChatSelection.subtracting(Set(activeSavedSelection.map(\.rawValue))).count
      return count > 0 ? "From Chats (\(count))" : option.rawValue
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Attach from Library")
          .font(.headline)
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
          .disabled(isLoading)
        Button(totalSelectionCount == 0 ? "Attach" : "Attach (\(totalSelectionCount))") { commit() }
          .buttonStyle(MacActionButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(totalSelectionCount == 0 || !livePreflight.isValid || isLoading)
      }
      .padding(16)

      Divider()

      VStack(spacing: 8) {
        MacSegmentedControl(
          options: Tab.allCases,
          selection: $tab,
          title: tabTitle
        )
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

        HStack(spacing: 8) {
          Text(capacityNote)
            .font(.caption)
            .foregroundStyle(
              (!livePreflight.isValid || remainingSlots == 0)
                ? Color.orange
                : MacDesignTokens.Colors.textMuted
            )
            .lineLimit(2)

          Spacer(minLength: 8)

          if let sizeNote {
            Text(sizeNote)
              .font(.caption.monospacedDigit())
              .foregroundStyle(
                projectedTotalBytes > MacAttachmentImporter.maximumTotalBytes
                  ? Color.orange
                  : MacDesignTokens.Colors.textMuted
              )
          }
        }
      }
      .padding(12)

      Divider()
      content
    }
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.standardHeight
    )
    .background(MacDesignTokens.Colors.canvas)
    .overlay {
      if isLoading {
        ProgressView()
          .padding(12)
          .background(.regularMaterial, in: Capsule())
      }
    }
    .onAppear {
      rebuildChatItems()
    }
    .onChange(of: chatSummariesSignature) { _, _ in
      rebuildChatItems()
    }
    .onChange(of: excludedIDs) { _, ids in
      savedSelection = savedSelection.filter { !ids.contains($0.rawValue) }
      chatSelection.subtract(ids)
      rebuildChatItems()
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

  /// Conversation summaries retain attachment metadata in the v2 index, so
  /// this list does not hydrate every chat just to populate the picker.
  private func rebuildChatItems() {
    var seen: Set<String> = []
    var values: [ChatItem] = []

    for conversation in chats.conversationSummaries {
      for message in conversation.messages {
        for attachment in message.attachments ?? []
        where !excludedIDs.contains(attachment.id) && seen.insert(attachment.id).inserted {
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
    cachedChatItems = values.sorted { $0.date > $1.date }
  }

  @ViewBuilder
  private var content: some View {
    switch tab {
    case .saved:
      if availableEntries.isEmpty {
        ContentUnavailableView(
          trimmedSearchQuery.isEmpty ? "No Available Library Items" : "No Matches",
          systemImage: trimmedSearchQuery.isEmpty ? "books.vertical" : "magnifyingglass",
          description: Text(
            trimmedSearchQuery.isEmpty
              ? "Import files into Library or remove an already selected attachment."
              : "Try a different file name."
          )
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
          trimmedSearchQuery.isEmpty ? "No Chat Attachments" : "No Matches",
          systemImage: trimmedSearchQuery.isEmpty ? "paperclip" : "magnifyingglass",
          description: Text(
            trimmedSearchQuery.isEmpty
              ? "Files attached to earlier chat messages will appear here."
              : "Try a different file or chat name."
          )
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
    let exceedsSize = !isSelected
      && (entry.byteCount > MacAttachmentImporter.maximumFileBytes
        || projectedTotalBytes + entry.byteCount > MacAttachmentImporter.maximumTotalBytes)
    return MacLibraryPickerSelectableRow(
      title: entry.filename,
      detail: "\(entry.byteCountText) · \(entry.mimeType)",
      isSelected: isSelected,
      isDisabled: isLoading || (!isSelected && (remainingSlots == 0 || exceedsSize)),
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
    let exceedsSize = !isSelected
      && (item.attachment.byteCount > MacAttachmentImporter.maximumFileBytes
        || projectedTotalBytes + item.attachment.byteCount > MacAttachmentImporter.maximumTotalBytes)
    return MacLibraryPickerSelectableRow(
      title: item.attachment.filename,
      detail: "\(item.conversationTitle) · \(byteCountText(item.attachment.byteCount))",
      isSelected: isSelected,
      isDisabled: isLoading || (!isSelected && (remainingSlots == 0 || exceedsSize)),
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
        : cachedChatItems.filter {
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

struct MacLibraryPickerSelectableRow<Leading: View>: View {
  let title: String
  let detail: String
  let isSelected: Bool
  let isDisabled: Bool
  let action: () -> Void
  @ViewBuilder let leading: () -> Leading

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
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
      .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .opacity(isDisabled && !isSelected ? 0.45 : 1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .accessibilityLabel("\(title), \(detail)")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private var rowBackground: Color {
    if isSelected { return MacDesignTokens.Colors.accent.opacity(0.10) }
    if isHovered && !isDisabled { return Color.primary.opacity(0.04) }
    return Color.clear
  }
}

struct MacLibraryPickerThumbnail: View {
  let attachment: ChatAttachment
  let loadThumbnail: (String, CGFloat) async -> Data?

  @Environment(\.displayScale) private var displayScale
  @State private var image: NSImage?

  private var targetPixelSize: CGFloat {
    max(80, ceil(40 * max(displayScale, 1)))
  }

  private var cacheKey: String {
    "\(attachment.id)@\(Int(targetPixelSize.rounded()))"
  }

  private var displayedImage: NSImage? {
    image ?? MacLibraryThumbnailCache.shared.image(forKey: cacheKey)
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    MacDesignTokens.Colors.surface
      .frame(width: 40, height: 40)
      .overlay {
        if let displayedImage {
          Image(nsImage: displayedImage)
            .resizable()
            .scaledToFill()
        } else {
          Image(
            systemName: MacLibraryThumbnailCache.fileSymbol(
              mimeType: attachment.mimeType,
              isImage: attachment.isImage
            )
          )
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.accent)
        }
      }
      .clipShape(shape)
      .task(id: cacheKey) {
        await loadThumbnailImage()
      }
  }

  private func loadThumbnailImage() async {
    guard attachment.isImage else {
      image = nil
      return
    }
    let key = cacheKey
    if let cached = MacLibraryThumbnailCache.shared.image(forKey: key) {
      image = cached
      return
    }
    image = nil

    guard await MacImageWorkLimiter.shared.acquirePermit() else { return }
    defer {
      Task { await MacImageWorkLimiter.shared.releasePermit() }
    }
    guard !Task.isCancelled else { return }

    if let cached = MacLibraryThumbnailCache.shared.image(forKey: key) {
      image = cached
      return
    }

    let maxPixels = targetPixelSize
    guard let data = await loadThumbnail(attachment.id, maxPixels),
      !data.isEmpty,
      !Task.isCancelled
    else { return }

    let bitmap = await Task.detached(priority: .utility) {
      MacLibraryThumbnailCache.decodeBitmap(from: data, maxPixelSize: maxPixels)
    }.value

    guard !Task.isCancelled, let bitmap else { return }
    let decoded = NSImage(cgImage: bitmap.cgImage, size: bitmap.pointSize)
    MacLibraryThumbnailCache.shared.insert(decoded, forKey: key, byteCost: bitmap.byteCost)
    image = decoded
  }
}
