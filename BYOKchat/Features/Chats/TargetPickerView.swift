import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// Shared model target picker with adaptive inline/pushed model selection,
/// cached-first discovery and reasoning controls on the parent screen.
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
  @State private var isCommitting = false
  @State private var showingManualModelPrompt = false
  @State private var manualModelID = ""
  @State private var removedManualModelIDs: Set<ModelID> = []
  @State private var refreshAccountID: ProviderAccountID?
  @State private var refreshMessage: String?
  @State private var commitError: String?

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
      .onChange(of: modelID) { _, _ in reasoning = reasoningControl.normalize(reasoning) }
      .task(id: accountID) { await refreshCatalog(for: accountID, force: false) }
      .alert("Enter Model ID", isPresented: $showingManualModelPrompt) {
        TextField("Exact model ID", text: $manualModelID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Cancel", role: .cancel) { manualModelID = "" }
        Button("Use Model") { stageManualModelID() }
          .disabled(manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      } message: {
        Text("Select a model that is not yet listed by your provider.")
      }
      .alert("Model Error", isPresented: Binding(
        get: { commitError != nil },
        set: { if !$0 { commitError = nil } }
      )) {
        Button("OK") { commitError = nil }
      } message: {
        Text(commitError ?? "Unable to save model.")
      }
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

  private var records: [AccountModelRecord] {
    // Use the rows users actually see, without filtering based on discovery age.
    providers.models(for: accountID).filter { !removedManualModelIDs.contains($0.model.id) }
  }

  private var selectedModelTitle: String {
    selectedRecord?.model.displayName ?? modelID?.rawValue ?? "Choose Model"
  }

  private var modelListSection: some View {
    Section {
      if TargetPickerLayout.showsInlineModels(count: records.count) {
        if let modelID,
           !records.contains(where: { $0.model.id == modelID }) {
          // A newly typed ID is staged, but has not been written to storage yet.
          HStack {
            Label(modelID.rawValue, systemImage: "checkmark")
              .foregroundStyle(theme.primaryForegroundColor)
            Spacer()
            Button("Clear entered ID", systemImage: "xmark.circle.fill") {
              clearUnlistedSelection()
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(theme.secondaryForegroundColor)
          }
        }
        if records.isEmpty {
          Text("No saved models yet. Refresh or enter an exact model ID.")
            .font(.footnote)
            .foregroundStyle(theme.secondaryForegroundColor)
        } else {
          ForEach(records) { record in
            Button {
              guard record.isAvailable else { return }
              modelID = record.model.id
            } label: {
              TargetModelRow(record: record, selected: record.model.id == modelID)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!record.isAvailable)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              if record.isManual {
                Button("Remove", systemImage: "trash", role: .destructive) {
                  stageManualRemoval(record.model.id)
                }
              }
            }
            .contextMenu {
              if record.isManual {
                Button("Remove Custom Model", systemImage: "trash", role: .destructive) {
                  stageManualRemoval(record.model.id)
                }
              }
            }
          }
        }
        Button("Enter Model ID", systemImage: "plus") { showManualPrompt() }
      } else {
        // Use a real navigation row instead of a plain Button with a Spacer.
        // A plain-styled Button only hit-tests its rendered children; the blank
        // middle of a wide row otherwise requires repeated, precisely placed taps.
        NavigationLink {
          TargetModelChoiceList(
            records: providers.models(for: accountID),
            selectedModelID: $modelID,
            removedManualModelIDs: $removedManualModelIDs,
            onRemoveManual: stageManualRemoval
          )
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(selectedModelTitle)
              .foregroundStyle(theme.primaryForegroundColor)
            Text("\(records.count) saved models")
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
          }
          .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
          .contentShape(Rectangle())
        }
        if let modelID, !records.contains(where: { $0.model.id == modelID }) {
          Button("Clear entered ID", systemImage: "xmark.circle") {
            clearUnlistedSelection()
          }
        }
      }
    } header: {
      HStack {
        Text("Model")
        Spacer()
        if selectedAccount?.definition.modelsPath != nil {
          Button {
            Task { await refreshCatalog(for: accountID, force: true) }
          } label: {
            if refreshAccountID == accountID {
              ProgressView().controlSize(.mini)
            } else {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
          }
          .disabled(refreshAccountID == accountID)
          .font(.caption)
        }
      }
    } footer: {
      VStack(alignment: .leading, spacing: 3) {
        if let refreshed = providers.lastModelRefreshByAccount[accountID] {
          Text("Catalog checked \(refreshed.formatted(date: .abbreviated, time: .shortened))")
        } else {
          Text("Showing saved models; catalog has not been refreshed yet.")
        }
        if let refreshMessage { Text(refreshMessage) }
        if records.contains(where: { $0.isManual }) {
          Text("Swipe left or long-press a custom model to remove it. Done saves changes.")
        }
        if modelID == nil && !removedManualModelIDs.isEmpty {
          Text("Choose another model before Done, or remove the last model in Provider Settings.")
        }
      }
      .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func clearUnlistedSelection() {
    modelID = records.first(where: { $0.isAvailable })?.model.id
  }

  private func stageManualRemoval(_ id: ModelID) {
    guard providers.models(for: accountID, includeHidden: true).contains(where: {
      $0.model.id == id && $0.isManual
    }) else { return }
    removedManualModelIDs.insert(id)
    if modelID == id { modelID = records.first(where: { $0.isAvailable })?.model.id }
  }

  private func showManualPrompt() {
    manualModelID = ""
    showingManualModelPrompt = true
  }

  private func stageManualModelID() {
    let exactID = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !exactID.isEmpty else { return }
    let selected = ModelID(rawValue: exactID)
    removedManualModelIDs.remove(selected)
    modelID = selected
    manualModelID = ""
  }

  private func refreshCatalog(for requestedAccount: ProviderAccountID, force: Bool) async {
    refreshAccountID = requestedAccount
    if accountID == requestedAccount { refreshMessage = nil }
    defer {
      if refreshAccountID == requestedAccount { refreshAccountID = nil }
    }
    do {
      let result = try await providers.refreshCatalog(accountID: requestedAccount, force: force)
      guard accountID == requestedAccount else { return }
      switch result {
      case .refreshed: refreshMessage = "Model list updated."
      case .unsupported: refreshMessage = "This provider does not offer model discovery. Enter an exact model ID instead."
      case .current, .throttled: break
      }
    } catch {
      guard accountID == requestedAccount else { return }
      refreshMessage = "Could not refresh models: \(error.localizedDescription). Saved models are still available."
    }
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
    removedManualModelIDs.removeAll()
    modelID =
      account.defaultModelID
      ?? providers.models(for: account.id).first(where: \.isAvailable)?.model.id
    reasoning = reasoningControl.normalize(reasoning)
  }

  /// Done is the only persistence boundary for a manually entered ID.
  private func commit() {
    guard !isCommitting, reasoningError == nil, let account = selectedAccount, let modelID else { return }
    isCommitting = true
    commitError = nil
    let reasoning = reasoningControl.normalize(reasoning)
    Task { @MainActor in
      do {
        try await providers.ensureSelectableModel(modelID, for: account.id)
        switch mode {
        case .stage(let commit):
          try await providers.removeManualModels(removedManualModelIDs, for: account.id)
          commit(NewChatTargetSelection(accountID: account.id, modelID: modelID, reasoning: reasoning))
          dismiss()
        case .existingChat(let conversation, let chats):
          var options = conversation.options
          if account.providerID != BuiltInProviders.openRouterID {
            options.openRouterRouting = nil
          }
          options.reasoning = reasoning
          if await chats.updateTarget(
            conversationID: conversation.id,
            account: account,
            modelID: modelID,
            systemPrompt: conversation.systemPrompt,
            options: options
          ) {
            try await providers.removeManualModels(removedManualModelIDs, for: account.id)
            dismiss()
          } else {
            commitError = "Unable to update this chat's model."
          }
        }
      } catch {
        commitError = error.localizedDescription
      }
      isCommitting = false
    }
  }
}

/// UI layout only: model freshness and provider availability do not affect this threshold.
enum TargetPickerLayout {
  static func showsInlineModels(count: Int) -> Bool { count <= 5 }
}

private struct TargetModelRow: View {
  let record: AccountModelRecord
  let selected: Bool

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Text(record.model.displayName)
            .font(.body.weight(.medium))
            .foregroundStyle(theme.primaryForegroundColor)
          if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
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
}

/// Pushed within the picker NavigationStack; selecting a model pops back to reasoning.
private struct TargetModelChoiceList: View {
  let records: [AccountModelRecord]
  @Binding var selectedModelID: ModelID?
  @Binding var removedManualModelIDs: Set<ModelID>
  let onRemoveManual: (ModelID) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var searchText = ""
  @State private var showingManualModelPrompt = false
  @State private var manualModelID = ""

  private var filtered: [AccountModelRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let visible = records.filter { !removedManualModelIDs.contains($0.model.id) }
    guard !query.isEmpty else { return visible }
    return visible.filter {
      $0.model.displayName.localizedCaseInsensitiveContains(query)
        || $0.model.id.rawValue.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    List {
      if filtered.isEmpty {
        ContentUnavailableView.search(text: searchText)
      } else {
        ForEach(filtered) { record in
          Button {
            guard record.isAvailable else { return }
            selectedModelID = record.model.id
            dismiss()
          } label: {
            TargetModelRow(record: record, selected: record.model.id == selectedModelID)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(!record.isAvailable)
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if record.isManual {
              Button("Remove", systemImage: "trash", role: .destructive) {
                onRemoveManual(record.model.id)
              }
            }
          }
          .contextMenu {
            if record.isManual {
              Button("Remove Custom Model", systemImage: "trash", role: .destructive) {
                onRemoveManual(record.model.id)
              }
            }
          }
        }
      }
      Button("Enter Model ID", systemImage: "plus") {
        manualModelID = ""
        showingManualModelPrompt = true
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Choose Model")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search models")
    .safeAreaInset(edge: .bottom) {
      if filtered.contains(where: { $0.isManual }) {
        Text("Swipe left or long-press a custom model to remove it. Done saves changes.")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
          .padding(.horizontal, 16)
          .padding(.vertical, 6)
      }
    }
    .alert("Enter Model ID", isPresented: $showingManualModelPrompt) {
      TextField("Exact model ID", text: $manualModelID)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Button("Cancel", role: .cancel) { manualModelID = "" }
      Button("Use Model") {
        let exactID = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exactID.isEmpty else { return }
        let id = ModelID(rawValue: exactID)
        removedManualModelIDs.remove(id)
        selectedModelID = id
        dismiss()
      }
      .disabled(manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: {
      Text("Select a model that is not yet listed by your provider.")
    }
  }
}
