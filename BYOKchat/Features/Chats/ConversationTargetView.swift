import BYOKchatProviderCore
import SwiftUI

struct ConversationTargetView: View {
  let conversation: ChatConversation
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel

  @Environment(\.dismiss) private var dismiss
  @State private var accountID: ProviderAccountID
  @State private var modelID: ModelID
  @State private var systemPrompt: String
  @State private var reasoningEnabled: Bool
  @State private var temperature: Double
  @State private var maxOutputTokens: String

  init(
    conversation: ChatConversation,
    chats: ChatManagementModel,
    providers: ProviderManagementModel
  ) {
    self.conversation = conversation
    self.chats = chats
    self.providers = providers
    _accountID = State(initialValue: conversation.accountID)
    _modelID = State(initialValue: conversation.modelID)
    _systemPrompt = State(initialValue: conversation.systemPrompt)
    _reasoningEnabled = State(initialValue: conversation.options.reasoning?.enabled ?? false)
    _temperature = State(initialValue: conversation.options.temperature ?? 1)
    _maxOutputTokens = State(
      initialValue: conversation.options.maxOutputTokens.map(String.init) ?? ""
    )
  }

  private var selectedAccount: ProviderAccount? {
    providers.accounts.first { $0.id == accountID }
  }

  private var availableModels: [AccountModelRecord] {
    providers.models(for: accountID)
  }

  var body: some View {
    NavigationStack {
      Form {
        if accountID != conversation.accountID {
          Section {
            Label(
              "Existing conversation context will be sent to the newly selected provider account.",
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
          }
        }

        Section("Provider") {
          Picker("Account", selection: $accountID) {
            ForEach(providers.accounts.filter(\.isEnabled)) { account in
              Text(account.label).tag(account.id)
            }
          }
          .onChange(of: accountID) { _, value in
            modelID =
              providers.accounts.first(where: { $0.id == value })?.defaultModelID
              ?? providers.models(for: value).first?.model.id
              ?? modelID
          }

          Picker("Model", selection: $modelID) {
            ForEach(availableModels) { record in
              Text(record.model.displayName).tag(record.model.id)
            }
          }
        }

        Section("System Prompt") {
          TextEditor(text: $systemPrompt)
            .frame(minHeight: 120)
        }

        Section("Generation") {
          Toggle("Reasoning", isOn: $reasoningEnabled)
          LabeledContent("Temperature") {
            Text(temperature, format: .number.precision(.fractionLength(1)))
          }
          Slider(value: $temperature, in: 0...2, step: 0.1)
          TextField("Maximum output tokens", text: $maxOutputTokens)
            .keyboardType(.numberPad)
        }
      }
      .navigationTitle("Chat Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(selectedAccount == nil || availableModels.isEmpty)
        }
      }
    }
  }

  private func save() {
    guard let account = selectedAccount else { return }
    let maxTokens = Int(maxOutputTokens)
    let options = ProviderRequestOptions(
      temperature: temperature,
      maxOutputTokens: maxTokens,
      reasoning: reasoningEnabled ? .init(enabled: true, effort: .high) : nil
    )
    Task {
      if await chats.updateTarget(
        conversationID: conversation.id,
        account: account,
        modelID: modelID,
        systemPrompt: systemPrompt,
        options: options
      ) {
        dismiss()
      }
    }
  }
}
