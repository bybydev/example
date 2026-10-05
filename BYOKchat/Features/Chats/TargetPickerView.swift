import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// The shared target picker: account strip + searchable model list + effort
/// segments, staged in place and committed in one write.
///
/// Used in three contexts per the redesign:
/// - Composer chip (fresh + existing chats): full surface, commit via closure
///   or `updateTarget`.
/// - Editor default-model field: model list only (no strip/reasoning).
/// - Models management: favorites/hide/search on the same list body.
struct TargetPickerView: View {
  /// All commits go through a closure on Done; the sheet never dismisses on a
  /// model tap, so provider/model/reasoning can be changed freely before
  /// applying. `.stage` is the fresh-chat path, `.existingChat` the
  /// existing-chat path (which writes via `updateTarget` inside its closure).
  enum CommitMode {
    case stage(commit: (NewChatTargetSelection) -> Void)
    case existingChat(conversation: ChatConversation, chats: ChatManagementModel)
  }

  let mode: CommitMode
  @Bindable var providers: ProviderManagementModel

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme

  @State private var accountID: ProviderAccountID
  @State private var modelID: ModelID?
  @State private var reasoning: ReasoningOptions?
  @State private var searchText = ""
  @State private var isCommitting = false

  init(
    providers: ProviderManagementModel,
    initialAccountID: ProviderAccountID?,
    initialModelID: ModelID?,
    initialReasoning: ReasoningOptions?,
    mode: CommitMode
  ) {
    self.providers = providers
    self.mode = mode
    let resolvedAccount = initialAccountID
      ?? providers.resolvedDefaultAccount?.id
      ?? providers.accounts.first(where: \.isEnabled)?.id
      ?? providers.accounts.first?.id
      ?? ProviderAccountID(rawValue: "")
    _accountID = State(initialValue: resolvedAccount)
    let resolvedModel = initialModelID
      ?? providers.accounts.first(where: { $0.id == resolvedAccount })?.defaultModelID
      ?? providers.models(for: resolvedAccount).first(where: \.isAvailable)?.model.id
    _modelID = State(initialValue: resolvedModel)
    let account = providers.accounts.first { $0.id == resolvedAccount }
    let model = providers.models(for: resolvedAccount, includeHidden: true).first { $0.model.id == resolvedModel }?.model
    let control = account.map {
      ModelCapabilityResolver.resolve(kind: $0.kind, modelID: resolvedModel ?? "", model: model).reasoning
    } ?? ModelReasoningControl()
    _reasoning = State(initialValue: control.normalize(initialReasoning))
  }

  private var accounts: [ProviderAccount] {
    // Ready accounts first, then the rest; one avatar per account.
    providers.accounts
      .filter(\.isEnabled)
      .sorted { lhs, rhs in
        let lhsReady = connectionStatus(model: providers, account: lhs).isReady
        let rhsReady = connectionStatus(model: providers, account: rhs).isReady
        if lhsReady != rhsReady { return lhsReady }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
      }
  }

  private var selectedAccount: ProviderAccount? {
    providers.accounts.first { $0.id == accountID }
  }

  private var selectedRecord: AccountModelRecord? {
    modelID.flatMap { id in
      providers.models(for: accountID, includeHidden: true).first { $0.model.id == id }
    }
  }

  private var reasoningControl: ModelReasoningControl {
    guard let account = selectedAccount, let modelID else { return .init() }
    return ModelCapabilityResolver.resolve(kind: account.kind, modelID: modelID, model: selectedRecord?.model).reasoning
  }

  private var reasoningError: String? {
    let outputLimit: Int?
    if selectedAccount?.kind == .anthropic {
      if case .existingChat(let conversation, _) = mode { outputLimit = conversation.options.maxOutputTokens ?? 4_096 }
      else { outputLimit = 4_096 }
    } else { outputLimit = nil }
    return reasoningControl.budgetValidationMessage(reasoning, outputLimit: outputLimit)
  }

  var body: some View {
    NavigationStack {
      List {
        accountStripSection
        modelListSection
        if !reasoningControl.choices.isEmpty {
          reasoningSection
        }
      }
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .onChange(of: reasoningControl) { _, control in reasoning = control.normalize(reasoning) }
      .navigationTitle("Model")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Search models")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { commit() }
            .disabled(modelID == nil || isCommitting || reasoningError != nil)
        }
      }
    }
  }

  // MARK: - Sections

  private var accountStripSection: some View {
    Section("Provider") {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(accounts) { account in
            accountAvatar(account)
          }
          if let create = onCreateConnection {
            Button(action: create) {
              VStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                  .font(.system(size: 26))
                Text("Add")
                  .font(.caption2)
                  .foregroundStyle(theme.secondaryForegroundColor)
              }
              .frame(width: 52)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.vertical, 4)
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }
  }

  var onCreateConnection: (() -> Void)?

  private func accountAvatar(_ account: ProviderAccount) -> some View {
    let status = connectionStatus(model: providers, account: account)
    let isSelected = account.id == accountID
    return Button {
      selectAccount(account)
    } label: {
      VStack(spacing: 5) {
        ConnectionProviderMark(definition: providers.provider(for: account.providerID), size: 44)
          .overlay {
            RoundedRectangle(cornerRadius: 44 * 0.3, style: .continuous)
              .stroke(isSelected ? theme.accentColor : .clear, lineWidth: 2)
          }
        Text(rowLabel(account))
          .font(.caption2)
          .foregroundStyle(isSelected ? theme.primaryForegroundColor : theme.secondaryForegroundColor)
          .lineLimit(1)
        if !status.isReady {
          Text(status.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func rowLabel(_ account: ProviderAccount) -> String {
    let providerName = providers.provider(for: account.providerID)?.displayName
      ?? account.providerID.rawValue
    if account.label == providerName || account.label == "Personal" {
      return providerName
    }
    return account.label
  }

  private var modelListSection: some View {
    Section("Model") {
      if records.isEmpty {
        ContentUnavailableView.search(text: searchText)
          .listRowBackground(Color.clear)
      } else {
        ForEach(records) { record in
          modelRow(record)
        }
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var records: [AccountModelRecord] {
    var values = providers.models(for: accountID, includeHidden: true)
    let query = searchText.trimmingCharacters(in: .whitespaces)
    if !query.isEmpty {
      values = values.filter {
        $0.model.displayName.localizedCaseInsensitiveContains(query)
          || $0.model.id.rawValue.localizedCaseInsensitiveContains(query)
      }
    }
    return values
  }

  @ViewBuilder
  private func modelRow(_ record: AccountModelRecord) -> some View {
    let isSelected = record.model.id == modelID
    Button {
      // Stages the selection only — the sheet stays open so provider, model,
      // and reasoning can all be adjusted before Done applies everything.
      guard record.isAvailable, !record.isHidden else { return }
      modelID = record.model.id
    } label: {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 6) {
            Text(record.model.displayName)
              .font(.body.weight(.medium))
              .foregroundStyle(theme.primaryForegroundColor)
            if isSelected {
              Image(systemName: "checkmark")
                .foregroundStyle(.tint)
            }
          }
          Text(record.model.id.rawValue)
            .font(.caption.monospaced())
            .foregroundStyle(theme.secondaryForegroundColor)
            .lineLimit(2)
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
          }
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
        }
        Spacer(minLength: 8)
      }
      .contentShape(Rectangle())
      .opacity(record.isAvailable ? 1 : 0.45)
    }
    .buttonStyle(.plain)
    .disabled(!record.isAvailable || record.isHidden)
  }

  private var reasoningSection: some View {
    Section("Reasoning") {
      Picker("Thinking", selection: Binding(
        get: { reasoningControl.choice(for: reasoning) },
        set: { reasoning = reasoningControl.options(for: $0, preserving: reasoning) }
      )) {
        ForEach(reasoningControl.choices, id: \.self) { choice in
          Text(choice.title).tag(choice)
        }
      }
      if reasoningControl.choice(for: reasoning) == .budget
        || (reasoningControl.combinesEffortAndBudget == true && reasoning != nil && reasoning?.enabled != false),
        let budget = reasoningControl.budget {
        TextField("Token budget", value: Binding(
          get: { reasoning?.maxTokens ?? budget.defaultTokens },
          set: { value in
            var options = reasoning ?? ReasoningOptions(enabled: true)
            options.maxTokens = value
            reasoning = options
          }
        ), format: .number)
        .keyboardType(.numbersAndPunctuation)
        Text(budget.allowsAutomatic ? "Use -1 for automatic thinking." : "Minimum \(budget.minimum) tokens.")
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      Text(reasoningError ?? reasoningControl.label(for: reasoning))
        .font(.caption)
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  // MARK: - Selection

  private func selectAccount(_ account: ProviderAccount) {
    guard account.id != accountID else { return }
    accountID = account.id
    modelID =
      account.defaultModelID
      ?? providers.models(for: account.id).first(where: \.isAvailable)?.model.id
    reasoning = reasoningControl.normalize(reasoning)
  }

  /// Commit happens only on Done: whatever is staged at that moment
  /// (account, model, effort) is applied once, then the sheet dismisses.
  private func commit() {
    guard !isCommitting, reasoningError == nil, let account = selectedAccount, let modelID else { return }
    isCommitting = true
    let reasoning = reasoningControl.normalize(reasoning)

    switch mode {
    case .stage(let commit):
      commit(NewChatTargetSelection(accountID: account.id, modelID: modelID, reasoning: reasoning))
      dismiss()
    case .existingChat(let conversation, let chats):
      var options = conversation.options
      if account.providerID != BuiltInProviders.openRouterID {
        options.openRouterRouting = nil
      }
      options.reasoning = reasoning
      Task { @MainActor in
        if await chats.updateTarget(
          conversationID: conversation.id,
          account: account,
          modelID: modelID,
          systemPrompt: conversation.systemPrompt,
          options: options
        ) {
          dismiss()
        } else {
          isCommitting = false
        }
      }
    }
  }
}
