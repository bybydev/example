import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct ConversationTargetView: View {
  let conversation: ChatConversation
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var accountID: ProviderAccountID
  @State private var modelID: ModelID
  @State private var systemPrompt: String
  @State private var reasoningEnabled: Bool
  @State private var reasoningEffort: ReasoningEffort
  @State private var temperatureEnabled: Bool
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
    _reasoningEffort = State(initialValue: conversation.options.reasoning?.effort ?? .high)
    _temperatureEnabled = State(initialValue: conversation.options.temperature != nil)
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

  private var selectedModel: AccountModelRecord? {
    availableModels.first { $0.model.id == modelID }
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
          .listRowBackground(theme.surfaceColor)
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
            resetParameters()
          }

          NavigationLink {
            ConversationModelSelectionView(
              accountID: accountID,
              selection: $modelID,
              providers: providers
            )
          } label: {
            LabeledContent("Model") {
              Text(selectedModel?.model.displayName ?? modelID.rawValue)
                .foregroundStyle(theme.secondaryForegroundColor)
                .lineLimit(1)
            }
          }
          .onChange(of: modelID) { _, _ in resetParameters() }

          if let selectedModel, !selectedModel.isAvailable {
            Label(
              "This model is no longer reported by the provider. Choose another model before sending.",
              systemImage: "exclamationmark.triangle"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
          }
        }
        .listRowBackground(theme.surfaceColor)

        Section("System Prompt") {
          TextEditor(text: $systemPrompt)
            .frame(minHeight: 120)
          Button("Use Global Default") {
            systemPrompt = chats.defaultSystemPrompt
          }
          .disabled(systemPrompt == chats.defaultSystemPrompt)
        }
        .listRowBackground(theme.surfaceColor)

        Section("Generation") {
          Toggle("Reasoning", isOn: $reasoningEnabled)
          if reasoningEnabled {
            Picker("Reasoning Effort", selection: $reasoningEffort) {
              ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                Text(effort.rawValue.capitalized).tag(effort)
              }
            }
          }

          Toggle("Override Temperature", isOn: $temperatureEnabled)
          if temperatureEnabled {
            LabeledContent("Temperature") {
              Text(temperature, format: .number.precision(.fractionLength(1)))
            }
            Slider(value: $temperature, in: 0...2, step: 0.1)
          }

          TextField("Maximum output tokens", text: $maxOutputTokens)
            .keyboardType(.numberPad)

          Button("Reset Model Parameters") { resetParameters() }
        }
        .listRowBackground(theme.surfaceColor)
      }
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle("Chat Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(selectedAccount == nil || selectedModel?.isAvailable != true)
        }
      }
    }
  }

  private func resetParameters() {
    let providerID = selectedAccount?.providerID
    temperatureEnabled = false
    temperature = 1
    maxOutputTokens = ""
    reasoningEnabled = [
      BuiltInProviders.deepSeekID,
      BuiltInProviders.anthropicID,
      BuiltInProviders.geminiID,
    ].contains(providerID)
    reasoningEffort = providerID == BuiltInProviders.geminiID ? .medium : .high
  }

  private func save() {
    guard let account = selectedAccount else { return }
    let options = ProviderRequestOptions(
      temperature: temperatureEnabled ? temperature : nil,
      maxOutputTokens: Int(maxOutputTokens),
      reasoning: reasoningEnabled
        ? .init(enabled: true, effort: reasoningEffort)
        : nil
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

private struct ConversationModelSelectionView: View {
  let accountID: ProviderAccountID
  @Binding var selection: ModelID
  @Bindable var providers: ProviderManagementModel

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var searchText = ""

  private var records: [AccountModelRecord] {
    let all = providers.models(for: accountID)
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return all }
    return all.filter { record in
      record.model.displayName.localizedCaseInsensitiveContains(trimmed)
        || record.model.id.rawValue.localizedCaseInsensitiveContains(trimmed)
    }
  }

  var body: some View {
    List(records) { record in
      HStack(alignment: .top, spacing: 10) {
        Button {
          guard record.isAvailable else { return }
          selection = record.model.id
          dismiss()
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(record.model.displayName)
                .font(.headline)
              if record.model.id == selection {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
              }
            }
            Text(record.model.id.rawValue)
              .font(.caption.monospaced())
              .foregroundStyle(theme.secondaryForegroundColor)
              .lineLimit(2)
            HStack(spacing: 6) {
              if let context = record.model.contextWindow {
                Text("\(context.formatted()) context")
              }
              if !record.isAvailable {
                Text("Unavailable")
                  .foregroundStyle(.orange)
              }
            }
            .font(.caption2)
            .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!record.isAvailable)

        Button {
          Task {
            await providers.setFavorite(
              !record.isFavorite,
              modelID: record.model.id,
              accountID: accountID
            )
          }
        } label: {
          Image(systemName: record.isFavorite ? "star.fill" : "star")
            .foregroundStyle(record.isFavorite ? .yellow : .secondary)
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(record.isFavorite ? "Remove favorite" : "Add favorite")
      }
    }
    .navigationTitle("Choose Model")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search models")
  }
}
