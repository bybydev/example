import BYOKchatProviderCore
import SwiftUI
import UIKit

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
      Spacer(minLength: 72)

      VStack(spacing: 16) {
        Text("How can I help?")
          .font(.system(size: 30, weight: .semibold))
          .multilineTextAlignment(.center)

        if providers.accounts.isEmpty {
          Text("Connect DeepSeek, OpenRouter, NVIDIA, or a custom provider to start chatting.")
            .font(.system(size: 16))
            .lineSpacing(3)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 34)

          Button("Configure Provider", systemImage: "key.horizontal") {
            openSettings()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
        } else {
          VStack(spacing: 8) {
            suggestion("Help me write production-ready Swift code")
            suggestion("Compare the best models for this task")
            suggestion("Explain a complex topic clearly")
          }
          .padding(.horizontal, 22)
          .padding(.top, 8)
        }
      }

      Spacer()
    }
    .background(Color(uiColor: .systemBackground))
    .toolbar(.hidden, for: .navigationBar)
    .safeAreaInset(edge: .top, spacing: 0) {
      ChatTopBar(
        openSidebar: openSidebar,
        newChat: { draft = "" }
      ) {
        Button("Settings", systemImage: "gearshape", action: openSettings)
        Button("Providers & Accounts", systemImage: "key.horizontal", action: openSettings)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
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
      HStack(spacing: 12) {
        Text(text)
          .font(.system(size: 16))
          .multilineTextAlignment(.leading)
        Spacer(minLength: 8)
        Image(systemName: "arrow.up.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 52)
      .background(
        Color(uiColor: .secondarySystemBackground),
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      )
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
