import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct NewChatTargetSelection: Equatable {
  let accountID: ProviderAccountID
  let modelID: ModelID
  let reasoning: ReasoningOptions?
}

struct NewChatTargetPickerView: View {
  let initialAccountID: ProviderAccountID
  let initialModelID: ModelID
  let initialReasoning: ReasoningOptions?
  @Bindable var providers: ProviderManagementModel
  let useSelection: (NewChatTargetSelection) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var accountID: ProviderAccountID
  @State private var modelID: ModelID
  @State private var reasoningEnabled: Bool
  @State private var reasoningEffort: ReasoningEffort

  init(
    initialAccountID: ProviderAccountID,
    initialModelID: ModelID,
    initialReasoning: ReasoningOptions?,
    providers: ProviderManagementModel,
    useSelection: @escaping (NewChatTargetSelection) -> Void
  ) {
    self.initialAccountID = initialAccountID
    self.initialModelID = initialModelID
    self.initialReasoning = initialReasoning
    self.providers = providers
    self.useSelection = useSelection
    _accountID = State(initialValue: initialAccountID)
    _modelID = State(initialValue: initialModelID)
    _reasoningEnabled = State(initialValue: initialReasoning?.enabled ?? false)
    _reasoningEffort = State(initialValue: initialReasoning?.effort ?? .high)
  }

  private var accounts: [ProviderAccount] {
    providers.accounts.filter(\.isEnabled)
  }

  private var selectedAccount: ProviderAccount? {
    accounts.first { $0.id == accountID }
  }

  private var models: [AccountModelRecord] {
    providers.models(for: accountID)
  }

  private var selectedModel: AccountModelRecord? {
    models.first { $0.model.id == modelID }
  }

  private var supportsReasoning: Bool {
    let parameters = selectedModel?.model.supportedParameters ?? []
    return !parameters.isDisjoint(with: [
      "reasoning", "thinking", "reasoning_effort", "thinkingConfig", "effort",
    ])
  }

  var body: some View {
    NavigationStack {
      List {
        Section("Provider") {
          ForEach(accounts) { account in
            Button {
              selectAccount(account)
            } label: {
              HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(account.label)
                  if let provider = providers.provider(for: account.providerID),
                    provider.displayName != account.label
                  {
                    Text(provider.displayName)
                      .font(.caption)
                      .foregroundStyle(theme.secondaryForegroundColor)
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
        }
        .listRowBackground(theme.surfaceColor)

        Section("Model") {
          NavigationLink {
            NewChatModelPickerView(
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
                .foregroundStyle(theme.secondaryForegroundColor)
                .lineLimit(1)
            }
          }
        }
        .listRowBackground(theme.surfaceColor)

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
        .listRowBackground(theme.surfaceColor)
      }
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
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
      .onChange(of: modelID) { _, _ in normalizeReasoning() }
    }
  }

  private func selectAccount(_ account: ProviderAccount) {
    guard account.id != accountID else { return }
    accountID = account.id
    modelID =
      account.defaultModelID
      ?? providers.models(for: account.id).first(where: \.isAvailable)?.model.id
      ?? providers.models(for: account.id).first?.model.id
      ?? modelID
    normalizeReasoning()
  }

  private func normalizeReasoning() {
    // Manifest data seeds the default; the toggle itself is never locked off.
    reasoningEnabled = supportsReasoning
    reasoningEffort = selectedAccount?.providerID == BuiltInProviders.geminiID ? .medium : .high
  }

  private func save() {
    guard selectedAccount != nil, selectedModel?.isAvailable == true else { return }
    let reasoning = reasoningEnabled
      ? ReasoningOptions(enabled: true, effort: reasoningEffort)
      : nil
    useSelection(
      NewChatTargetSelection(
        accountID: accountID,
        modelID: modelID,
        reasoning: reasoning
      )
    )
    dismiss()
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
}

private struct NewChatModelPickerView: View {
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
              .foregroundStyle(theme.secondaryForegroundColor)
              .lineLimit(1)
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
