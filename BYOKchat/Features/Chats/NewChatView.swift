import AppFoundation
import BYOKchatProviderCore
import SwiftUI
import UIKit

struct NewChatView: View {
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel

  let openSidebar: () -> Void
  let openSettings: () -> Void
  let selectConversation: (ConversationID) -> Void

  @Environment(\.appFoundationTheme) private var theme
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
    guard let modelID = defaultModelID else { return "Choose model" }
    let modelName = providers.models(for: account.id)
      .first(where: { $0.model.id == modelID })?.model.displayName
      ?? modelID.rawValue
    return "\(account.label) · \(modelName)"
  }

  var body: some View {
    ZStack {
      theme.backgroundColor
        .ignoresSafeArea()

      VStack(spacing: 0) {
        Spacer(minLength: 72)

        VStack(spacing: 12) {
          Image(systemName: "bubble.left.and.bubble.right")
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(theme.accentColor)
            .accessibilityHidden(true)

          Text("How can I help?")
            .font(.system(size: 30, weight: .semibold))
            .multilineTextAlignment(.center)

          Text("Send a message to start a new conversation.")
            .font(.system(size: 16))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)

        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .simultaneousGesture(
      TapGesture().onEnded {
        dismissKeyboard()
      }
    )
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

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }
}
