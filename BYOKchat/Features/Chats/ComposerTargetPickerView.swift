import BYOKchatProviderCore
import SwiftUI

struct ComposerTargetPickerView: View {
  let conversation: ChatConversation
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel

  @Environment(\.dismiss) private var dismiss
  @State private var accountID: ProviderAccountID
  @State private var modelID: ModelID
  @State private var reasoningEnabled: Bool
  @State private var reasoningEffort: ReasoningEffort

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
    _reasoningEnabled = State(initialValue: conversation.options.reasoning?.enabled ?? false)
    _reasoningEffort = State(initialValue: conversation.options.reasoning?.effort ?? .high)
  }

  private var accounts: [ProviderAccount] {
    providers.accounts.filter(\.isEnabled)
  }

  private var selectedAccount: ProviderAccount? {
    accounts.first { $0.id == accountID }
  }

  private var availableModels: [AccountModelRecord] {
    providers.models(for: accountID)
  }

  private var selectedModel: AccountModelRecord? {
    availableModels.first { $0.model.id == modelID }
  }

  private var supportedParameters: Set<String> {
    selectedModel?.model.supportedParameters ?? []
  }

  private var supportsReasoning: Bool {
    !supportedParameters.isDisjoint(with: [
      "reasoning", "thinking", "reasoning_effort", "thinkingConfig", "effort",
    ])
  }

  private var supportsTemperature: Bool {
    supportedParameters.contains("temperature")
  }

  private var supportsTopP: Bool {
    supportedParameters.contains("top_p") || supportedParameters.contains("topP")
  }

  private var supportsMaximumTokens: Bool {
    !supportedParameters.isDisjoint(with: [
      "max_tokens", "max_output_tokens", "maxOutputTokens",
    ])
  }

  var body: some View {
    NavigationStack {
      List {
        Section("Provider") {
          ForEach(accounts) { account in
            providerRow(account)
          }
        }

        Section("Model") {
          NavigationLink {
            ComposerModelPickerView(
              accountID: accountID,
              selection: $modelID,
              providers: providers
            )
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(selectedModel?.model.displayName ?? modelID.rawValue)
                .font(.body.weight(.medium))
                .lineLimit(2)
              Text(selectedModel?.model.id.rawValue ?? modelID.rawValue)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }

          if let model = selectedModel?.model {
            modelCapabilitySummary(model)
          }
        }

        if supportsReasoning {
          Section("Reasoning") {
            Toggle("Reasoning", isOn: $reasoningEnabled)
            if reasoningEnabled {
              Picker("Effort", selection: $reasoningEffort) {
                ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                  Text(reasoningTitle(effort)).tag(effort)
                }
              }
            }
          }
        }
      }
      .navigationTitle("Choose Model")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Use") { save() }
            .disabled(selectedAccount == nil || selectedModel?.isAvailable != true)
        }
      }
      .onChange(of: modelID) { _, _ in
        normalizeReasoningForSelection()
      }
    }
  }

  private func providerRow(_ account: ProviderAccount) -> some View {
    Button {
      guard account.id != accountID else { return }
      accountID = account.id
      modelID =
        account.defaultModelID
        ?? providers.models(for: account.id).first(where: \.isAvailable)?.model.id
        ?? providers.models(for: account.id).first?.model.id
        ?? modelID
      normalizeReasoningForSelection()
    } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(account.label)
            .foregroundStyle(.primary)
          if let definition = providers.provider(for: account.providerID),
            definition.displayName != account.label
          {
            Text(definition.displayName)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        if account.id == accountID {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.tint)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func modelCapabilitySummary(_ model: ProviderModel) -> some View {
    HStack(spacing: 10) {
      if let context = model.contextWindow {
        Label(context.formatted(.number.notation(.compactName)), systemImage: "text.line.first.and.arrowtriangle.forward")
      }
      if model.inputModalities.contains("image") {
        Label("Vision", systemImage: "photo")
      }
      if model.inputModalities.contains("file") {
        Label("Files", systemImage: "doc")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func normalizeReasoningForSelection() {
    guard supportsReasoning else {
      reasoningEnabled = false
      return
    }

    if accountID == conversation.accountID, modelID == conversation.modelID {
      reasoningEnabled = conversation.options.reasoning?.enabled ?? false
      reasoningEffort = conversation.options.reasoning?.effort ?? .high
      return
    }

    reasoningEnabled = true
    reasoningEffort = selectedAccount?.providerID == BuiltInProviders.geminiID ? .medium : .high
  }

  private func reasoningTitle(_ effort: ReasoningEffort) -> String {
    switch effort {
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .max: "Max"
    }
  }

  private func save() {
    guard let account = selectedAccount else { return }

    var options = conversation.options
    if !supportsTemperature { options.temperature = nil }
    if !supportsTopP { options.topP = nil }
    if !supportsMaximumTokens { options.maxOutputTokens = nil }
    if account.providerID != BuiltInProviders.openRouterID {
      options.openRouterRouting = nil
    }
    options.reasoning = supportsReasoning && reasoningEnabled
      ? .init(enabled: true, effort: reasoningEffort)
      : nil

    Task {
      if await chats.updateTarget(
        conversationID: conversation.id,
        account: account,
        modelID: modelID,
        systemPrompt: conversation.systemPrompt,
        options: options
      ) {
        dismiss()
      }
    }
  }
}

private struct ComposerModelPickerView: View {
  let accountID: ProviderAccountID
  @Binding var selection: ModelID
  @Bindable var providers: ProviderManagementModel

  @Environment(\.dismiss) private var dismiss
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
      Button {
        guard record.isAvailable else { return }
        selection = record.model.id
        dismiss()
      } label: {
        HStack(alignment: .top, spacing: 10) {
          VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
              Text(record.model.displayName)
                .font(.headline)
                .foregroundStyle(.primary)
              if record.model.id == selection {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
              }
            }

            Text(record.model.id.rawValue)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)

            HStack(spacing: 8) {
              if let context = record.model.contextWindow {
                Text("\(context.formatted(.number.notation(.compactName))) ctx")
              }
              if record.model.inputModalities.contains("image") {
                Label("Vision", systemImage: "photo")
              }
              if record.model.inputModalities.contains("file") {
                Label("Files", systemImage: "doc")
              }
              if !record.isAvailable {
                Text("Unavailable")
                  .foregroundStyle(.orange)
              }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!record.isAvailable)
    }
    .navigationTitle("Models")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search models")
  }
}
