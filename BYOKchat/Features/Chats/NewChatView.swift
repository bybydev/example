import BYOKchatProviderCore
import SwiftUI

struct NewChatView: View {
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel

  let openSidebar: () -> Void
  let openSettings: () -> Void
  let selectConversation: (ConversationID) -> Void

  @State private var draft = ""
  @State private var isCreating = false

  private var defaultAccount: ProviderAccount? {
    providers.accounts.first(where: \.isEnabled)
  }

  private var defaultModelID: ModelID? {
    guard let account = defaultAccount else { return nil }
    return account.defaultModelID ?? providers.models(for: account.id).first?.model.id
  }

  private var targetLabel: String {
    guard let account = defaultAccount else { return "Configure a provider" }
    let model = defaultModelID?.rawValue ?? "Choose model"
    return "\(account.label) · \(model)"
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer()

      VStack(spacing: 18) {
        Image(systemName: "bubble.left.and.bubble.right.fill")
          .font(.system(size: 42))
          .foregroundStyle(.tint)
          .frame(width: 76, height: 76)
          .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))

        Text("How can I help?")
          .font(.largeTitle.bold())

        if providers.accounts.isEmpty {
          Text("Add a DeepSeek, OpenRouter, NVIDIA, or custom provider account to begin.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 32)

          Button("Configure Provider", systemImage: "key.horizontal") {
            openSettings()
          }
          .buttonStyle(.borderedProminent)
        } else {
          VStack(spacing: 10) {
            suggestion("Help me write production-ready Swift code")
            suggestion("Compare the best models for this task")
            suggestion("Explain a complex topic clearly")
          }
          .padding(.horizontal, 24)
        }
      }

      Spacer()
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Open Sidebar", systemImage: "line.3.horizontal") {
          openSidebar()
        }
      }

      ToolbarItem(placement: .principal) {
        Button {
          openSettings()
        } label: {
          HStack(spacing: 5) {
            Text(defaultModelID?.rawValue ?? "BYOKchat")
              .font(.headline)
              .lineLimit(1)
            Image(systemName: "chevron.down")
              .font(.caption2.weight(.bold))
          }
        }
        .buttonStyle(.plain)
      }
    }
    .safeAreaInset(edge: .bottom) {
      ChatComposer(
        draft: $draft,
        isGenerating: false,
        canSend: !isCreating && defaultAccount != nil && defaultModelID != nil,
        targetLabel: targetLabel,
        openTarget: openSettings,
        send: { startConversation(with: draft) },
        stop: {}
      )
      .overlay {
        if isCreating {
          ProgressView()
            .padding(10)
            .background(.regularMaterial, in: Capsule())
        }
      }
    }
  }

  private func suggestion(_ text: String) -> some View {
    Button {
      startConversation(with: text)
    } label: {
      HStack {
        Text(text)
          .multilineTextAlignment(.leading)
        Spacer()
        Image(systemName: "arrow.up.right")
          .foregroundStyle(.secondary)
      }
      .padding(14)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
    .buttonStyle(.plain)
    .disabled(isCreating)
  }

  private func startConversation(with text: String) {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, !isCreating else { return }

    isCreating = true
    Task { @MainActor in
      defer { isCreating = false }
      guard let id = await chats.createConversation() else { return }
      draft = ""
      chats.send(conversationID: id, text: normalized)
      selectConversation(id)
    }
  }
}
