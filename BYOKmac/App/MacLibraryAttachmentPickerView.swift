import AppKit
import BYOKchatProviderCore
import Foundation
import SwiftUI

struct MacLibraryAttachmentPickerView: View {
  @Bindable var workspace: MacWorkspaceModel
  let excludedIDs: Set<String>
  let attach: ([ChatAttachment]) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(MacChatSessionModel.self) private var chats
  @State private var tab: Tab = .saved
  @State private var savedSelection: Set<LibraryEntryID> = []
  @State private var chatSelection: Set<String> = []
  @State private var searchText = ""
  @State private var isLoading = false

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

  private var availableEntries: [LibraryEntry] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return workspace.libraryEntries
      .filter { !excludedIDs.contains($0.id.rawValue) }
      .filter { query.isEmpty || $0.filename.localizedCaseInsensitiveContains(query) }
      .sorted { $0.createdAt > $1.createdAt }
  }

  /// Conversation summaries retain attachment metadata in the v2 index, so
  /// this list does not hydrate every chat just to populate the picker.
  private var chatItems: [ChatItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    var seen: Set<String> = []
    var values: [ChatItem] = []

    for conversation in chats.conversationSummaries {
      for message in conversation.messages {
        for attachment in message.attachments ?? []
        where !excludedIDs.contains(attachment.id) && seen.insert(attachment.id).inserted
        {
          let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
          let item = ChatItem(
            attachment: attachment,
            conversationTitle: title.isEmpty ? "Chat" : title,
            date: message.createdAt
          )
          if query.isEmpty
            || attachment.filename.localizedCaseInsensitiveContains(query)
            || item.conversationTitle.localizedCaseInsensitiveContains(query)
          {
            values.append(item)
          }
        }
      }
    }
    return values.sorted { $0.date > $1.date }
  }

  private var selectionCount: Int {
    switch tab {
    case .saved:
      savedSelection.intersection(Set(availableEntries.map(\.id))).count
    case .fromChats:
      chatSelection.intersection(Set(chatItems.map(\.id))).count
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Attach from Library")
          .font(.headline)
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(selectionCount == 0 ? "Attach" : "Attach (\(selectionCount))") { commit() }
          .keyboardShortcut(.defaultAction)
          .disabled(selectionCount == 0 || isLoading)
      }
      .padding(16)

      Divider()

      VStack(spacing: 10) {
        Picker("Source", selection: $tab) {
          ForEach(Tab.allCases) { tab in
            Text(tab.rawValue).tag(tab)
          }
        }
        .pickerStyle(.segmented)

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
    .alert(
      "Library Error",
      isPresented: Binding(
        get: { workspace.errorMessage != nil },
        set: { if !$0 { workspace.errorMessage = nil } }
      )
    ) {
      Button("OK") { workspace.errorMessage = nil }
    } message: {
      Text(workspace.errorMessage ?? "Unknown error")
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
        List(availableEntries, selection: $savedSelection) { entry in
          HStack(spacing: 10) {
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
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.filename).lineLimit(1)
              Text("\(entry.byteCountText) · \(entry.mimeType)")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .lineLimit(1)
            }
          }
          .tag(entry.id)
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
        List(chatItems, selection: $chatSelection) { item in
          HStack(spacing: 10) {
            MacLibraryPickerThumbnail(
              attachment: item.attachment,
              loadThumbnail: { id, size in
                await chats.attachmentThumbnail(id, maxPixelSize: size)
              }
            )
            VStack(alignment: .leading, spacing: 2) {
              Text(item.attachment.filename).lineLimit(1)
              Text("\(item.conversationTitle) · \(byteCountText(item.attachment.byteCount))")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .lineLimit(1)
            }
          }
          .tag(item.id)
        }
      }
    }
  }

  private func commit() {
    guard selectionCount > 0, !isLoading else { return }
    isLoading = true
    Task { @MainActor in
      defer { isLoading = false }
      var values: [ChatAttachment] = []
      var missingCount = 0

      switch tab {
      case .saved:
        for entry in availableEntries where savedSelection.contains(entry.id) {
          if let attachment = await workspace.attachment(for: entry) {
            values.append(attachment)
          } else {
            missingCount += 1
          }
        }

      case .fromChats:
        for item in chatItems where chatSelection.contains(item.id) {
          if let data = await chats.attachmentData(item.id), !data.isEmpty {
            var attachment = item.attachment
            attachment.data = data
            values.append(attachment)
          } else {
            missingCount += 1
          }
        }
      }

      if missingCount > 0 {
        workspace.errorMessage = missingCount == 1
          ? "One selected file is no longer available."
          : "\(missingCount) selected files are no longer available."
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
