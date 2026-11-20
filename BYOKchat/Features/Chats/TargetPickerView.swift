import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// Shared model target picker with adaptive inline/pushed model selection,
/// cached-first discovery and reasoning controls on the parent screen.
///
/// Used in composer & chat settings contexts:
/// - Composer chip & Chat Settings: full surface, commit via closure
///   or `updateTarget`.
struct TargetPickerView: View {
  /// All commits go through Done; the sheet never dismisses on a model tap,
  /// so provider/model/reasoning can be changed freely before applying.
  /// `.stage` is the fresh-chat path, `.existingChat` the existing-chat path
  /// (which writes via `updateTarget`).
  enum CommitMode {
    case stage(commit: (NewChatTargetSelection) -> Void)
    case existingChat(conversation: ChatConversation, chats: ChatManagementModel)
  }

  let mode: CommitMode
  @Bindable var providers: ProviderManagementModel
  let onCreateConnection: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @Environment(PurchaseManager.self) private var purchaseManager

  @State private var accountID: ProviderAccountID
  @State private var modelID: ModelID?
  @State private var reasoning: ReasoningOptions?
  @State private var tokenBudgetText: String
  @State private var isCommitting = false
  @State private var showModelChoiceList = false
  @State private var showAddConnection = false
  @State private var showProUpsell = false
  @State private var accountIDsBeforeCreate: Set<ProviderAccountID> = []
  @State private var showingManualModelPrompt = false
  @State private var manualModelID = ""
  @State private var explicitlyEnteredManualIDs: Set<ModelID> = []
  @State private var removedManualModelIDs: Set<ModelID> = []
  @State private var refreshAccountID: ProviderAccountID?
  @State private var refreshMessage: String?
  @State private var commitError: String?
  @FocusState private var isTokenBudgetFocused: Bool

  init(
    providers: ProviderManagementModel,
    initialAccountID: ProviderAccountID?,
    initialModelID: ModelID?,
    initialReasoning: ReasoningOptions?,
    mode: CommitMode,
    onCreateConnection: (() -> Void)? = nil
  ) {
    self.providers = providers
    self.mode = mode
    self.onCreateConnection = onCreateConnection

    let enabledAccounts = providers.accounts.filter(\.isEnabled)
    let initialEnabledAccount = initialAccountID.flatMap { id in
      enabledAccounts.first { $0.id == id }
    }
    let fallbackAccount =
      providers.resolvedDefaultAccount.flatMap { $0.isEnabled ? $0 : nil }
      ?? enabledAccounts.first { connectionStatus(model: providers, account: $0).isReady }
      ?? enabledAccounts.first
    let resolvedAccount = initialEnabledAccount ?? fallbackAccount
    let resolvedAccountID = resolvedAccount?.id ?? ProviderAccountID(rawValue: "")
    _accountID = State(initialValue: resolvedAccountID)

    let resolvedModel: ModelID?
    if let initialEnabledAccount {
      resolvedModel =
        initialModelID ?? Self.preferredModelID(for: initialEnabledAccount, in: providers)
    } else {
      resolvedModel = Self.preferredModelID(for: fallbackAccount, in: providers)
    }
    _modelID = State(initialValue: resolvedModel)

    let model = resolvedModel.flatMap { id in
      providers.models(for: resolvedAccountID, includeHidden: true)
        .first { $0.model.id == id }?.model
    }
    let control = resolvedAccount.map {
      ModelCapabilityResolver.resolve(kind: $0.kind, modelID: resolvedModel ?? "", model: model)
        .reasoning
    } ?? ModelReasoningControl()
    let normalizedReasoning = control.normalize(initialReasoning)
    _reasoning = State(initialValue: normalizedReasoning)
    _tokenBudgetText = State(
      initialValue: Self.budgetText(for: normalizedReasoning, control: control)
    )
  }

  private static func preferredModelID(
    for account: ProviderAccount?,
    in providers: ProviderManagementModel
  ) -> ModelID? {
    guard let account else { return nil }
    let available = providers.models(for: account.id).filter(\.isAvailable)
    if let defaultID = account.defaultModelID,
      available.contains(where: { $0.model.id == defaultID })
    {
      return defaultID
    }
    return available.first?.model.id
  }

  private static func budgetText(
    for reasoning: ReasoningOptions?,
    control: ModelReasoningControl
  ) -> String {
    if let tokens = reasoning?.maxTokens {
      return String(tokens)
    }
    if let defaultTokens = control.budget?.defaultTokens {
      return String(defaultTokens)
    }
    return ""
  }

  private var accounts: [ProviderAccount] {
    // Ready accounts first (default pinned), then unready; stable sort by visible name.
    providers.accounts
      .filter(\.isEnabled)
      .sorted { lhs, rhs in
        let lhsReady = connectionStatus(model: providers, account: lhs).isReady
        let rhsReady = connectionStatus(model: providers, account: rhs).isReady
        if lhsReady != rhsReady { return lhsReady }
        let lhsDefault = providers.isDefaultAccount(lhs.id)
        let rhsDefault = providers.isDefaultAccount(rhs.id)
        if lhsDefault != rhsDefault { return lhsDefault }
        let groupComparison = displayGroupName(for: lhs)
          .localizedCaseInsensitiveCompare(displayGroupName(for: rhs))
        if groupComparison != .orderedSame {
          return groupComparison == .orderedAscending
        }
        let labelComparison = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
        if labelComparison != .orderedSame {
          return labelComparison == .orderedAscending
        }
        return lhs.id.rawValue < rhs.id.rawValue
      }
  }

  private func displayGroupName(for account: ProviderAccount) -> String {
    if account.kind == .openAICompatible {
      return account.label
    }
    return providers.provider(for: account.providerID)?.displayName ?? account.label
  }

  private var selectedAccount: ProviderAccount? {
    providers.accounts.first { $0.id == accountID && $0.isEnabled }
  }

  private var selectedAccountNeedsCredential: Bool {
    guard let account = selectedAccount else { return false }
    let definition = providers.provider(for: account.providerID) ?? account.definition
    return definition.requiresCredential && !providers.credentialAccountIDs.contains(account.id)
  }

  private var supportsModelDiscovery: Bool {
    selectedAccount?.definition.modelsPath != nil
  }

  private var selectedRecord: AccountModelRecord? {
    modelID.flatMap { id in
      providers.models(for: accountID, includeHidden: true).first { $0.model.id == id }
    }
  }

  private var selectedModelIsUnavailable: Bool {
    guard let modelID else { return false }
    if explicitlyEnteredManualIDs.contains(modelID) { return false }
    guard let record = selectedRecord else { return true }
    return !record.isAvailable
  }

  private var resolvedCapabilities: ResolvedModelCapabilities? {
    guard let account = selectedAccount, let modelID else { return nil }
    return ModelCapabilityResolver.resolve(
      kind: account.kind, modelID: modelID, model: selectedRecord?.model
    )
  }

  private var reasoningControl: ModelReasoningControl {
    resolvedCapabilities?.reasoning ?? .init()
  }

  private var showsTokenBudgetField: Bool {
    guard reasoningControl.budget != nil else { return false }
    return reasoningControl.choice(for: reasoning) == .budget
      || (reasoningControl.combinesEffortAndBudget == true
        && reasoning != nil
        && reasoning?.enabled != false)
  }

  private func anthropicOutputLimit(for options: ReasoningOptions?) -> Int? {
    guard selectedAccount?.kind == .anthropic else { return nil }
    let fallback = AnthropicMessagesAdapter.defaultMaxTokens(
      reasoning: options,
      capabilities: resolvedCapabilities
    )
    if case .existingChat(let conversation, let chats) = mode {
      let live = chats.conversation(conversation.id) ?? conversation
      return live.options.maxOutputTokens ?? fallback
    }
    return fallback
  }

  private var reasoningError: String? {
    if showsTokenBudgetField {
      let trimmed = tokenBudgetText.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        return "Enter a thinking token budget."
      }
      guard let parsed = Int(trimmed) else {
        return "Enter a whole number of tokens."
      }
      var candidate = reasoning ?? ReasoningOptions(enabled: true)
      candidate.maxTokens = parsed
      return reasoningControl.budgetValidationMessage(
        candidate,
        outputLimit: anthropicOutputLimit(for: candidate)
      )
    }
    return reasoningControl.budgetValidationMessage(
      reasoning,
      outputLimit: anthropicOutputLimit(for: reasoning)
    )
  }

  private var canCommit: Bool {
    guard let account = selectedAccount, account.isEnabled, !selectedAccountNeedsCredential else {
      return false
    }
    guard modelID != nil, !selectedModelIsUnavailable else { return false }
    return !isCommitting && reasoningError == nil
  }

  var body: some View {
    NavigationStack {
      List {
        accountStripSection
        if selectedAccount != nil {
          modelListSection
          if !reasoningControl.choices.isEmpty {
            reasoningSection
          }
        }
      }
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle("Model")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(isPresented: $showModelChoiceList) {
        TargetModelChoiceList(
          records: providers.models(for: accountID),
          selectedModelID: $modelID,
          removedManualModelIDs: $removedManualModelIDs,
          onRemoveManual: stageManualRemoval,
          onStageManualModel: stageManualModelID(_:)
        )
      }
      .onChange(of: reasoningControl) { _, control in
        reasoning = control.normalize(reasoning)
        syncTokenBudgetText()
      }
      .onChange(of: modelID) { _, _ in
        reasoning = reasoningControl.normalize(reasoning)
        syncTokenBudgetText()
      }
      .task(id: accountID) { await refreshCatalog(for: accountID, force: false) }
      .sheet(isPresented: $showAddConnection) {
        NavigationStack {
          ConnectionEditorView(
            model: providers,
            onFinished: handleCreatedConnection
          )
        }
        .presentationDragIndicator(.visible)
      }
      .sheet(isPresented: $showProUpsell) {
        BYOKProUpsellFlow(feature: .providerAccounts)
      }
      .alert("Enter Model ID", isPresented: $showingManualModelPrompt) {
        TextField("Exact model ID", text: $manualModelID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Cancel", role: .cancel) { manualModelID = "" }
        Button("Use Model") { commitManualPrompt() }
          .disabled(manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      } message: {
        Text("Select a model that is not yet listed by your provider.")
      }
      .alert(
        "Model Error",
        isPresented: Binding(
          get: { commitError != nil },
          set: { if !$0 { commitError = nil } }
        )
      ) {
        Button("OK") { commitError = nil }
      } message: {
        Text(commitError ?? "Unable to save model.")
      }
      .toolbar {
        if isTokenBudgetFocused {
          ToolbarItem(placement: .keyboard) {
            Button("Done") { isTokenBudgetFocused = false }
          }
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isCommitting)
        }
        ToolbarItem(placement: .confirmationAction) {
          if isCommitting {
            ProgressView()
          } else {
            Button("Done") { commit() }
              .disabled(!canCommit)
          }
        }
      }
    }
    .interactiveDismissDisabled(isCommitting)
  }

  // MARK: - Sections

  private var accountStripSection: some View {
    Section("Provider") {
      if accounts.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("No enabled connections. Add or enable a connection to choose a model.")
            .font(.footnote)
            .foregroundStyle(theme.secondaryForegroundColor)
          Button("Add Connection", systemImage: "plus.circle.fill") {
            beginAddConnection()
          }
          .font(.subheadline.weight(.medium))
        }
        .padding(.vertical, 4)
        .listRowBackground(theme.surfaceColor)
      } else {
        ScrollViewReader { proxy in
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
              ForEach(accounts) { account in
                accountAvatar(account)
                  .id(account.id)
              }
              addConnectionTile
            }
            .padding(.vertical, 4)
          }
          .onAppear {
            proxy.scrollTo(accountID, anchor: .center)
          }
          .onChange(of: accountID) { _, id in
            withAnimation(.snappy(duration: 0.2)) {
              proxy.scrollTo(id, anchor: .center)
            }
          }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
      }
    }
  }

  private var addConnectionTile: some View {
    Button {
      beginAddConnection()
    } label: {
      VStack(spacing: 5) {
        Image(systemName: "plus")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(theme.accentColor)
          .frame(width: 44, height: 44)
          .background(
            theme.elevatedSurfaceColor,
            in: RoundedRectangle(cornerRadius: 44 * 0.3, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 44 * 0.3, style: .continuous)
              .stroke(theme.borderColor, lineWidth: 1)
          }
        Text("Add")
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor)
          .lineLimit(1)
      }
      .frame(width: 64)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Add Connection")
  }

  private func accountAvatar(_ account: ProviderAccount) -> some View {
    let status = connectionStatus(model: providers, account: account)
    let isSelected = account.id == accountID
    let label = rowLabel(account)
    return Button {
      selectAccount(account)
    } label: {
      VStack(spacing: 5) {
        ConnectionProviderMark(definition: providers.provider(for: account.providerID), size: 44)
          .overlay {
            RoundedRectangle(cornerRadius: 44 * 0.3, style: .continuous)
              .stroke(isSelected ? theme.accentColor : .clear, lineWidth: 2)
          }
        Text(label)
          .font(.caption2)
          .foregroundStyle(
            isSelected ? theme.primaryForegroundColor : theme.secondaryForegroundColor
          )
          .lineLimit(1)
        if !status.isReady {
          Text(status.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
      }
      .frame(width: 64)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(status.isReady ? "Ready" : status.label)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func rowLabel(_ account: ProviderAccount) -> String {
    let providerName = providers.provider(for: account.providerID)?.displayName
      ?? account.providerID.rawValue
    let sameProviderCount = providers.accounts(for: account.providerID).count
    if account.label == providerName || (account.label == "Personal" && sameProviderCount == 1) {
      return providerName
    }
    return account.label
  }

  private var records: [AccountModelRecord] {
    // Use the rows users actually see, without filtering based on discovery age.
    providers.models(for: accountID).filter { !removedManualModelIDs.contains($0.model.id) }
  }

  private var selectedModelTitle: String {
    if let record = selectedRecord {
      return record.isHidden ? "\(record.model.displayName) (Hidden)" : record.model.displayName
    }
    return modelID?.rawValue ?? "Choose Model"
  }

  private var modelListSection: some View {
    Section {
      if selectedAccountNeedsCredential {
        Label(
          "This connection needs an API key. Add one in AI Providers before using it.",
          systemImage: "key.slash"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
      }
      if selectedModelIsUnavailable {
        Label(
          selectedRecord == nil
            ? "The current model is not in your saved models. Choose another model or enter an exact model ID."
            : "The current model is no longer reported by this provider. Choose another model or enter an exact model ID.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
      }
      if TargetPickerLayout.showsInlineModels(count: records.count) {
        if let modelID,
          !records.contains(where: { $0.model.id == modelID })
        {
          unlistedOrHiddenRow(for: modelID)
        }
        if records.isEmpty {
          Text(
            supportsModelDiscovery
              ? "No saved models yet. Refresh or enter an exact model ID."
              : "No saved models yet. Enter an exact model ID."
          )
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
        Button {
          showModelChoiceList = true
        } label: {
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
              Text(selectedModelTitle)
                .foregroundStyle(theme.primaryForegroundColor)
              Text(records.count == 1 ? "1 saved model" : "\(records.count) saved models")
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
          .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if let modelID,
          explicitlyEnteredManualIDs.contains(modelID),
          !records.contains(where: { $0.model.id == modelID })
        {
          Button("Clear entered ID", systemImage: "xmark.circle") {
            clearUnlistedSelection()
          }
        }
      }
    } header: {
      HStack {
        Text("Model")
        Spacer()
        if supportsModelDiscovery {
          Button {
            Task { await refreshCatalog(for: accountID, force: true) }
          } label: {
            if refreshAccountID == accountID {
              ProgressView().controlSize(.mini)
            } else {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
          }
          .disabled(refreshAccountID == accountID || selectedAccountNeedsCredential)
          .font(.caption)
        }
      }
    } footer: {
      VStack(alignment: .leading, spacing: 3) {
        if supportsModelDiscovery {
          if let refreshed = providers.lastModelRefreshByAccount[accountID] {
            Text("Catalog checked \(refreshed.formatted(date: .abbreviated, time: .shortened))")
          } else {
            Text("Showing saved models; catalog has not been refreshed yet.")
          }
        } else {
          Text("This provider does not offer model discovery. Enter an exact model ID to add models.")
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

  @ViewBuilder
  private func unlistedOrHiddenRow(for modelID: ModelID) -> some View {
    if let hiddenRecord = selectedRecord, hiddenRecord.isHidden {
      TargetModelRow(record: hiddenRecord, selected: true, showHiddenBadge: true)
    } else if explicitlyEnteredManualIDs.contains(modelID) {
      // A newly typed ID is staged, but has not been written to storage yet.
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Label(modelID.rawValue, systemImage: "checkmark")
            .foregroundStyle(theme.primaryForegroundColor)
          Text("Custom • Saves on Done")
            .font(.caption2)
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        Spacer()
        Button("Clear entered ID", systemImage: "xmark.circle.fill") {
          clearUnlistedSelection()
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(theme.secondaryForegroundColor)
      }
    } else {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(modelID.rawValue)
            .font(.body.monospaced())
            .foregroundStyle(theme.secondaryForegroundColor)
          Text("Not in saved models")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
        Spacer()
        Button("Clear", systemImage: "xmark.circle.fill") {
          clearUnlistedSelection()
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
  }

  private func clearUnlistedSelection() {
    if let modelID {
      explicitlyEnteredManualIDs.remove(modelID)
    }
    modelID = records.first(where: { $0.isAvailable })?.model.id
  }

  private func stageManualRemoval(_ id: ModelID) {
    guard providers.models(for: accountID, includeHidden: true).contains(where: {
      $0.model.id == id && $0.isManual
    }) else { return }
    explicitlyEnteredManualIDs.remove(id)
    removedManualModelIDs.insert(id)
    if modelID == id { modelID = records.first(where: { $0.isAvailable })?.model.id }
  }

  private func showManualPrompt() {
    manualModelID = ""
    showingManualModelPrompt = true
  }

  private func commitManualPrompt() {
    let exactID = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !exactID.isEmpty else { return }
    stageManualModelID(ModelID(rawValue: exactID))
    manualModelID = ""
  }

  private func stageManualModelID(_ selected: ModelID) {
    removedManualModelIDs.remove(selected)
    explicitlyEnteredManualIDs.insert(selected)
    modelID = selected
  }

  private func refreshCatalog(for requestedAccount: ProviderAccountID, force: Bool) async {
    guard let account = providers.accounts.first(where: { $0.id == requestedAccount && $0.isEnabled })
    else { return }
    let definition = providers.provider(for: account.providerID) ?? account.definition
    guard definition.modelsPath != nil else { return }
    if !force && definition.requiresCredential && !providers.credentialAccountIDs.contains(account.id)
    {
      if accountID == requestedAccount { refreshMessage = nil }
      return
    }
    refreshAccountID = requestedAccount
    if accountID == requestedAccount { refreshMessage = nil }
    defer {
      if refreshAccountID == requestedAccount { refreshAccountID = nil }
    }
    do {
      let result = try await providers.refreshCatalog(accountID: requestedAccount, force: force)
      guard accountID == requestedAccount else { return }
      switch result {
      case .refreshed:
        refreshMessage = "Model list updated."
        if modelID == nil && removedManualModelIDs.isEmpty {
          modelID = Self.preferredModelID(for: selectedAccount, in: providers)
        }
      case .unsupported:
        refreshMessage = "This provider does not offer model discovery. Enter an exact model ID instead."
      case .current, .throttled:
        break
      }
    } catch {
      guard accountID == requestedAccount else { return }
      refreshMessage =
        "Could not refresh models: \(error.localizedDescription). Saved models are still available."
    }
  }

  private var reasoningSection: some View {
    Section("Reasoning") {
      Picker(
        "Thinking",
        selection: Binding(
          get: { reasoningControl.choice(for: reasoning) },
          set: { choice in
            reasoning = reasoningControl.options(for: choice, preserving: reasoning)
            syncTokenBudgetText()
          }
        )
      ) {
        ForEach(reasoningControl.choices, id: \.self) { choice in
          Text(choice.title).tag(choice)
        }
      }
      if showsTokenBudgetField, let budget = reasoningControl.budget {
        TextField("Token budget", text: $tokenBudgetText)
          .keyboardType(budget.allowsAutomatic ? .numbersAndPunctuation : .numberPad)
          .focused($isTokenBudgetFocused)
          .onChange(of: tokenBudgetText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Int(trimmed) else { return }
            var options = reasoning ?? ReasoningOptions(enabled: true)
            options.enabled = true
            options.maxTokens = parsed
            reasoning = options
          }
        Text(budgetHint(for: budget))
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      Text(reasoningError ?? reasoningControl.label(for: reasoning))
        .font(.caption)
        .foregroundStyle(reasoningError != nil ? Color.red : theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func budgetHint(for budget: ReasoningBudgetControl) -> String {
    let outputLimit = anthropicOutputLimit(for: reasoning)
    let outputCap = outputLimit.map { $0 - 1 }
    let effectiveMaximum: Int?
    switch (budget.maximum, outputCap) {
    case (let maxBudget?, let cap?): effectiveMaximum = min(maxBudget, cap)
    case (let maxBudget?, nil): effectiveMaximum = maxBudget
    case (nil, let cap?): effectiveMaximum = cap
    case (nil, nil): effectiveMaximum = nil
    }

    if let maxTokens = effectiveMaximum, maxTokens < budget.minimum, let outputLimit {
      return "The thinking budget must be below \(outputLimit.formatted()) output tokens."
    }

    if budget.allowsAutomatic {
      if let maxTokens = effectiveMaximum {
        return "Use -1 for automatic thinking, or \(budget.minimum.formatted())–\(maxTokens.formatted()) tokens."
      }
      return "Use -1 for automatic thinking, or at least \(budget.minimum.formatted()) tokens."
    }
    if let maxTokens = effectiveMaximum {
      return "Enter \(budget.minimum.formatted())–\(maxTokens.formatted()) tokens."
    }
    return "Minimum \(budget.minimum.formatted()) tokens."
  }

  private func syncTokenBudgetText() {
    tokenBudgetText = Self.budgetText(for: reasoning, control: reasoningControl)
  }

  // MARK: - Selection & Add Connection

  private func beginAddConnection() {
    if let onCreateConnection {
      onCreateConnection()
      return
    }
    if BYOKProAccess.canCreateProviderAccount(
      currentCount: providers.accounts.count,
      hasPro: purchaseManager.hasPro
    ) {
      accountIDsBeforeCreate = Set(providers.accounts.map(\.id))
      showAddConnection = true
    } else {
      showProUpsell = true
    }
  }

  private func handleCreatedConnection() {
    if let created = providers.accounts.first(where: {
      $0.isEnabled && !accountIDsBeforeCreate.contains($0.id)
    }) {
      selectAccount(created)
    }
    accountIDsBeforeCreate = []
  }

  private func selectAccount(_ account: ProviderAccount) {
    guard account.id != accountID else { return }
    accountID = account.id
    removedManualModelIDs.removeAll()
    explicitlyEnteredManualIDs.removeAll()
    refreshMessage = nil
    modelID = Self.preferredModelID(for: account, in: providers)
    reasoning = reasoningControl.normalize(reasoning)
    syncTokenBudgetText()
  }

  /// Done is the only persistence boundary for a manually entered ID.
  private func commit() {
    guard canCommit, let account = selectedAccount, let modelID else { return }
    isTokenBudgetFocused = false
    isCommitting = true
    commitError = nil
    let normalizedReasoning = reasoningControl.normalize(reasoning)
    let removalsToApply = removedManualModelIDs.subtracting([modelID])
    let selectedWasAvailableAndVisible =
      selectedRecord?.isAvailable == true && selectedRecord?.isHidden == false

    if case .existingChat(let snapshot, let chats) = mode {
      let liveConversation = chats.conversation(snapshot.id) ?? snapshot
      let isUnchanged =
        liveConversation.accountID == account.id
        && liveConversation.providerID == account.providerID
        && liveConversation.modelID == modelID
        && liveConversation.options.reasoning == normalizedReasoning
        && removalsToApply.isEmpty
        && selectedWasAvailableAndVisible
      if isUnchanged {
        isCommitting = false
        dismiss()
        return
      }
    }

    Task { @MainActor in
      do {
        try await providers.ensureSelectableModel(modelID, for: account.id)
        switch mode {
        case .stage(let commit):
          if !removalsToApply.isEmpty {
            try await providers.removeManualModels(removalsToApply, for: account.id)
          }
          commit(
            NewChatTargetSelection(
              accountID: account.id,
              modelID: modelID,
              reasoning: normalizedReasoning
            )
          )
          dismiss()
        case .existingChat(let snapshot, let chats):
          let liveConversation = chats.conversation(snapshot.id) ?? snapshot
          var options = liveConversation.options
          if account.providerID != BuiltInProviders.openRouterID {
            options.openRouterRouting = nil
          }
          options.reasoning = normalizedReasoning
          if await chats.updateTarget(
            conversationID: liveConversation.id,
            account: account,
            modelID: modelID,
            systemPrompt: liveConversation.systemPrompt,
            options: options
          ) {
            if !removalsToApply.isEmpty {
              try await providers.removeManualModels(removalsToApply, for: account.id)
            }
            dismiss()
          } else {
            commitError = chats.errorMessage ?? "Unable to update this chat's model."
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
  var showHiddenBadge: Bool = false

  @Environment(\.appFoundationTheme) private var theme

  private var details: String {
    var parts: [String] = []
    if let context = record.model.contextWindow {
      parts.append("\(context.formatted(.number.notation(.compactName))) ctx")
    }
    if record.model.inputModalities.contains("image") {
      parts.append("Vision")
    }
    if record.model.inputModalities.contains("file") {
      parts.append("Files")
    }
    if record.isManual {
      parts.append("Custom")
    }
    if showHiddenBadge {
      parts.append("Hidden")
    }
    return parts.joined(separator: " • ")
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          if record.isFavorite {
            Image(systemName: "star.fill")
              .font(.caption)
              .foregroundStyle(.yellow)
          }
          Text(record.model.displayName)
            .font(.body.weight(.medium))
            .foregroundStyle(theme.primaryForegroundColor)
          if selected {
            Image(systemName: "checkmark")
              .foregroundStyle(.tint)
          }
        }
        Text(record.model.id.rawValue)
          .font(.caption.monospaced())
          .foregroundStyle(theme.secondaryForegroundColor)
          .lineLimit(2)
        if !details.isEmpty || !record.isAvailable {
          HStack(spacing: 6) {
            if !record.isAvailable {
              Text("Unavailable")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
            }
            if !details.isEmpty {
              Text(details)
                .font(.caption2)
                .foregroundStyle(theme.secondaryForegroundColor)
                .lineLimit(1)
            }
          }
        }
      }
      Spacer(minLength: 8)
    }
    .contentShape(Rectangle())
    .opacity(record.isAvailable ? 1 : 0.55)
  }
}

/// Pushed within the picker NavigationStack; selecting a model pops back to reasoning.
private struct TargetModelChoiceList: View {
  let records: [AccountModelRecord]
  @Binding var selectedModelID: ModelID?
  @Binding var removedManualModelIDs: Set<ModelID>
  let onRemoveManual: (ModelID) -> Void
  let onStageManualModel: (ModelID) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var searchText = ""
  @State private var showingManualModelPrompt = false
  @State private var manualModelID = ""

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var filtered: [AccountModelRecord] {
    let query = trimmedSearch
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
        if trimmedSearch.isEmpty {
          ContentUnavailableView(
            "No Models",
            systemImage: "square.stack.3d.up.slash",
            description: Text("Enter an exact model ID to add one.")
          )
          .listRowBackground(Color.clear)
        } else {
          ContentUnavailableView.search(text: searchText)
            .listRowBackground(Color.clear)
        }
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
          .listRowBackground(theme.surfaceColor)
          .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
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
        openManualPrompt(prefillSearchIfEmpty: filtered.isEmpty)
      }
      .listRowBackground(theme.surfaceColor)
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Choose Model")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search models")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Enter Model ID", systemImage: "plus") {
          openManualPrompt(prefillSearchIfEmpty: filtered.isEmpty)
        }
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
        onStageManualModel(ModelID(rawValue: exactID))
        dismiss()
      }
      .disabled(manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: {
      Text("Select a model that is not yet listed by your provider.")
    }
  }

  private func openManualPrompt(prefillSearchIfEmpty: Bool) {
    manualModelID = prefillSearchIfEmpty ? trimmedSearch : ""
    showingManualModelPrompt = true
  }
}
