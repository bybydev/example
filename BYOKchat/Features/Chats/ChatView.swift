import BYOKchatProviderCore
import SwiftUI
import UIKit

struct ChatView: View {
  let conversationID: ConversationID
  let initialScrollMessageID: ChatMessageID?
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

  init(
    conversationID: ConversationID,
    initialScrollMessageID: ChatMessageID? = nil,
    chats: ChatManagementModel,
    providers: ProviderManagementModel
  ) {
    self.conversationID = conversationID
    self.initialScrollMessageID = initialScrollMessageID
    self.chats = chats
    self.providers = providers
  }

  var conversation: ChatConversation? {
    chats.conversation(conversationID)
  }

  var latestAssistantID: ChatMessageID? {
    conversation?.messages.last(where: { $0.role == .assistant })?.id
  }

  var body: some View {
    Group {
      if let conversation {
        chatContent(conversation)
      } else {
        ContentUnavailableView("Conversation Missing", systemImage: "exclamationmark.bubble")
      }
    }
    .navigationTitle(conversation?.title ?? "Chat")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button("Chat Settings", systemImage: "slider.horizontal.3") {
          showTargetSettings = true
        }
        Menu {
          Button("Rename", systemImage: "pencil") {
            renameText = conversation?.title ?? ""
            showRename = true
          }
          Button("Delete", systemImage: "trash", role: .destructive) {
            Task {
              await chats.deleteConversation(conversationID)
              dismiss()
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
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
        Task { await chats.renameConversation(conversationID, title: renameText) }
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
