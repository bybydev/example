import BYOKchatProviderCore
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
  let conversationID: ConversationID
  let initialScrollMessageID: ChatMessageID?
  let openSidebar: () -> Void
  let startNewChat: () -> Void

  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel

  @Environment(\.dismiss) var dismiss
  @State var draft = ""
  @State var restoredDraft = false
  @State var showTargetSettings = false
  @State var renameText = ""
  @State var showRename = false
  @State var editTarget: ChatMessage?
  @State var editText = ""
  @State var showRegenerateConfirmation = false
  @State var isNearBottom = true
  @State var showJumpToLatest = false
  @State var markdownDocument: MarkdownExportDocument?
  @State var showMarkdownExporter = false

  init(
    conversationID: ConversationID,
    initialScrollMessageID: ChatMessageID? = nil,
    chats: ChatManagementModel,
    providers: ProviderManagementModel,
    openSidebar: @escaping () -> Void = {},
    startNewChat: @escaping () -> Void = {}
  ) {
    self.conversationID = conversationID
    self.initialScrollMessageID = initialScrollMessageID
    self.chats = chats
    self.providers = providers
    self.openSidebar = openSidebar
    self.startNewChat = startNewChat
  }

  var conversation: ChatConversation? {
    chats.conversation(conversationID)
  }

  var latestAssistantID: ChatMessageID? {
    conversation?.messages.last(where: { $0.role == .assistant })?.id
  }

  var markdownFilename: String {
    let title = conversation?.title ?? "BYOKchat-conversation"
    let safe = title.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
    return String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private var headerAccountLabel: String {
    guard let conversation else { return "" }
    return providers.accounts.first { $0.id == conversation.accountID }?.label
      ?? conversation.providerID.rawValue
  }

  var body: some View {
    Group {
      if let conversation {
        chatContent(conversation)
      } else {
        ContentUnavailableView("Conversation Missing", systemImage: "exclamationmark.bubble")
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Open Sidebar", systemImage: "line.3.horizontal") {
          openSidebar()
        }
      }

      ToolbarItem(placement: .principal) {
        if let conversation {
          Button {
            showTargetSettings = true
          } label: {
            VStack(spacing: 0) {
              HStack(spacing: 4) {
                Text(conversation.modelID.rawValue)
                  .font(.headline)
                  .lineLimit(1)
                Image(systemName: "chevron.down")
                  .font(.caption2.weight(.bold))
              }
              Text(headerAccountLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Change provider account and model")
        }
      }

      ToolbarItemGroup(placement: .topBarTrailing) {
        Button("New Chat", systemImage: "square.and.pencil") {
          startNewChat()
        }

        Menu {
          Button("Chat Settings", systemImage: "slider.horizontal.3") {
            showTargetSettings = true
          }
          Button("Rename", systemImage: "pencil") {
            renameText = conversation?.title ?? ""
            showRename = true
          }
          Button("Export Markdown", systemImage: "doc.text") {
            guard let conversation else { return }
            let accountLabel = providers.accounts.first { $0.id == conversation.accountID }?.label
            markdownDocument = MarkdownExportDocument(
              data: Data(
                ConversationMarkdownFormatter.render(
                  conversation, accountLabel: accountLabel
                ).utf8
              )
            )
            showMarkdownExporter = true
          }
          Button("Delete", systemImage: "trash", role: .destructive) {
            Task { @MainActor in
              await chats.deleteConversation(conversationID)
              startNewChat()
              dismiss()
            }
          }
        } label: {
          Image(systemName: "ellipsis")
        }
      }
    }
    .sheet(isPresented: $showTargetSettings) {
      if let conversation {
        ConversationTargetView(
          conversation: conversation,
          chats: chats,
          providers: providers
        )
      }
    }
    .sheet(item: $editTarget) { message in
      MessageEditorSheet(
        original: message.content,
        text: $editText,
        save: {
          chats.editAndResend(
            conversationID: conversationID,
            messageID: message.id,
            text: editText
          )
          editTarget = nil
        },
        cancel: { editTarget = nil }
      )
    }
    .alert("Rename Chat", isPresented: $showRename) {
      TextField("Title", text: $renameText)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        Task { @MainActor in
          await chats.renameConversation(conversationID, title: renameText)
        }
      }
    }
    .alert("Regenerate response?", isPresented: $showRegenerateConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Regenerate Anyway", role: .destructive) {
        chats.regenerate(
          conversationID: conversationID,
          confirmingUncertainCompletion: true
        )
      }
    } message: {
      Text(
        "The previous request may have completed at the provider. Regenerating could create another billable request."
      )
    }
    .fileExporter(
      isPresented: $showMarkdownExporter,
      document: markdownDocument,
      contentType: .markdown,
      defaultFilename: markdownFilename
    ) { result in
      if case .failure(let error) = result {
        chats.errorMessage = error.localizedDescription
      }
    }
    .task(id: conversationID) {
      guard !restoredDraft else { return }
      draft = chats.draft(for: conversationID)
      restoredDraft = true
    }
    .onChange(of: draft) { _, value in
      guard restoredDraft else { return }
      chats.saveDraft(value, conversationID: conversationID)
    }
  }
}
