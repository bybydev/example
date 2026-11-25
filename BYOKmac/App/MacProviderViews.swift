import AppKit
import BYOKchatProviderCore
import Foundation
import SwiftUI

// MARK: - Shared Model Capability Badges

private struct MacBadgeFlowLayout: Layout {
  var horizontalSpacing: CGFloat = 5
  var verticalSpacing: CGFloat = 4

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > maxWidth {
        x = 0
        y += rowHeight + verticalSpacing
        rowHeight = 0
      }
      totalWidth = max(totalWidth, x + size.width)
      x += size.width + horizontalSpacing
      rowHeight = max(rowHeight, size.height)
    }

    return CGSize(width: totalWidth, height: y + rowHeight)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX && x + size.width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + verticalSpacing
        rowHeight = 0
      }
      subview.place(
        at: CGPoint(x: x, y: y),
        anchor: .topLeading,
        proposal: ProposedViewSize(size)
      )
      x += size.width + horizontalSpacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

struct MacModelCapabilityBadges: View {
  let kind: ProviderKind
  let model: ProviderModel
  var isManual: Bool = false
  var isHidden: Bool = false
  var isAvailable: Bool = true
  var resolvedCapabilities: ResolvedModelCapabilities? = nil

  var body: some View {
    let capabilities = resolvedCapabilities
      ?? ModelCapabilityResolver.resolve(kind: kind, modelID: model.id, model: model)
    let contextLabel: String? = (capabilities.contextWindow ?? model.contextWindow).map {
      "\($0.formatted(.number.notation(.compactName))) ctx"
    }
    let supportsVision = capabilities[.imageInput] == .supported || model.inputModalities.contains("image")
    let supportsFiles = capabilities[.fileInput] == .supported || model.inputModalities.contains("file")
    let supportsReasoning = capabilities[.reasoning] == .supported
    let supportsTools = capabilities[.tools] == .supported
    let hasAnyBadge =
      !isAvailable || contextLabel != nil || supportsVision || supportsFiles || supportsReasoning
      || supportsTools || isManual || isHidden

    if hasAnyBadge {
      MacBadgeFlowLayout(horizontalSpacing: 5, verticalSpacing: 4) {
        if !isAvailable {
          badge("Unavailable", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let contextLabel {
          badge(contextLabel, systemImage: nil, tint: MacDesignTokens.Colors.textMuted)
        }
        if supportsVision {
          badge("Vision", systemImage: "eye", tint: MacDesignTokens.Colors.textMuted)
        }
        if supportsFiles {
          badge("Files", systemImage: "doc", tint: MacDesignTokens.Colors.textMuted)
        }
        if supportsReasoning {
          badge("Reasoning", systemImage: "brain", tint: MacDesignTokens.Colors.accent)
        }
        if supportsTools {
          badge("Tools", systemImage: "wrench.and.screwdriver", tint: MacDesignTokens.Colors.textMuted)
        }
        if isManual {
          badge("Custom", systemImage: nil, tint: MacDesignTokens.Colors.accent)
        }
        if isHidden {
          badge("Hidden", systemImage: "eye.slash", tint: MacDesignTokens.Colors.textMuted)
        }
      }
    }
  }

  private func badge(_ text: String, systemImage: String?, tint: Color) -> some View {
    HStack(spacing: 3) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 9, weight: .medium))
      }
      Text(text)
        .font(.system(size: 10, weight: .medium))
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(tint.opacity(0.11), in: Capsule())
    .fixedSize()
  }
}

// MARK: - Lightweight Composer Model Popover

nonisolated enum MacComposerModelPickerSupport: Sendable {
  struct RowItem: Identifiable, Equatable, Sendable {
    let id: ModelID
    let displayName: String
    let subtitleID: String?
    let searchKey: String
    let isFavorite: Bool
    let isManual: Bool
    let isAvailable: Bool
    let supportsVision: Bool
  }

  static func makeRows(from records: [AccountModelRecord]) -> [RowItem] {
    var rows: [RowItem] = []
    rows.reserveCapacity(records.count)
    for record in records {
      let modelID = record.model.id
      let rawName = record.model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      let displayName = rawName.isEmpty ? modelID.rawValue : rawName
      let subtitleID =
        displayName.caseInsensitiveCompare(modelID.rawValue) == .orderedSame
        ? nil
        : modelID.rawValue
      let searchKey = "\(displayName) \(modelID.rawValue)".lowercased()
      rows.append(
        RowItem(
          id: modelID,
          displayName: displayName,
          subtitleID: subtitleID,
          searchKey: searchKey,
          isFavorite: record.isFavorite,
          isManual: record.isManual,
          isAvailable: record.isAvailable,
          supportsVision: record.model.inputModalities.contains("image")
        )
      )
    }
    return rows
  }

  static func filterRows(_ rows: [RowItem], query: String) -> [RowItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return rows }
    return rows.filter { $0.searchKey.contains(trimmed) }
  }

  static func partitionRows(
    _ rows: [RowItem],
    hasQuery: Bool
  ) -> (favorites: [RowItem], others: [RowItem]) {
    guard !hasQuery else { return ([], rows) }
    var favorites: [RowItem] = []
    var others: [RowItem] = []
    for row in rows {
      if row.isFavorite {
        favorites.append(row)
      } else {
        others.append(row)
      }
    }
    return (favorites, others)
  }
}

struct MacComposerModelPopover: View {
  @Bindable var providers: MacProviderModel
  let initialTarget: MacChatTarget?
  let maxOutputTokens: Int?
  let manageProviders: () -> Void
  let onCommit: (MacChatTarget) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var accountID: ProviderAccountID?
  @State private var activeAccountID: ProviderAccountID?
  @State private var activeModelID: ModelID?
  @State private var reasoning: ReasoningOptions?
  @State private var searchText = ""
  @State private var cachedAccounts: [ProviderAccount] = []
  @State private var cachedRows: [MacComposerModelPickerSupport.RowItem] = []
  @State private var filteredRows: [MacComposerModelPickerSupport.RowItem] = []
  @State private var showingManualEntry = false
  @State private var manualModelDraft = ""
  @State private var isRefreshing = false
  @State private var isSaving = false
  @State private var statusMessage: String?
  @State private var errorMessage: String?
  @FocusState private var searchFocused: Bool
  @FocusState private var manualFieldFocused: Bool

  init(
    providers: MacProviderModel,
    initialTarget: MacChatTarget?,
    maxOutputTokens: Int? = nil,
    manageProviders: @escaping () -> Void,
    onCommit: @escaping (MacChatTarget) async -> Bool
  ) {
    self.providers = providers
    self.initialTarget = initialTarget
    self.maxOutputTokens = maxOutputTokens
    self.manageProviders = manageProviders
    self.onCommit = onCommit

    let sortedAccounts = Self.sortedEnabledAccounts(from: providers)
    let initialAccount = initialTarget.flatMap { target in
      sortedAccounts.first { $0.id == target.accountID }
    }
    let fallbackTarget = providers.preferredTarget()
    let seedAccountID = initialAccount?.id
      ?? fallbackTarget?.accountID
      ?? sortedAccounts.first?.id
    let seedModelID: ModelID?
    if initialAccount != nil, let initialTarget {
      seedModelID = initialTarget.modelID
    } else if let seedAccountID {
      seedModelID = providers.usableModelID(for: seedAccountID)
    } else {
      seedModelID = nil
    }

    let initialRows = seedAccountID.map {
      MacComposerModelPickerSupport.makeRows(from: providers.models(for: $0))
    } ?? []
    let control: ModelReasoningControl
    if let seedAccountID, let seedModelID {
      control = providers.capabilities(accountID: seedAccountID, modelID: seedModelID).reasoning
    } else {
      control = ModelReasoningControl()
    }

    _accountID = State(initialValue: seedAccountID)
    _activeAccountID = State(initialValue: initialTarget?.accountID ?? seedAccountID)
    _activeModelID = State(initialValue: initialTarget?.modelID ?? seedModelID)
    _reasoning = State(initialValue: control.normalize(initialTarget?.reasoning))
    _cachedAccounts = State(initialValue: sortedAccounts)
    _cachedRows = State(initialValue: initialRows)
    _filteredRows = State(initialValue: initialRows)
  }

  private static func sortedEnabledAccounts(from providers: MacProviderModel) -> [ProviderAccount] {
    providers.accounts
      .filter(\.isEnabled)
      .sorted { lhs, rhs in
        let lhsReady = providers.isReady(lhs) && !providers.isProviderRestricted(lhs.id)
        let rhsReady = providers.isReady(rhs) && !providers.isProviderRestricted(rhs.id)
        if lhsReady != rhsReady { return lhsReady }
        let lhsDefault = providers.defaultAccountID == lhs.id
        let rhsDefault = providers.defaultAccountID == rhs.id
        if lhsDefault != rhsDefault { return lhsDefault }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
      }
  }

  private var selectedAccount: ProviderAccount? {
    guard let accountID else { return nil }
    return cachedAccounts.first { $0.id == accountID }
  }

  private var selectedAccountIsRestricted: Bool {
    guard let accountID else { return false }
    return providers.isProviderRestricted(accountID)
  }

  private var selectedAccountNeedsCredential: Bool {
    guard let account = selectedAccount else { return false }
    let definition = providers.provider(for: account.providerID) ?? account.definition
    return definition.requiresCredential && !providers.hasCredential(account.id)
  }

  private var canSelectFromCurrentAccount: Bool {
    selectedAccount != nil && !selectedAccountIsRestricted && !selectedAccountNeedsCredential
  }

  private var supportsModelDiscovery: Bool {
    selectedAccount?.definition.modelsPath != nil
  }

  private var trimmedQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var activeCapabilities: ResolvedModelCapabilities? {
    guard let activeAccountID, let activeModelID else { return nil }
    return providers.capabilities(accountID: activeAccountID, modelID: activeModelID)
  }

  private var activeReasoningControl: ModelReasoningControl {
    activeCapabilities?.reasoning ?? ModelReasoningControl()
  }

  private func anthropicOutputLimit(for options: ReasoningOptions?) -> Int? {
    guard let activeAccountID, providers.account(activeAccountID)?.kind == .anthropic else {
      return nil
    }
    let fallback = AnthropicMessagesAdapter.defaultMaxTokens(
      reasoning: options,
      capabilities: activeCapabilities
    )
    return maxOutputTokens ?? fallback
  }

  private var reasoningError: String? {
    activeReasoningControl.budgetValidationMessage(
      reasoning,
      outputLimit: anthropicOutputLimit(for: reasoning)
    )
  }

  private var catalogSignature: String {
    let count = accountID.map { providers.models(for: $0).count } ?? 0
    let refreshStamp = accountID.flatMap { providers.lastModelRefreshAt(for: $0)?.timeIntervalSince1970 } ?? 0
    return "\(accountID?.rawValue ?? ""):\(count):\(providers.modelCatalogRevision):\(refreshStamp)"
  }

  var body: some View {
    VStack(spacing: 0) {
      if cachedAccounts.count > 1 {
        providerStrip
        Divider()
      } else if let account = selectedAccount {
        singleProviderHeader(account)
        Divider()
      }

      searchBar

      if showingManualEntry {
        Divider()
        manualEntryBar
      }

      if let warning = accountWarningMessage {
        Divider()
        warningStrip(warning)
      }

      Divider()

      modelList

      if accountID == activeAccountID,
        !activeReasoningControl.choices.isEmpty,
        activeAccountID != nil,
        activeModelID != nil
      {
        Divider()
        reasoningFooter
      }

      Divider()

      bottomFooter
    }
    .frame(width: 392, height: 472)
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      searchFocused = true
    }
    .onChange(of: searchText) { _, newValue in
      filteredRows = MacComposerModelPickerSupport.filterRows(cachedRows, query: newValue)
    }
    .onChange(of: catalogSignature) { _, _ in
      rebuildAccountRows()
    }
  }

  private var providerStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(cachedAccounts) { account in
          let isSelected = account.id == accountID
          let ready = providers.isReady(account) && !providers.isProviderRestricted(account.id)
          MacComposerProviderChip(
            account: account,
            isSelected: isSelected,
            isReady: ready
          ) {
            selectAccount(account.id)
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    }
    .background(MacDesignTokens.Colors.surface.opacity(0.6))
  }

  private func singleProviderHeader(_ account: ProviderAccount) -> some View {
    let ready = providers.isReady(account) && !providers.isProviderRestricted(account.id)
    return HStack(spacing: 8) {
      MacProviderMark(account: account, size: 20, isReady: ready)
      Text(account.label)
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .lineLimit(1)
      Spacer(minLength: 6)
      Text(providerDisplayName(account.kind))
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(MacDesignTokens.Colors.surface.opacity(0.6))
  }

  private var searchBar: some View {
    HStack(spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        TextField("Search models…", text: $searchText)
          .textFieldStyle(.plain)
          .font(.system(size: 12.5))
          .focused($searchFocused)
          .onSubmit {
            if let firstAvailable = filteredRows.first(where: \.isAvailable) {
              selectModel(firstAvailable.id)
            }
          }
        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 12))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear search")
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(
        MacDesignTokens.Colors.surface,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.75)
      }

      if selectedAccount != nil {
        Button {
          toggleManualEntry()
        } label: {
          Image(systemName: showingManualEntry ? "xmark" : "plus")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(
              showingManualEntry ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted
            )
        }
        .buttonStyle(MacIconButtonStyle())
        .help(showingManualEntry ? "Close custom model ID" : "Enter custom model ID")
        .accessibilityLabel(showingManualEntry ? "Close custom model ID" : "Enter custom model ID")

        if supportsModelDiscovery {
          Button {
            Task { await refreshCurrentAccount() }
          } label: {
            if isRefreshing {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
          }
          .buttonStyle(MacIconButtonStyle())
          .disabled(isRefreshing || selectedAccountNeedsCredential || selectedAccountIsRestricted)
          .help("Refresh models from provider")
          .accessibilityLabel("Refresh models")
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private var manualEntryBar: some View {
    HStack(spacing: 6) {
      TextField("Exact model ID…", text: $manualModelDraft)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
        .focused($manualFieldFocused)
        .onSubmit {
          commitManualModel()
        }
      Button("Use") {
        commitManualModel()
      }
      .buttonStyle(MacActionButtonStyle(.primary, size: .small))
      .disabled(
        manualModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !canSelectFromCurrentAccount
          || isSaving
      )
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(MacDesignTokens.Colors.surface.opacity(0.45))
  }

  private var accountWarningMessage: String? {
    if selectedAccountIsRestricted {
      return "This restored connection requires BYOK Pro."
    }
    if selectedAccountNeedsCredential {
      return "Add an API key in Providers before selecting a model."
    }
    if let errorMessage {
      return errorMessage
    }
    return nil
  }

  private func warningStrip(_ message: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)
      Text(message)
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .lineLimit(2)
      Spacer(minLength: 4)
      if selectedAccountNeedsCredential || selectedAccountIsRestricted {
        Button("Providers…") {
          manageProviders()
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color.orange.opacity(0.10))
  }

  @ViewBuilder
  private var modelList: some View {
    if selectedAccount == nil {
      ContentUnavailableView {
        Label("No Enabled Providers", systemImage: "sparkles")
      } description: {
        Text("Add or enable a provider connection to pick a model.")
      } actions: {
        Button("Manage Providers…", action: manageProviders)
          .buttonStyle(MacActionButtonStyle(.primary, size: .small))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if filteredRows.isEmpty {
      ContentUnavailableView {
        Label(
          trimmedQuery.isEmpty ? "No Models" : "No Matching Models",
          systemImage: trimmedQuery.isEmpty ? "cube" : "magnifyingglass"
        )
      } description: {
        Text(
          trimmedQuery.isEmpty
            ? (supportsModelDiscovery
              ? "Refresh discovery or add a custom model ID."
              : "Add a custom model ID to continue.")
            : "No models match \"\(trimmedQuery)\"."
        )
      } actions: {
        if !trimmedQuery.isEmpty, canSelectFromCurrentAccount {
          Button("Use \"\(trimmedQuery)\"") {
            manualModelDraft = trimmedQuery
            commitManualModel()
          }
          .buttonStyle(MacActionButtonStyle(.primary, size: .small))
        } else if supportsModelDiscovery, canSelectFromCurrentAccount {
          Button("Refresh Models") {
            Task { await refreshCurrentAccount() }
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      let partitioned = MacComposerModelPickerSupport.partitionRows(
        filteredRows,
        hasQuery: !trimmedQuery.isEmpty
      )
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          if !partitioned.favorites.isEmpty {
            sectionHeader("Favorites")
            ForEach(partitioned.favorites) { row in
              modelRowView(row)
            }
            if !partitioned.others.isEmpty {
              sectionHeader("All Models")
                .padding(.top, 6)
            }
          }

          ForEach(partitioned.others) { row in
            modelRowView(row)
          }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(MacDesignTokens.Colors.textMuted)
      .tracking(0.4)
      .padding(.horizontal, 8)
      .padding(.top, 2)
      .padding(.bottom, 2)
  }

  private func modelRowView(_ row: MacComposerModelPickerSupport.RowItem) -> some View {
    let isCurrent = accountID == activeAccountID && row.id == activeModelID
    return MacComposerModelRow(
      row: row,
      isSelected: isCurrent,
      isDisabled: !row.isAvailable || !canSelectFromCurrentAccount || isSaving
    ) {
      selectModel(row.id)
    }
  }

  private var reasoningFooter: some View {
    let control = activeReasoningControl
    let currentChoice = control.choice(for: reasoning)
    let showsBudget =
      currentChoice == .budget
      || (control.combinesEffortAndBudget == true && reasoning != nil && reasoning?.enabled != false)

    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Label("Reasoning", systemImage: "brain")
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

        Spacer(minLength: 6)

        if control.choices.count <= 5 {
          HStack(spacing: 4) {
            ForEach(control.choices, id: \.self) { choice in
              MacComposerReasoningChip(
                title: choice.title,
                isSelected: currentChoice == choice
              ) {
                applyReasoningChoice(choice)
              }
            }
          }
        } else {
          Picker("Reasoning", selection: Binding(
            get: { currentChoice },
            set: { applyReasoningChoice($0) }
          )) {
            ForEach(control.choices, id: \.self) { choice in
              Text(choice.title).tag(choice)
            }
          }
          .labelsHidden()
          .controlSize(.small)
        }
      }

      if showsBudget, let budget = control.budget {
        HStack(spacing: 6) {
          Text("Budget")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)

          TextField("Tokens", value: Binding(
            get: { reasoning?.maxTokens ?? budget.defaultTokens },
            set: { value in
              var options = reasoning ?? ReasoningOptions(enabled: true)
              options.maxTokens = value
              reasoning = options
            }
          ), format: .number)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .frame(width: 90)
          .onSubmit {
            applyCurrentReasoning()
          }

          Button("Apply") {
            applyCurrentReasoning()
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          .disabled(reasoningError != nil || isSaving)

          Spacer(minLength: 0)
        }
      }

      if let reasoningError {
        Text(reasoningError)
          .font(.caption2)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(MacDesignTokens.Colors.surface.opacity(0.45))
  }

  private var bottomFooter: some View {
    HStack(spacing: 8) {
      if isSaving {
        ProgressView()
          .controlSize(.mini)
        Text("Applying…")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      } else if let statusMessage {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .lineLimit(1)
      } else {
        Text(
          trimmedQuery.isEmpty
            ? "\(cachedRows.count) \(cachedRows.count == 1 ? "model" : "models")"
            : "\(filteredRows.count) of \(cachedRows.count)"
        )
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }

      Spacer(minLength: 8)

      Button("Manage Providers…") {
        manageProviders()
      }
      .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
    }
    .padding(.horizontal, 10)
    .frame(height: 36)
    .background(MacDesignTokens.Colors.surface.opacity(0.6))
  }

  private func selectAccount(_ id: ProviderAccountID) {
    guard id != accountID else { return }
    accountID = id
    statusMessage = nil
    errorMessage = nil
    showingManualEntry = false
    rebuildAccountRows()
  }

  private func rebuildAccountRows() {
    cachedAccounts = Self.sortedEnabledAccounts(from: providers)
    guard let accountID else {
      cachedRows = []
      filteredRows = []
      return
    }
    let rows = MacComposerModelPickerSupport.makeRows(from: providers.models(for: accountID))
    cachedRows = rows
    filteredRows = MacComposerModelPickerSupport.filterRows(rows, query: searchText)
  }

  private func toggleManualEntry() {
    showingManualEntry.toggle()
    if showingManualEntry {
      manualModelDraft = filteredRows.isEmpty ? trimmedQuery : ""
      manualFieldFocused = true
    } else {
      manualModelDraft = ""
      searchFocused = true
    }
  }

  private func selectModel(_ modelID: ModelID) {
    guard let accountID, canSelectFromCurrentAccount, !isSaving else { return }
    let control = providers.capabilities(accountID: accountID, modelID: modelID).reasoning
    let normalized = control.normalize(reasoning)
    let target = MacChatTarget(
      accountID: accountID,
      modelID: modelID,
      reasoning: normalized
    )
    isSaving = true
    errorMessage = nil
    Task { @MainActor in
      defer { isSaving = false }
      if await onCommit(target) {
        activeAccountID = accountID
        activeModelID = modelID
        reasoning = normalized
        dismiss()
      } else {
        errorMessage = "Could not switch to this model."
      }
    }
  }

  private func commitManualModel() {
    let trimmed = manualModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let accountID, canSelectFromCurrentAccount, !isSaving else { return }
    let id = ModelID(rawValue: trimmed)
    let control = providers.capabilities(accountID: accountID, modelID: id).reasoning
    let normalized = control.normalize(reasoning)
    let target = MacChatTarget(accountID: accountID, modelID: id, reasoning: normalized)
    isSaving = true
    errorMessage = nil
    Task { @MainActor in
      defer { isSaving = false }
      do {
        try await providers.ensureSelectableModel(id, for: accountID)
        if await onCommit(target) {
          activeAccountID = accountID
          activeModelID = id
          reasoning = normalized
          manualModelDraft = ""
          showingManualEntry = false
          dismiss()
        } else {
          errorMessage = "Could not switch to \"\(trimmed)\"."
        }
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func applyReasoningChoice(_ choice: ReasoningChoice) {
    let updated = activeReasoningControl.options(for: choice, preserving: reasoning)
    reasoning = updated
    if choice != .budget {
      applyCurrentReasoning()
    }
  }

  private func applyCurrentReasoning() {
    guard let activeAccountID, let activeModelID, reasoningError == nil, !isSaving else { return }
    let normalized = activeReasoningControl.normalize(reasoning)
    let target = MacChatTarget(
      accountID: activeAccountID,
      modelID: activeModelID,
      reasoning: normalized
    )
    isSaving = true
    errorMessage = nil
    Task { @MainActor in
      defer { isSaving = false }
      if await onCommit(target) {
        reasoning = normalized
        statusMessage = "Reasoning updated"
      } else {
        errorMessage = "Could not update reasoning."
      }
    }
  }

  private func refreshCurrentAccount() async {
    guard let requestedAccount = accountID, !isRefreshing else { return }
    isRefreshing = true
    statusMessage = nil
    errorMessage = nil
    defer { isRefreshing = false }
    do {
      let result = try await providers.refreshModelsIfNeeded(
        accountID: requestedAccount,
        force: true
      )
      guard accountID == requestedAccount else { return }
      rebuildAccountRows()
      switch result {
      case .refreshed:
        statusMessage = "Models updated"
      case .unsupported:
        statusMessage = "Discovery not supported"
      case .current, .throttled:
        statusMessage = "Up to date"
      }
    } catch {
      guard accountID == requestedAccount else { return }
      errorMessage = error.localizedDescription
    }
  }
}

private struct MacComposerProviderChip: View {
  let account: ProviderAccount
  let isSelected: Bool
  let isReady: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        MacProviderMark(account: account, size: 16, isReady: isReady)
        Text(account.label)
          .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
          .foregroundStyle(
            isSelected ? MacDesignTokens.Colors.textPrimary : MacDesignTokens.Colors.textMuted
          )
          .lineLimit(1)
        if !isReady {
          Circle()
            .fill(Color.orange)
            .frame(width: 5, height: 5)
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 26)
      .background(
        isSelected
          ? MacDesignTokens.Colors.accentSoft
          : Color.primary.opacity(isHovered ? 0.055 : 0.025),
        in: Capsule()
      )
      .overlay {
        Capsule()
          .stroke(
            isSelected
              ? MacDesignTokens.Colors.accent.opacity(0.6)
              : MacDesignTokens.Colors.separator.opacity(0.75),
            lineWidth: 0.75
          )
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}

private struct MacComposerModelRow: View {
  let row: MacComposerModelPickerSupport.RowItem
  let isSelected: Bool
  let isDisabled: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 1.5) {
          HStack(spacing: 5) {
            Text(row.displayName)
              .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .lineLimit(1)

            if row.isFavorite {
              Image(systemName: "star.fill")
                .font(.system(size: 9))
                .foregroundStyle(MacDesignTokens.Colors.accent)
            }

            if row.isManual {
              Text("Custom")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(MacDesignTokens.Colors.accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(MacDesignTokens.Colors.accentSoft, in: Capsule())
            }
          }

          if let subtitleID = row.subtitleID {
            Text(subtitleID)
              .font(.system(size: 10.5).monospaced())
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }

        Spacer(minLength: 6)

        if row.supportsVision {
          Image(systemName: "eye")
            .font(.system(size: 10.5))
            .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.8))
            .help("Supports image input")
        }

        if isSelected {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(MacDesignTokens.Colors.accent)
        } else if !row.isAvailable {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5))
            .foregroundStyle(.orange)
        }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(rowBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .opacity(row.isAvailable ? 1 : 0.5)
    .onHover { isHovered = $0 }
  }

  private var rowBackground: Color {
    if isSelected { return MacDesignTokens.Colors.selection }
    if isHovered && !isDisabled { return Color.primary.opacity(0.05) }
    return .clear
  }
}

private struct MacComposerReasoningChip: View {
  let title: String
  let isSelected: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
        .foregroundStyle(
          isSelected ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted
        )
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
          isSelected
            ? MacDesignTokens.Colors.accentSoft
            : Color.primary.opacity(isHovered ? 0.06 : 0.03),
          in: Capsule()
        )
        .overlay {
          Capsule()
            .stroke(
              isSelected
                ? MacDesignTokens.Colors.accent.opacity(0.55)
                : MacDesignTokens.Colors.separator.opacity(0.65),
              lineWidth: 0.75
            )
        }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}

// MARK: - Target Picker View

struct MacTargetPickerView: View {
  @Bindable var providers: MacProviderModel
  let initialTarget: MacChatTarget?
  let maxOutputTokens: Int?
  let onCommit: (MacChatTarget) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var accountID: ProviderAccountID?
  @State private var modelID: ModelID?
  @State private var reasoning: ReasoningOptions?
  @State private var searchText = ""
  @State private var isSaving = false
  @State private var showingProviders = false
  @State private var showingManualModelSheet = false
  @State private var manualModelDraft = ""
  @FocusState private var isManualModelFieldFocused: Bool
  @State private var explicitlyEnteredManualIDs: Set<ModelID> = []
  @State private var removedManualModelIDs: Set<ModelID> = []
  @State private var refreshAccountID: ProviderAccountID?
  @State private var refreshMessage: String?
  @State private var commitError: String?

  init(
    providers: MacProviderModel,
    initialTarget: MacChatTarget?,
    maxOutputTokens: Int? = nil,
    onCommit: @escaping (MacChatTarget) async -> Bool
  ) {
    self.providers = providers
    self.initialTarget = initialTarget
    self.maxOutputTokens = maxOutputTokens
    self.onCommit = onCommit

    let enabledAccounts = providers.accounts.filter(\.isEnabled)
    let initialAccount = initialTarget.flatMap { target in
      enabledAccounts.first { $0.id == target.accountID }
    }
    let fallbackTarget = providers.preferredTarget()
    let seedAccountID = initialAccount?.id
      ?? fallbackTarget?.accountID
      ?? enabledAccounts.first?.id
    let seedModelID: ModelID?
    if let initialAccount, let initialTarget {
      seedModelID = initialTarget.modelID
    } else if let seedAccountID {
      seedModelID = providers.usableModelID(for: seedAccountID)
    } else {
      seedModelID = nil
    }

    _accountID = State(initialValue: seedAccountID)
    _modelID = State(initialValue: seedModelID)
    let control: ModelReasoningControl
    if let seedAccountID, let seedModelID {
      control = providers.capabilities(accountID: seedAccountID, modelID: seedModelID).reasoning
    } else {
      control = ModelReasoningControl()
    }
    _reasoning = State(initialValue: control.normalize(initialTarget?.reasoning))
  }

  private var enabledAccounts: [ProviderAccount] {
    providers.accounts
      .filter(\.isEnabled)
      .sorted { lhs, rhs in
        let lhsReady = providers.isReady(lhs) && !providers.isProviderRestricted(lhs.id)
        let rhsReady = providers.isReady(rhs) && !providers.isProviderRestricted(rhs.id)
        if lhsReady != rhsReady { return lhsReady }
        let lhsDefault = providers.defaultAccountID == lhs.id
        let rhsDefault = providers.defaultAccountID == rhs.id
        if lhsDefault != rhsDefault { return lhsDefault }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
      }
  }

  private var selectedAccount: ProviderAccount? {
    guard let accountID else { return nil }
    return providers.accounts.first { $0.id == accountID && $0.isEnabled }
  }

  private var selectedAccountIsRestricted: Bool {
    guard let accountID else { return false }
    return providers.isProviderRestricted(accountID)
  }

  private var selectedAccountNeedsCredential: Bool {
    guard let account = selectedAccount else { return false }
    let definition = providers.provider(for: account.providerID) ?? account.definition
    return definition.requiresCredential && !providers.hasCredential(account.id)
  }

  private var supportsModelDiscovery: Bool {
    selectedAccount?.definition.modelsPath != nil
  }

  private var allAccountRecords: [AccountModelRecord] {
    guard let accountID else { return [] }
    return providers.models(for: accountID).filter { !removedManualModelIDs.contains($0.model.id) }
  }

  private var filteredRecords: [AccountModelRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return allAccountRecords }
    return allAccountRecords.filter {
      $0.model.displayName.localizedCaseInsensitiveContains(query)
        || $0.model.id.rawValue.localizedCaseInsensitiveContains(query)
    }
  }

  private var selectedRecord: AccountModelRecord? {
    guard let accountID, let modelID else { return nil }
    return providers.models(for: accountID, includeHidden: true).first { $0.model.id == modelID }
  }

  private var selectedModelIsUnavailable: Bool {
    guard let modelID else { return false }
    if explicitlyEnteredManualIDs.contains(modelID) { return false }
    guard let record = selectedRecord else { return true }
    return !record.isAvailable
  }

  private var selectedAccountHasNoAvailableModels: Bool {
    guard selectedAccount != nil else { return false }
    let hasSavedAvailable = allAccountRecords.contains { $0.isAvailable }
    let hasStagedManual = modelID.map { explicitlyEnteredManualIDs.contains($0) } ?? false
    return !hasSavedAvailable && !hasStagedManual
  }

  private var resolvedCapabilities: ResolvedModelCapabilities? {
    guard let accountID, let modelID else { return nil }
    return providers.capabilities(accountID: accountID, modelID: modelID)
  }

  private var reasoningControl: ModelReasoningControl {
    resolvedCapabilities?.reasoning ?? ModelReasoningControl()
  }

  private func anthropicOutputLimit(for options: ReasoningOptions?) -> Int? {
    guard providers.account(accountID)?.kind == .anthropic else { return nil }
    let fallback = AnthropicMessagesAdapter.defaultMaxTokens(
      reasoning: options,
      capabilities: resolvedCapabilities
    )
    return maxOutputTokens ?? fallback
  }

  private var reasoningError: String? {
    reasoningControl.budgetValidationMessage(
      reasoning,
      outputLimit: anthropicOutputLimit(for: reasoning)
    )
  }

  private var canCommit: Bool {
    guard let account = selectedAccount,
      account.isEnabled,
      !selectedAccountIsRestricted,
      !selectedAccountNeedsCredential
    else { return false }
    guard modelID != nil, !selectedModelIsUnavailable else { return false }
    return !isSaving && reasoningError == nil
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

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Provider & Model")
          .font(.title3.weight(.semibold))
        Spacer()
        Button("Manage Providers…") { showingProviders = true }
          .buttonStyle(MacActionButtonStyle(.secondary))
        Button("Cancel") { dismiss() }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .disabled(isSaving)
        Button("Done") { save() }
          .buttonStyle(MacActionButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(!canCommit)
      }
      .padding(16)
      .background(MacDesignTokens.Colors.surface)

      Divider()

      HSplitView {
        accountListPane
          .frame(minWidth: 170, idealWidth: 195, maxWidth: 230)
          .background(MacDesignTokens.Colors.surface.opacity(0.45))

        VStack(spacing: 0) {
          modelToolbar

          Divider()

          if selectedAccount == nil {
            ContentUnavailableView(
              "No Enabled Providers",
              systemImage: "sparkles",
              description: Text("Add or enable an AI provider in Manage Providers.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            warningsArea

            modelListContent

            selectedModelFooter
          }
        }
        .frame(minWidth: 390)
        .background(MacDesignTokens.Colors.canvas)
      }
    }
    .frame(minWidth: 580, idealWidth: 620, minHeight: 420, idealHeight: 460)
    .background(MacDesignTokens.Colors.canvas)
    .interactiveDismissDisabled(isSaving)
    .task(id: accountID) {
      guard let accountID else { return }
      await refreshCatalog(for: accountID, force: false)
    }
    .sheet(isPresented: $showingProviders, onDismiss: repairSelection) {
      MacProviderManagementView(model: providers)
    }
    .sheet(isPresented: $showingManualModelSheet) {
      manualModelPromptSheet
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
      Text(commitError ?? "Unable to apply model selection.")
    }
    .onChange(of: reasoningControl) { _, control in
      reasoning = control.normalize(reasoning)
    }
  }

  private var accountListPane: some View {
    Group {
      if enabledAccounts.isEmpty {
        ContentUnavailableView(
          "No Providers",
          systemImage: "sparkles",
          description: Text("Add a connection to pick a model.")
        )
      } else {
        List(selection: Binding(
          get: { accountID },
          set: { value in
            guard let value else { return }
            selectAccount(value)
          }
        )) {
          ForEach(enabledAccounts) { account in
            let ready = providers.isReady(account) && !providers.isProviderRestricted(account.id)
            let warningLabel = accountStatusWarning(for: account)
            HStack(spacing: 9) {
              MacProviderMark(account: account, size: 26, isReady: ready)
              VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                  .fontWeight(.medium)
                  .lineLimit(1)
                if let warningLabel {
                  Label(warningLabel, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                } else {
                  Text(providerDisplayName(account.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
            }
            .tag(account.id)
          }
        }
        .scrollContentBackground(.hidden)
      }
    }
  }

  private var modelToolbar: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        TextField("Search models", text: $searchText)
          .textFieldStyle(.plain)
        if !searchText.isEmpty {
          Button { searchText = "" } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .buttonStyle(.plain)
        }
      }

      if selectedAccount != nil {
        Button {
          openManualModelPrompt()
        } label: {
          Label("Add Model ID", systemImage: "plus")
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        .help("Enter a custom model ID manually")

        if supportsModelDiscovery, let accountID {
          Button {
            Task { await refreshCatalog(for: accountID, force: true) }
          } label: {
            if refreshAccountID == accountID {
              ProgressView()
                .controlSize(.small)
            } else {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          .disabled(refreshAccountID == accountID || selectedAccountNeedsCredential || selectedAccountIsRestricted)
          .help("Refresh available models from provider")
        }
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 44)
    .background(MacDesignTokens.Colors.surface.opacity(0.45))
  }

  @ViewBuilder
  private var warningsArea: some View {
    if selectedAccountIsRestricted || selectedAccountNeedsCredential
      || selectedAccountHasNoAvailableModels || selectedModelIsUnavailable
    {
      VStack(alignment: .leading, spacing: 6) {
        if selectedAccountIsRestricted {
          warningBanner(
            "This restored connection requires BYOK Pro to use.",
            systemImage: "crown.fill"
          )
        }
        if selectedAccountNeedsCredential {
          HStack(spacing: 8) {
            warningBanner(
              "This connection needs an API key. Add one in Manage Providers before using it.",
              systemImage: "key.slash"
            )
            Spacer(minLength: 4)
            Button("Manage…") { showingProviders = true }
              .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          }
        }
        if selectedAccountHasNoAvailableModels {
          warningBanner(
            supportsModelDiscovery
              ? "No available models yet. Refresh models or enter an exact Model ID."
              : "No available models yet. Enter an exact Model ID to continue.",
            systemImage: "cube"
          )
        }
        if selectedModelIsUnavailable {
          warningBanner(
            selectedRecord == nil
              ? "The current model is not in your saved models. Choose another model or enter an exact Model ID."
              : "The current model is no longer reported by this provider. Choose another model or enter an exact Model ID.",
            systemImage: "exclamationmark.triangle.fill"
          )
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.orange.opacity(0.09))

      Divider()
    }
  }

  private func warningBanner(_ text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  private var modelListContent: some View {
    let showUnlistedBanner = modelID.map { id in
      !allAccountRecords.contains(where: { $0.model.id == id })
    } ?? false

    if filteredRecords.isEmpty && !showUnlistedBanner {
      ContentUnavailableView {
        Label(
          searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No Models" : "No Matching Models",
          systemImage: "cube"
        )
      } description: {
        Text(
          searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (supportsModelDiscovery
              ? "Refresh discovery or enter an exact model ID."
              : "Enter an exact model ID to add one.")
            : "Try another query or enter \"\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\" as a custom model ID."
        )
      } actions: {
        Button("Enter Model ID…", systemImage: "plus") { openManualModelPrompt() }
          .buttonStyle(MacActionButtonStyle(.primary))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List(selection: $modelID) {
        if let modelID, showUnlistedBanner {
          unlistedOrHiddenRow(for: modelID)
            .tag(modelID)
        }

        ForEach(filteredRecords) { record in
          modelRow(record)
            .tag(record.model.id)
        }
      }
      .scrollContentBackground(.hidden)
    }
  }

  private func modelRow(_ record: AccountModelRecord) -> some View {
    let kind = selectedAccount?.kind ?? .openAICompatible
    return HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          Text(record.model.displayName)
            .fontWeight(.medium)
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .lineLimit(1)
          if record.isFavorite {
            Image(systemName: "star.fill")
              .font(.caption2)
              .foregroundStyle(MacDesignTokens.Colors.accent)
          }
        }
        Text(record.model.id.rawValue)
          .font(.caption.monospaced())
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .lineLimit(1)
        MacModelCapabilityBadges(
          kind: kind,
          model: record.model,
          isManual: record.isManual,
          isHidden: record.isHidden,
          isAvailable: record.isAvailable
        )
      }
      Spacer(minLength: 6)
      if record.isManual {
        Button {
          stageManualRemoval(record.model.id)
        } label: {
          Image(systemName: "trash")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .buttonStyle(MacIconButtonStyle())
        .help("Remove custom model")
        .accessibilityLabel("Remove \(record.model.displayName)")
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        guard record.isAvailable else { return }
        modelID = record.model.id
        if canCommit {
          save()
        }
      }
    )
    .opacity(record.isAvailable ? 1 : 0.5)
    .contextMenu {
      if record.isManual {
        Button("Remove Custom Model", systemImage: "trash", role: .destructive) {
          stageManualRemoval(record.model.id)
        }
      }
    }
  }

  @ViewBuilder
  private func unlistedOrHiddenRow(for id: ModelID) -> some View {
    let kind = selectedAccount?.kind ?? .openAICompatible
    if let hiddenRecord = selectedRecord, hiddenRecord.isHidden {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(hiddenRecord.model.displayName)
            .fontWeight(.medium)
          Text(hiddenRecord.model.id.rawValue)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          MacModelCapabilityBadges(
            kind: kind,
            model: hiddenRecord.model,
            isManual: hiddenRecord.isManual,
            isHidden: true,
            isAvailable: hiddenRecord.isAvailable
          )
        }
        Spacer()
      }
      .padding(.vertical, 2)
    } else if explicitlyEnteredManualIDs.contains(id) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(id.rawValue)
              .font(.body.monospaced().weight(.medium))
            Text("Custom · Saves on Done")
              .font(.caption2.weight(.medium))
              .foregroundStyle(MacDesignTokens.Colors.accent)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(MacDesignTokens.Colors.accent.opacity(0.11), in: Capsule())
          }
          Text("Manually entered model ID")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          clearUnlistedSelection()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(MacIconButtonStyle())
        .help("Clear entered model ID")
      }
      .padding(.vertical, 2)
    } else {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(id.rawValue)
            .font(.body.monospaced())
            .foregroundStyle(.secondary)
          Text("Not in saved models")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
        }
        Spacer()
        Button {
          clearUnlistedSelection()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(MacIconButtonStyle())
        .help("Clear unavailable model")
      }
      .padding(.vertical, 2)
    }
  }

  @ViewBuilder
  private var selectedModelFooter: some View {
    if !reasoningControl.choices.isEmpty {
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        Picker("Reasoning", selection: Binding(
          get: { reasoningControl.choice(for: reasoning) },
          set: { reasoning = reasoningControl.options(for: $0, preserving: reasoning) }
        )) {
          ForEach(reasoningControl.choices, id: \.self) { choice in
            Text(choice.title).tag(choice)
          }
        }
        if reasoningControl.choice(for: reasoning) == .budget
          || (reasoningControl.combinesEffortAndBudget == true && reasoning != nil && reasoning?.enabled != false),
          let budget = reasoningControl.budget
        {
          TextField("Token budget", value: Binding(
            get: { reasoning?.maxTokens ?? budget.defaultTokens },
            set: { value in
              var options = reasoning ?? ReasoningOptions(enabled: true)
              options.maxTokens = value
              reasoning = options
            }
          ), format: .number)
          Text(budgetHint(for: budget))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(reasoningError ?? reasoningControl.label(for: reasoning))
          .font(.caption)
          .foregroundStyle(reasoningError != nil ? Color.red : .secondary)
      }
      .padding(12)
    }

    Divider()

    VStack(alignment: .leading, spacing: 6) {
      if let account = selectedAccount, let modelID {
        let model = selectedRecord?.model
          ?? ProviderModel(providerID: account.providerID, id: modelID, displayName: modelID.rawValue)
        VStack(alignment: .leading, spacing: 4) {
          Text(selectedRecord?.model.displayName ?? modelID.rawValue)
            .font(.caption.weight(.medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .lineLimit(1)
          MacModelCapabilityBadges(
            kind: account.kind,
            model: model,
            isManual: selectedRecord?.isManual ?? explicitlyEnteredManualIDs.contains(modelID),
            isHidden: selectedRecord?.isHidden ?? false,
            isAvailable: !selectedModelIsUnavailable
          )
        }
      }

      HStack(spacing: 8) {
        if let accountID {
          if supportsModelDiscovery {
            if let refreshed = providers.lastModelRefreshAt(for: accountID) {
              Text("Catalog checked \(refreshed.formatted(date: .abbreviated, time: .shortened))")
            } else {
              Text("Showing saved models; catalog has not been refreshed yet.")
            }
          } else {
            Text("This provider does not offer model discovery. Enter an exact model ID.")
          }
        }
        Spacer(minLength: 0)
      }
      .font(.caption)
      .foregroundStyle(MacDesignTokens.Colors.textMuted)

      if let refreshMessage {
        Text(refreshMessage)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !removedManualModelIDs.isEmpty {
        Text("Custom model removal will be saved when you click Done.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(MacDesignTokens.Colors.surface.opacity(0.6))
  }

  private var manualModelPromptSheet: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Enter Model ID")
        .font(.headline)
      TextField("Exact model ID", text: $manualModelDraft)
        .textFieldStyle(.roundedBorder)
        .focused($isManualModelFieldFocused)
        .onSubmit { commitManualPrompt() }
      Text("Select a model that is not yet listed by your provider. It will be saved when you click Done.")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      HStack(spacing: 8) {
        Spacer()
        Button("Cancel") {
          manualModelDraft = ""
          showingManualModelSheet = false
        }
        .buttonStyle(MacActionButtonStyle(.secondary))
        .keyboardShortcut(.cancelAction)
        Button("Use Model") { commitManualPrompt() }
          .buttonStyle(MacActionButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(manualModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      isManualModelFieldFocused = true
    }
  }

  private func accountStatusWarning(for account: ProviderAccount) -> String? {
    if providers.isProviderRestricted(account.id) { return "Pro required" }
    let definition = providers.provider(for: account.providerID) ?? account.definition
    if definition.requiresCredential && !providers.hasCredential(account.id) {
      return "Needs API key"
    }
    if !providers.models(for: account.id).contains(where: { $0.isAvailable }) {
      return "Needs model"
    }
    return nil
  }

  private func openManualModelPrompt() {
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    manualModelDraft = filteredRecords.isEmpty ? trimmed : ""
    showingManualModelSheet = true
  }

  private func commitManualPrompt() {
    let trimmed = manualModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let id = ModelID(rawValue: trimmed)
    removedManualModelIDs.remove(id)
    explicitlyEnteredManualIDs.insert(id)
    modelID = id
    manualModelDraft = ""
    showingManualModelSheet = false
  }

  private func clearUnlistedSelection() {
    if let modelID {
      explicitlyEnteredManualIDs.remove(modelID)
    }
    modelID = allAccountRecords.first(where: { $0.isAvailable })?.model.id
  }

  private func stageManualRemoval(_ id: ModelID) {
    guard let accountID else { return }
    guard providers.models(for: accountID, includeHidden: true).contains(where: {
      $0.model.id == id && $0.isManual
    }) else { return }
    explicitlyEnteredManualIDs.remove(id)
    removedManualModelIDs.insert(id)
    if modelID == id {
      modelID = allAccountRecords.first(where: { $0.isAvailable })?.model.id
    }
  }

  private func refreshCatalog(for requestedAccount: ProviderAccountID, force: Bool) async {
    guard let account = providers.accounts.first(where: { $0.id == requestedAccount && $0.isEnabled }),
      !providers.isProviderRestricted(requestedAccount)
    else { return }
    let definition = providers.provider(for: account.providerID) ?? account.definition
    guard definition.modelsPath != nil else { return }
    if !force && definition.requiresCredential && !providers.hasCredential(account.id) {
      if accountID == requestedAccount { refreshMessage = nil }
      return
    }
    refreshAccountID = requestedAccount
    if accountID == requestedAccount { refreshMessage = nil }
    defer {
      if refreshAccountID == requestedAccount { refreshAccountID = nil }
    }
    do {
      let result = try await providers.refreshModelsIfNeeded(
        accountID: requestedAccount,
        force: force
      )
      guard accountID == requestedAccount else { return }
      switch result {
      case .refreshed:
        refreshMessage = "Model list updated."
        if modelID == nil && removedManualModelIDs.isEmpty {
          modelID = providers.usableModelID(for: requestedAccount)
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

  private func repairSelection() {
    if let accountID,
      let account = providers.accounts.first(where: { $0.id == accountID && $0.isEnabled })
    {
      if modelID == nil {
        modelID = providers.usableModelID(for: account.id)
      }
      return
    }
    let seed = providers.preferredTarget()
    accountID = seed?.accountID ?? enabledAccounts.first?.id
    modelID = seed?.modelID ?? accountID.flatMap { providers.usableModelID(for: $0) }
    removedManualModelIDs.removeAll()
    explicitlyEnteredManualIDs.removeAll()
    reasoning = reasoningControl.normalize(seed?.reasoning)
  }

  private func selectAccount(_ value: ProviderAccountID) {
    guard value != accountID, let account = providers.account(value) else { return }
    accountID = value
    removedManualModelIDs.removeAll()
    explicitlyEnteredManualIDs.removeAll()
    refreshMessage = nil
    modelID = account.defaultModelID
      ?? providers.models(for: value).first(where: { $0.isAvailable })?.model.id
    reasoning = reasoningControl.normalize(reasoning)
  }

  private func save() {
    guard canCommit, let accountID, let modelID else { return }
    isSaving = true
    commitError = nil
    let normalizedReasoning = reasoningControl.normalize(reasoning)
    let removalsToApply = removedManualModelIDs.subtracting([modelID])
    let target = MacChatTarget(
      accountID: accountID,
      modelID: modelID,
      reasoning: normalizedReasoning
    )
    Task { @MainActor in
      do {
        try await providers.ensureSelectableModel(modelID, for: accountID)
        if await onCommit(target) {
          if !removalsToApply.isEmpty {
            try await providers.removeManualModels(removalsToApply, for: accountID)
          }
          dismiss()
        } else {
          isSaving = false
        }
      } catch {
        commitError = error.localizedDescription
        isSaving = false
      }
    }
  }
}

// MARK: - Connection Editor Route & View

enum MacConnectionEditorRoute: Identifiable {
  case create(ProviderKind)
  case edit(ProviderAccountID)

  var id: String {
    switch self {
    case .create(let kind): "create-\(kind.rawValue)"
    case .edit(let id): "edit-\(id.rawValue)"
    }
  }
}

nonisolated enum MacConnectionURLValidator {
  static let invalidURLMessage = "Enter a valid URL starting with https:// or http://."
  static let httpsRequiredMessage = "Use an https:// URL for this provider."
  static let privateNetworkHTTPMessage =
    "Cleartext http:// is only allowed for localhost and private LAN hosts. Use https:// for public endpoints."
  static let credentialsNotAllowedMessage =
    "Remove embedded username or password from the URL."

  /// Resolves a draft base URL string for a given `ProviderKind`.
  /// Empty input returns `nil` for custom OpenAI-compatible servers and the
  /// provider's default endpoint for built-in providers.
  static func resolvedEndpoint(for rawURL: String, kind: ProviderKind) -> URL? {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return kind == .openAICompatible ? nil : kind.defaultEndpoint
    }
    guard let parsed = URL(string: trimmed),
      let scheme = parsed.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = parsed.host, !host.isEmpty
    else { return nil }
    let normalized = kind.normalizedBaseURL(parsed)
    guard (try? ProviderHTTP.validateBaseURL(normalized, allowsLocalHTTP: kind.allowsLocalHTTP)) != nil else {
      return nil
    }
    return normalized
  }

  /// Returns an inline validation error message when a non-empty Base URL fails
  /// HTTP(S) or transport security validation.
  static func validationError(for rawURL: String, kind: ProviderKind) -> String? {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let parsed = URL(string: trimmed),
      let scheme = parsed.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = parsed.host, !host.isEmpty
    else { return invalidURLMessage }
    if parsed.user != nil || parsed.password != nil {
      return credentialsNotAllowedMessage
    }
    if scheme == "http" {
      if !kind.allowsLocalHTTP {
        return httpsRequiredMessage
      }
      if !ProviderHTTP.isPrivateNetworkHost(host) {
        return privateNetworkHTTPMessage
      }
    }
    return nil
  }
}

struct MacConnectionEditorView: View {
  private enum ConnectionTestState: Equatable {
    case idle
    case testing
    case fetchingModels
    case discovered(modelCount: Int)
    case connectedVerified(modelID: String)
    case failed(String)
  }

  private struct DiscoveryInput: Equatable {
    let kind: ProviderKind
    let endpoint: String
    let credential: String
    let clearCredential: Bool
    let headers: [String: String]
    let appTitle: String
    let referer: String
    let chatPath: String
    let modelsPath: String
    let authMode: String
    let headerName: String
  }

  @Bindable var model: MacProviderModel
  let route: MacConnectionEditorRoute
  let onFinished: (ProviderAccountID?) -> Void

  @Environment(\.dismiss) private var dismiss

  private let initialKind: ProviderKind
  private let initialDefaultModelID: ModelID?

  @State private var selectedKind: ProviderKind
  @State private var label: String
  @State private var suggestedLabel: String
  @State private var didEditLabel = false
  @State private var showingProviderPicker = false
  @State private var credential = ""
  @State private var baseURL: String
  @State private var chatPath: String
  @State private var modelsPath: String
  @State private var authMode: String
  @State private var customHeaderName: String
  @State private var additionalHeaders: [MacAdditionalHeaderItem]
  @State private var headerEditorTarget: MacAdditionalHeaderEditorTarget?
  @State private var selectedModelID: ModelID?
  @State private var manualModelID = ""
  @State private var discoveredModels: [ProviderModel]? = nil
  @State private var manualModels: [ProviderModel] = []
  @State private var removedManualModelIDs: Set<ModelID> = []
  @State private var seedModelsText: String
  @State private var appTitle: String
  @State private var httpReferer: String
  @State private var isEnabled: Bool
  @State private var isSaving = false
  @State private var saveError: String?
  @State private var isRevealing = false
  @State private var revealedStoredCredential: String?
  @State private var didCopyRevealedCredential = false
  @State private var isDraftCredentialVisible = false
  @State private var clearCredential = false
  @State private var showingAdvanced = false
  @State private var showingModelPicker = false
  @State private var showingDiscardAlert = false

  @State private var discoveryTask: Task<Void, Never>?
  @State private var discoveryID: UUID?
  @State private var isDiscoveryRunning = false
  @State private var discoveryWarning: String?
  @State private var connectionTestState: ConnectionTestState = .idle

  private var existing: ProviderAccount? {
    switch route {
    case .create: nil
    case .edit(let id): model.account(id)
    }
  }

  private var kind: ProviderKind {
    switch route {
    case .create: selectedKind
    case .edit: existing?.kind ?? .openAICompatible
    }
  }

  init(
    model: MacProviderModel,
    route: MacConnectionEditorRoute,
    onFinished: @escaping (ProviderAccountID?) -> Void
  ) {
    self.model = model
    self.route = route
    self.onFinished = onFinished

    let account: ProviderAccount?
    switch route {
    case .create:
      account = nil
    case .edit(let id):
      account = model.account(id)
    }
    let kind: ProviderKind
    switch route {
    case .create(let value): kind = value
    case .edit: kind = account?.kind ?? .openAICompatible
    }

    self.initialKind = kind
    let defaultModelSeed = account?.defaultModelID ?? (account == nil ? kind.seedModels.first?.id : nil)
    self.initialDefaultModelID = defaultModelSeed

    let initialLabel = account?.label ?? model.autoName(for: kind)
    _selectedKind = State(initialValue: kind)
    _label = State(initialValue: initialLabel)
    _suggestedLabel = State(initialValue: initialLabel)
    _didEditLabel = State(initialValue: account != nil)
    _baseURL = State(
      initialValue: account?.baseURLOverride?.absoluteString
        ?? (kind == .openAICompatible ? "" : kind.defaultEndpoint?.absoluteString ?? "")
    )
    _chatPath = State(initialValue: account?.chatCompletionsPath ?? "/chat/completions")
    _modelsPath = State(initialValue: account == nil ? "/models" : (account?.modelsPath ?? ""))
    let authentication = account?.authChoice ?? kind.authSpec.fixedAuthentication ?? .bearer
    switch authentication {
    case .bearer:
      _authMode = State(initialValue: "bearer")
      _customHeaderName = State(initialValue: "X-API-Key")
    case .header(let name):
      _authMode = State(initialValue: "header")
      _customHeaderName = State(initialValue: name)
    case .none:
      _authMode = State(initialValue: "none")
      _customHeaderName = State(initialValue: "X-API-Key")
    }
    _additionalHeaders = State(initialValue: MacAdditionalHeaderItem.items(from: account?.additionalHeaders ?? [:]))
    _selectedModelID = State(initialValue: defaultModelSeed)
    _seedModelsText = State(initialValue: (account?.seedModelIDs ?? []).joined(separator: "\n"))
    _appTitle = State(initialValue: account?.metadata["appTitle"] ?? "")
    _httpReferer = State(initialValue: account?.metadata["httpReferer"] ?? "")
    _isEnabled = State(initialValue: account?.isEnabled ?? true)
    _showingAdvanced = State(initialValue: kind == .openAICompatible || account?.baseURLOverride != nil)
  }

  private var isCreate: Bool {
    if case .create = route { return true }
    return false
  }

  private var isCustom: Bool { kind == .openAICompatible }

  private var showsCredentialField: Bool {
    effectiveAuthentication != .none
  }

  private var requiresCredential: Bool {
    showsCredentialField && kind.requiresCredential
  }

  private var hasStoredCredential: Bool {
    guard !isCreate, let accountID = existing?.id else { return false }
    return model.hasCredential(accountID)
  }

  private var trimmedCredential: String {
    credential.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var keyAvailableForDiscovery: Bool {
    if !trimmedCredential.isEmpty { return true }
    if clearCredential || (isCustom && authMode == "none") { return false }
    return hasStoredCredential
  }

  private var credentialPlaceholder: String {
    if isCreate {
      return requiresCredential ? "API Key / Token" : "API Key / Token (optional)"
    }
    return "New API Key / Token (leave blank to keep current)"
  }

  private var localServerPlaceholder: String {
    switch kind {
    case .ollama: "http://localhost:11434/v1"
    case .lmStudio: "http://localhost:1234/v1"
    default: "http://localhost:11434/v1"
    }
  }

  private var localServerHint: String {
    switch kind {
    case .ollama:
      "Use http://localhost:11434/v1 on this Mac, or your LAN IP with 'Expose Ollama to the network' enabled. /v1 is added automatically if omitted."
    case .lmStudio:
      "Use http://localhost:1234/v1 on this Mac, or your LAN IP with 'Serve on Local Network' enabled. /v1 is added automatically if omitted."
    default:
      "HTTP and HTTPS endpoints are accepted for local and LAN hosts."
    }
  }

  private var effectiveAuthentication: ProviderAuthentication {
    if !isCustom {
      return kind.authSpec.fixedAuthentication ?? .bearer
    }
    switch authMode {
    case "none": return .none
    case "header": return .header(name: customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines))
    default: return .bearer
    }
  }

  private var resolvedDraftEndpoint: URL? {
    MacConnectionURLValidator.resolvedEndpoint(for: baseURL, kind: kind)
  }

  private var baseURLValidationError: String? {
    MacConnectionURLValidator.validationError(for: baseURL, kind: kind)
  }

  private var draftDefinition: ProviderDefinition {
    if let existing, !isCustom { return existing.definition }
    let trimmedChat = chatPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedModels = modelsPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return kind.definition(
      providerID: existing?.providerID ?? kind.defaultProviderID ?? "custom",
      displayName: label.trimmingCharacters(in: .whitespacesAndNewlines),
      baseURLOverride: resolvedDraftEndpoint,
      chatPath: trimmedChat.isEmpty ? "/chat/completions" : trimmedChat,
      modelsPath: trimmedModels.isEmpty ? nil : trimmedModels,
      authentication: effectiveAuthentication,
      seedModelIDs: parseSeedModels(seedModelsText)
    )
    .withKind(kind)
  }

  private var draftMetadata: [String: String] {
    var metadata = existing?.metadata ?? [:]
    if kind == .openRouter {
      metadata.removeValue(forKey: "appTitle")
      metadata.removeValue(forKey: "httpReferer")
      let title = appTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      let referer = httpReferer.trimmingCharacters(in: .whitespacesAndNewlines)
      if !title.isEmpty { metadata["appTitle"] = title }
      if !referer.isEmpty { metadata["httpReferer"] = referer }
    }
    return metadata
  }

  private var headerValidationPolicy: HTTPHeaderValidationPolicy {
    .provider(kind: kind, authentication: effectiveAuthentication)
  }

  private var hasInvalidAdditionalHeaders: Bool {
    MacAdditionalHeaderItem.hasValidationErrors(
      in: additionalHeaders,
      policy: headerValidationPolicy
    )
  }

  private var additionalHeadersDictionary: [String: String] {
    MacAdditionalHeaderItem.dictionary(from: additionalHeaders)
  }

  private var discoveryInput: DiscoveryInput {
    DiscoveryInput(
      kind: kind,
      endpoint: baseURL,
      credential: credential,
      clearCredential: clearCredential,
      headers: additionalHeadersDictionary,
      appTitle: appTitle,
      referer: httpReferer,
      chatPath: chatPath,
      modelsPath: modelsPath,
      authMode: authMode,
      headerName: customHeaderName
    )
  }

  private var modelRecords: [AccountModelRecord] {
    let stored = existing.map { model.models(for: $0.id, includeHidden: true) } ?? []
    var records: [ModelID: AccountModelRecord] = [:]
    let catalog = discoveredModels ?? (isCreate ? kind.seedModels : [])
    for record in stored where discoveredModels == nil || record.isManual {
      records[record.model.id] = record
    }
    for value in catalog {
      if var existingRecord = stored.first(where: { $0.model.id == value.id }) {
        existingRecord.model = value.mergingCapabilities(from: existingRecord.model)
        existingRecord.isAvailable = true
        records[value.id] = existingRecord
      } else {
        records[value.id] = AccountModelRecord(accountID: existing?.id ?? "", model: value)
      }
    }
    for value in manualModels {
      if var record = records[value.id] {
        record.isAvailable = true
        record.isHidden = false
        record.isManual = true
        records[value.id] = record
      } else {
        records[value.id] = AccountModelRecord(
          accountID: existing?.id ?? "",
          model: value,
          isManual: true
        )
      }
    }
    if isCustom {
      for rawID in parseSeedModels(seedModelsText) {
        let id = ModelID(rawValue: rawID)
        guard records[id] == nil else { continue }
        records[id] = AccountModelRecord(
          accountID: existing?.id ?? "",
          model: ProviderModel(
            providerID: existing?.providerID ?? "custom",
            id: id,
            displayName: rawID
          ),
          isManual: true
        )
      }
    }
    return records.values
      .filter { $0.isAvailable && !$0.isHidden && !removedManualModelIDs.contains($0.model.id) }
      .sorted { lhs, rhs in
        if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
        return lhs.model.displayName.localizedCaseInsensitiveCompare(rhs.model.displayName)
          == .orderedAscending
      }
  }

  private var manualOnlyRecords: [AccountModelRecord] {
    let seedIDs = isCustom ? Set(parseSeedModels(seedModelsText).map(ModelID.init(rawValue:))) : []
    return modelRecords.filter { $0.isManual && !seedIDs.contains($0.model.id) }
  }

  private var selectedModelRecord: AccountModelRecord? {
    let typed = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty {
      let id = ModelID(rawValue: typed)
      return modelRecords.first { $0.model.id == id }
        ?? AccountModelRecord(
          accountID: existing?.id ?? "",
          model: ProviderModel(
            providerID: existing?.providerID ?? kind.defaultProviderID ?? "custom",
            id: id,
            displayName: typed
          ),
          isManual: true
        )
    }
    if let selectedModelID, let match = modelRecords.first(where: { $0.model.id == selectedModelID }) {
      return match
    }
    if let selectedModelID, let existing,
      let hidden = model.models(for: existing.id, includeHidden: true).first(where: {
        $0.model.id == selectedModelID
      })
    {
      return hidden
    }
    return nil
  }

  private var selectedModelTitle: String {
    let typed = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty { return typed }
    if let match = modelRecords.first(where: { $0.model.id == selectedModelID }) {
      return match.model.displayName
    }
    if let selectedModelID, let existing,
      let hidden = model.models(for: existing.id, includeHidden: true).first(where: {
        $0.model.id == selectedModelID
      })
    {
      return hidden.isHidden ? "\(hidden.model.displayName) (Hidden)" : hidden.model.displayName
    }
    return selectedModelID?.rawValue ?? "Choose model"
  }

  private var hasValidPreviewCredentialsAndEndpoint: Bool {
    guard !isDiscoveryRunning, resolvedDraftEndpoint != nil else { return false }
    guard !hasInvalidAdditionalHeaders else { return false }
    if isCustom && authMode == "header"
      && customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return false
    }
    if requiresCredential && !keyAvailableForDiscovery {
      return false
    }
    return true
  }

  private var canFetchModels: Bool {
    hasValidPreviewCredentialsAndEndpoint && draftDefinition.modelsPath != nil
  }

  private var previewTargetModelID: ModelID? {
    let typed = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty { return ModelID(rawValue: typed) }
    return selectedModelID ?? modelRecords.first?.model.id
  }

  private var canTestConnection: Bool {
    hasValidPreviewCredentialsAndEndpoint && previewTargetModelID != nil
  }

  private var hasNonEnabledUnsavedChanges: Bool {
    let typedModel = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedModelID = typedModel.isEmpty ? selectedModelID : ModelID(rawValue: typedModel)
    let manualIDs = manualModels.map { $0.id.rawValue } + (typedModel.isEmpty ? [] : [typedModel])
    let sanitizedCredential = (isCustom && authMode == "none") ? "" : trimmedCredential
    let shouldClear = (clearCredential || (isCustom && authMode == "none")) && sanitizedCredential.isEmpty
    let persistedBaseURL = isCustom ? baseURL.trimmingCharacters(in: .whitespacesAndNewlines) : normalizedBuiltInOverride
    let effectiveRemoved = removedManualModelIDs.subtracting(Set(manualIDs.map(ModelID.init(rawValue:))))

    if let existing {
      if hasInvalidAdditionalHeaders { return true }
      let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedLabel != existing.label { return true }
      let existingNormalizedOverride: String = {
        guard let url = existing.baseURLOverride else { return "" }
        if isCustom { return url.absoluteString }
        let normalized = kind.normalizedBaseURL(url).absoluteString
        return normalized == kind.defaultEndpoint?.absoluteString ? "" : normalized
      }()
      if persistedBaseURL != existingNormalizedOverride { return true }
      if additionalHeadersDictionary != existing.additionalHeaders { return true }
      if draftMetadata != existing.metadata { return true }
      if !sanitizedCredential.isEmpty || (shouldClear && hasStoredCredential) { return true }
      if resolvedModelID != existing.defaultModelID { return true }
      if discoveredModels != nil || !manualIDs.isEmpty || !effectiveRemoved.isEmpty { return true }
      if isCustom {
        let existingChat = existing.chatCompletionsPath ?? "/chat/completions"
        let trimmedChat = chatPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChat = trimmedChat.isEmpty ? "/chat/completions" : (trimmedChat.hasPrefix("/") ? trimmedChat : "/\(trimmedChat)")
        if normalizedChat != existingChat { return true }
        let trimmedModels = modelsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModels: String? = trimmedModels.isEmpty ? nil : (trimmedModels.hasPrefix("/") ? trimmedModels : "/\(trimmedModels)")
        if normalizedModels != existing.modelsPath { return true }
        if effectiveAuthentication != (existing.authChoice ?? .bearer) { return true }
        if parseSeedModels(seedModelsText) != (existing.seedModelIDs ?? []) { return true }
      }
      return false
    }

    if selectedKind != initialKind { return true }
    if didEditLabel { return true }
    if !sanitizedCredential.isEmpty { return true }
    if isCustom {
      if !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
      if authMode != "bearer" { return true }
      if chatPath.trimmingCharacters(in: .whitespacesAndNewlines) != "/chat/completions" { return true }
      if modelsPath.trimmingCharacters(in: .whitespacesAndNewlines) != "/models" { return true }
      if !parseSeedModels(seedModelsText).isEmpty { return true }
    } else {
      if !normalizedBuiltInOverride.isEmpty { return true }
    }
    if !additionalHeaders.isEmpty { return true }
    if !appTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
    if !httpReferer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
    if !manualIDs.isEmpty || discoveredModels != nil { return true }
    if resolvedModelID != initialDefaultModelID { return true }
    return false
  }

  private var hasUnsavedChanges: Bool {
    if let existing, isEnabled != existing.isEnabled { return true }
    return hasNonEnabledUnsavedChanges
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Group {
          if let existing {
            MacProviderMark(account: existing, size: 36, isReady: true)
          } else {
            MacProviderMark(kind: kind, size: 36, isReady: true)
          }
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(isCreate ? "Connect \(providerDisplayName(kind))" : "Edit Connection")
            .font(.title3.weight(.semibold))
          Text(isCreate ? "Configure the connection BYOKchat will use." : providerDisplayName(kind))
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        Spacer()
        Button("Cancel") { requestDismiss() }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
          .disabled(isSaving)
        Button(isCreate ? "Connect" : "Save") { save() }
          .buttonStyle(MacActionButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave || isSaving)
      }
      .padding(16)

      Divider()

      if let saveError {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .padding(.top, 1)
          Text(saveError)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 6)
          Button {
            self.saveError = nil
          } label: {
            Image(systemName: "xmark")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .buttonStyle(MacIconButtonStyle())
          .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.09))

        Divider()
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          editorCard("Connection", systemImage: "link") {
            VStack(alignment: .leading, spacing: 10) {
              if isCreate {
                Button {
                  showingProviderPicker = true
                } label: {
                  HStack(spacing: 10) {
                    MacProviderMark(kind: selectedKind, size: 28, isReady: true)
                    VStack(alignment: .leading, spacing: 1) {
                      Text(selectedKind.macPickerTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                      Text(selectedKind.macPickerDescription)
                        .font(.caption)
                        .foregroundStyle(MacDesignTokens.Colors.textMuted)
                    }
                    Spacer()
                    Text("Change")
                      .font(.caption.weight(.medium))
                      .foregroundStyle(MacDesignTokens.Colors.accent)
                    Image(systemName: "chevron.right")
                      .font(.caption2.weight(.semibold))
                      .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  }
                  .padding(.horizontal, 10)
                  .padding(.vertical, 8)
                }
                .buttonStyle(
                  MacCardButtonStyle(
                    cornerRadius: 8,
                    surfaceColor: MacDesignTokens.Colors.canvas.opacity(0.65)
                  )
                )
                .accessibilityLabel("Provider")
                .accessibilityValue(selectedKind.macPickerTitle)
              } else {
                LabeledContent("Provider", value: providerDisplayName(kind))
              }
              labeledField("Connection Name") {
                TextField("Connection Name", text: $label, prompt: Text("e.g. OpenAI"))
                  .textFieldStyle(.roundedBorder)
                  .onChange(of: label) { _, newValue in
                    if newValue != suggestedLabel {
                      didEditLabel = true
                    }
                  }
              }
              if !isCreate {
                Divider()
                HStack(alignment: .center, spacing: 12) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text("Enabled")
                      .font(.system(size: 13, weight: .medium))
                    Text("Disabled connections won't appear in model pickers or new chats.")
                      .font(.caption)
                      .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  }
                  Spacer()
                  Toggle("Enabled", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
              }
            }
          }

          editorCard(
            showsCredentialField && !requiresCredential ? "Authentication (Optional)" : "Authentication",
            systemImage: "key"
          ) {
            VStack(alignment: .leading, spacing: 10) {
              if isCustom {
                Picker("Authentication", selection: $authMode) {
                  Text("Bearer Token").tag("bearer")
                  Text("Custom Header").tag("header")
                  Text("None").tag("none")
                }
                if authMode == "header" {
                  labeledField("Header Name") {
                    TextField("Header Name", text: $customHeaderName, prompt: Text("e.g. X-API-Key"))
                      .textFieldStyle(.roundedBorder)
                      .font(.system(size: 13, design: .monospaced))
                  }
                }
              }

              if showsCredentialField {
                if hasStoredCredential && clearCredential {
                  HStack {
                    Text("Saved API key will be removed when you click Save.")
                      .font(.caption)
                      .foregroundStyle(MacDesignTokens.Colors.textMuted)
                    Spacer()
                    Button("Keep Saved Key") {
                      clearCredential = false
                    }
                    .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
                  }
                } else {
                  labeledField(isCreate ? "API Key / Token" : "Replace API Key / Token") {
                    HStack(spacing: 6) {
                      Group {
                        if isDraftCredentialVisible {
                          TextField(credentialPlaceholder, text: $credential)
                            .font(.system(size: 13, design: .monospaced))
                        } else {
                          SecureField(credentialPlaceholder, text: $credential)
                        }
                      }
                      .textFieldStyle(.roundedBorder)

                      Button {
                        isDraftCredentialVisible.toggle()
                      } label: {
                        Image(systemName: isDraftCredentialVisible ? "eye.slash" : "eye")
                          .foregroundStyle(MacDesignTokens.Colors.textMuted)
                      }
                      .buttonStyle(MacIconButtonStyle())
                      .help(isDraftCredentialVisible ? "Hide typed key" : "Show typed key")
                      .accessibilityLabel(isDraftCredentialVisible ? "Hide typed key" : "Show typed key")
                    }
                  }
                  if hasStoredCredential {
                    HStack(spacing: 8) {
                      Label("Credential stored in Keychain", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(MacDesignTokens.Colors.textMuted)
                      Spacer()
                      if revealedStoredCredential != nil {
                        Button("Hide Key") {
                          hideRevealedCredential()
                        }
                        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
                      } else {
                        Button(isRevealing ? "Revealing…" : "Reveal") { revealCredential() }
                          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
                          .disabled(isRevealing)
                      }
                      if !requiresCredential {
                        Button("Remove Key", role: .destructive) {
                          hideRevealedCredential()
                          clearCredential = true
                          credential = ""
                        }
                        .buttonStyle(MacActionButtonStyle(.destructive, size: .small))
                      }
                    }

                    if let revealed = revealedStoredCredential {
                      HStack(alignment: .center, spacing: 8) {
                        Text(revealed)
                          .font(.system(size: 12, design: .monospaced))
                          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                          .textSelection(.enabled)
                          .lineLimit(2)
                          .truncationMode(.middle)
                          .frame(maxWidth: .infinity, alignment: .leading)

                        Button(didCopyRevealedCredential ? "Copied" : "Copy") {
                          NSPasteboard.general.clearContents()
                          NSPasteboard.general.setString(revealed, forType: .string)
                          didCopyRevealedCredential = true
                        }
                        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
                      }
                      .padding(.horizontal, 10)
                      .padding(.vertical, 8)
                      .background(
                        MacDesignTokens.Colors.codeSurface,
                        in: RoundedRectangle(cornerRadius: 8)
                      )
                      .overlay {
                        RoundedRectangle(cornerRadius: 8)
                          .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.6)
                      }
                    }
                  } else {
                    Text(
                      requiresCredential
                        ? "Credentials are stored in Keychain."
                        : "Optional. Stored in Keychain if provided."
                    )
                    .font(.caption)
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  }
                }
              } else {
                Text("This connection does not require a credential.")
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
                if hasStoredCredential {
                  Text("Saved API key will be removed when you click Save.")
                    .font(.caption)
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                }
              }
            }
          }

          if isCustom {
            editorCard("Endpoint", systemImage: "network") {
              VStack(alignment: .leading, spacing: 10) {
                labeledField("Base URL") {
                  TextField("Base URL", text: $baseURL, prompt: Text("https://example.com/v1"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                }
                if let urlError = baseURLValidationError {
                  Label(urlError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                }
                labeledField("Chat Completions Path") {
                  TextField("Chat Completions Path", text: $chatPath, prompt: Text("/chat/completions"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                }
                labeledField("Models Path (leave blank to disable discovery)") {
                  TextField("Models Path", text: $modelsPath, prompt: Text("/models"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                }
                Text("HTTPS endpoints are accepted anywhere; cleartext HTTP is allowed for localhost and private LAN servers.")
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          } else if kind.isLocalServer {
            editorCard("Local Server", systemImage: "network") {
              VStack(alignment: .leading, spacing: 10) {
                labeledField("Server URL") {
                  TextField("Server URL", text: $baseURL, prompt: Text(localServerPlaceholder))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                }
                if let urlError = baseURLValidationError {
                  Label(urlError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text(localServerHint)
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }

          modelsAndDiscoveryCard

          if isCustom {
            editorCard("Seed Models", systemImage: "list.bullet") {
              VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $seedModelsText)
                  .font(.system(size: 12.5, design: .monospaced))
                  .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                  .scrollContentBackground(.hidden)
                  .frame(minHeight: 76)
                  .padding(6)
                  .background(
                    MacDesignTokens.Colors.codeSurface,
                    in: RoundedRectangle(cornerRadius: 8)
                  )
                  .overlay {
                    RoundedRectangle(cornerRadius: 8)
                      .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.75)
                  }
                Text("Optional model IDs, one per line. Removing a line removes that seed model on Save.")
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
            }
          } else if !kind.isLocalServer {
            DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
              VStack(spacing: 12) {
                editorCard("Endpoint Override", systemImage: "network") {
                  VStack(alignment: .leading, spacing: 8) {
                    labeledField("Base URL Override") {
                      TextField(
                        "Base URL Override",
                        text: $baseURL,
                        prompt: Text(kind.defaultEndpoint?.absoluteString ?? "https://")
                      )
                      .textFieldStyle(.roundedBorder)
                      .font(.system(size: 13, design: .monospaced))
                    }
                    if let urlError = baseURLValidationError {
                      Label(urlError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Leave unchanged to use the provider default endpoint.")
                      .font(.caption)
                      .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  }
                }
              }
              .padding(.top, 10)
            }
            .font(.headline)
          }

          editorCard("Additional Headers", systemImage: "list.bullet.rectangle") {
            MacAdditionalHeadersSection(
              headers: $additionalHeaders,
              policy: headerValidationPolicy,
              footerText: "Optional non-secret headers sent with requests. Authentication and transport headers are managed by BYOKchat.",
              editorTarget: $headerEditorTarget
            )
          }

          if kind == .openRouter {
            editorCard("OpenRouter", systemImage: "arrow.triangle.branch") {
              VStack(alignment: .leading, spacing: 10) {
                labeledField("App Title") {
                  TextField("App Title", text: $appTitle, prompt: Text("Optional X-Title header"))
                    .textFieldStyle(.roundedBorder)
                }
                labeledField("HTTP Referer") {
                  TextField("HTTP Referer", text: $httpReferer, prompt: Text("Optional HTTP-Referer URL"))
                    .textFieldStyle(.roundedBorder)
                }
              }
            }
          }

          if let existing {
            editorCard("Details", systemImage: "info.circle") {
              VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Created") {
                  Text(existing.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                }
                LabeledContent("Updated") {
                  Text(existing.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                }
              }
              .font(.callout)
            }
          }
        }
        .padding(16)
      }
    }
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.standardHeight
    )
    .background(MacDesignTokens.Colors.canvas)
    .interactiveDismissDisabled(isSaving || hasUnsavedChanges)
    .onChange(of: discoveryInput) { _, _ in invalidateDiscovery() }
    .onDisappear {
      cancelDiscovery()
      hideRevealedCredential()
    }
    .sheet(isPresented: $showingProviderPicker) {
      MacProviderKindPickerSheet(currentSelection: selectedKind) { newKind in
        switchKind(to: newKind)
      }
    }
    .sheet(isPresented: $showingModelPicker) {
      MacConnectionModelPickerSheet(
        kind: kind,
        records: modelRecords,
        selection: Binding(
          get: { selectedModelID },
          set: { newID in
            selectedModelID = newID
            manualModelID = ""
          }
        ),
        removedManualModelIDs: $removedManualModelIDs,
        onRemoveManual: stageManualRemoval
      )
    }
    .alert("Unsaved Changes", isPresented: $showingDiscardAlert) {
      Button("Discard Changes", role: .destructive) {
        dismiss()
      }
      if canSave {
        Button(isCreate ? "Connect" : "Save") {
          save()
        }
      }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text(
        canSave
          ? "You have unsaved changes to this connection. Do you want to save them before closing?"
          : "You have unsaved changes to this connection that will be lost if you close."
      )
    }
    .macAdditionalHeaderEditorSheet(
      target: $headerEditorTarget,
      headers: $additionalHeaders,
      policy: headerValidationPolicy
    )
  }

  private var modelsAndDiscoveryCard: some View {
    editorCard("Models & Verification", systemImage: "cube") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Button {
            runPreSaveConnectionTest()
          } label: {
            Label("Test Connection", systemImage: "bolt.horizontal.circle")
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          .disabled(!canTestConnection)
          .help(
            previewTargetModelID == nil
              ? "Fetch models or enter a model ID first to verify chat requests."
              : "Send a lightweight test request to verify credentials and model access."
          )

          if draftDefinition.modelsPath != nil {
            Button {
              fetchModels()
            } label: {
              HStack(spacing: 5) {
                Label("Fetch Models", systemImage: "arrow.clockwise")
                if let discoveredModels {
                  Text("(\(discoveredModels.count))")
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                }
              }
            }
            .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
            .disabled(!canFetchModels)
          }

          if isDiscoveryRunning {
            ProgressView()
              .controlSize(.small)
          }

          Spacer()
        }

        connectionTestStatusRow

        Divider()

        HStack(alignment: .center, spacing: 10) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Default Model")
              .font(.caption.weight(.semibold))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Text(selectedModelTitle)
              .font(.system(size: 13.5, weight: .medium))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .lineLimit(1)
            if let record = selectedModelRecord {
              MacModelCapabilityBadges(
                kind: kind,
                model: record.model,
                isManual: record.isManual,
                isHidden: record.isHidden,
                isAvailable: record.isAvailable
              )
            }
          }
          Spacer()
          if !modelRecords.isEmpty {
            Button("Choose Model… (\(modelRecords.count))") {
              showingModelPicker = true
            }
            .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          }
        }

        labeledField("Add or Override Model ID") {
          HStack(spacing: 8) {
            TextField("Or enter a model ID", text: $manualModelID)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: 13, design: .monospaced))
              .onSubmit { selectManualModel() }
            Button("Use Model ID") { selectManualModel() }
              .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
              .disabled(manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }

        if !manualOnlyRecords.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Custom Models")
              .font(.caption.weight(.semibold))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            ForEach(manualOnlyRecords) { record in
              HStack(spacing: 8) {
                Text(record.model.id.rawValue)
                  .font(.caption.monospaced())
                  .lineLimit(1)
                if selectedModelID == record.model.id {
                  Text("DEFAULT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MacDesignTokens.Colors.accent)
                }
                Spacer()
                Button {
                  stageManualRemoval(record.model.id)
                } label: {
                  Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                }
                .buttonStyle(MacIconButtonStyle())
                .help("Remove custom model")
                .accessibilityLabel("Remove \(record.model.id.rawValue)")
              }
              .padding(.horizontal, 9)
              .padding(.vertical, 6)
              .background(MacDesignTokens.Colors.canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            }
          }
        }

        if let warning = discoveryWarning {
          Label(warning, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  @ViewBuilder
  private var connectionTestStatusRow: some View {
    switch connectionTestState {
    case .idle:
      EmptyView()
    case .testing:
      Text("Testing connection…")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    case .fetchingModels:
      Text("Fetching models…")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    case .discovered(let count):
      let summary =
        count == 0
        ? "Discovery returned no models"
        : "Fetched \(count) \(count == 1 ? "model" : "models") — use Test Connection to verify chat access"
      Label(summary, systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .fixedSize(horizontal: false, vertical: true)
    case .connectedVerified(let verifiedModelID):
      Label("Connected — verified with \(verifiedModelID)", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
        .fixedSize(horizontal: false, vertical: true)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func switchKind(to newKind: ProviderKind) {
    guard isCreate, newKind != selectedKind else { return }
    invalidateDiscovery()
    selectedKind = newKind
    let nextSuggested = model.autoName(for: newKind)
    suggestedLabel = nextSuggested
    if !didEditLabel {
      label = nextSuggested
    }
    baseURL = newKind == .openAICompatible ? "" : (newKind.defaultEndpoint?.absoluteString ?? "")
    chatPath = "/chat/completions"
    modelsPath = "/models"
    let authentication = newKind.authSpec.fixedAuthentication ?? .bearer
    switch authentication {
    case .bearer:
      authMode = "bearer"
      customHeaderName = "X-API-Key"
    case .header(let name):
      authMode = "header"
      customHeaderName = name
    case .none:
      authMode = "none"
      customHeaderName = "X-API-Key"
    }
    credential = ""
    clearCredential = false
    hideRevealedCredential()
    isDraftCredentialVisible = false
    saveError = nil
    additionalHeaders = []
    headerEditorTarget = nil
    selectedModelID = newKind.seedModels.first?.id
    manualModelID = ""
    manualModels = []
    removedManualModelIDs = []
    seedModelsText = ""
    appTitle = ""
    httpReferer = ""
    showingAdvanced = newKind == .openAICompatible
  }

  private func selectManualModel() {
    let value = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    let id = ModelID(rawValue: value)
    removedManualModelIDs.remove(id)
    if !manualModels.contains(where: { $0.id == id }) {
      manualModels.append(
        ProviderModel(
          providerID: existing?.providerID ?? kind.defaultProviderID ?? "custom",
          id: id,
          displayName: value
        )
      )
    }
    selectedModelID = id
    manualModelID = ""
  }

  private func stageManualRemoval(_ id: ModelID) {
    let inDraft = manualModels.contains { $0.id == id }
    let inSeeds = isCustom && parseSeedModels(seedModelsText).contains(id.rawValue)
    let storedManual = existing.map { account in
      model.models(for: account.id, includeHidden: true).contains {
        $0.model.id == id && $0.isManual
      }
    } ?? false
    guard inDraft || inSeeds || storedManual else { return }

    manualModels.removeAll { $0.id == id }
    if inSeeds {
      let remaining = parseSeedModels(seedModelsText).filter { $0 != id.rawValue }
      seedModelsText = remaining.joined(separator: "\n")
    }
    if storedManual {
      removedManualModelIDs.insert(id)
    }
    if selectedModelID == id {
      selectedModelID = modelRecords.first?.model.id
    }
  }

  private func cancelDiscovery() {
    discoveryTask?.cancel()
    discoveryTask = nil
    discoveryID = nil
    isDiscoveryRunning = false
  }

  private func invalidateDiscovery() {
    cancelDiscovery()
    discoveredModels = nil
    discoveryWarning = nil
    connectionTestState = .idle
  }

  private func makePreviewResolvedAccount() throws -> (ResolvedProviderAccount, ProviderAccountID?) {
    guard let endpoint = resolvedDraftEndpoint else {
      throw ProviderError.invalidRequest("Enter a valid server URL first.")
    }
    let headers = try MacAdditionalHeaderItem.validatedDictionary(
      from: additionalHeaders,
      policy: headerValidationPolicy
    )
    let definition = draftDefinition
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let previewLabel = trimmedLabel.isEmpty
      ? (suggestedLabel.isEmpty ? "Custom" : suggestedLabel)
      : trimmedLabel
    let resolved = ResolvedProviderAccount(
      kind: kind,
      id: existing?.id ?? "",
      providerID: existing?.providerID ?? definition.id,
      label: previewLabel,
      apiKey: trimmedCredential.isEmpty ? nil : trimmedCredential,
      baseURLOverride: endpoint,
      additionalHeaders: headers,
      metadata: draftMetadata,
      chatCompletionsPath: isCustom
        ? chatPath.trimmingCharacters(in: .whitespacesAndNewlines)
        : nil,
      modelsPath: isCustom ? definition.modelsPath : nil,
      authChoice: isCustom ? definition.authentication : nil,
      seedModelIDs: isCustom ? parseSeedModels(seedModelsText) : (existing?.seedModelIDs ?? [])
    )
    let storedCredentialID = (clearCredential || (isCustom && authMode == "none")) ? nil : existing?.id
    return (resolved, storedCredentialID)
  }

  private func runPreSaveConnectionTest() {
    guard let targetModelID = previewTargetModelID else {
      let message = "Fetch models or enter a model ID first to test this connection."
      discoveryWarning = message
      connectionTestState = .failed(message)
      return
    }
    let resolved: ResolvedProviderAccount
    let storedCredentialID: ProviderAccountID?
    do {
      (resolved, storedCredentialID) = try makePreviewResolvedAccount()
    } catch {
      discoveryWarning = error.localizedDescription
      connectionTestState = .failed(error.localizedDescription)
      return
    }
    let input = discoveryInput
    let requestID = UUID()
    discoveryTask?.cancel()
    discoveryID = requestID
    isDiscoveryRunning = true
    discoveryWarning = nil
    connectionTestState = .testing
    discoveryTask = Task { @MainActor in
      defer {
        if discoveryID == requestID {
          isDiscoveryRunning = false
          discoveryTask = nil
        }
      }
      do {
        try await model.testConnectionPreview(
          for: resolved,
          modelID: targetModelID,
          storedCredentialAccountID: storedCredentialID
        )
        guard !Task.isCancelled, discoveryID == requestID, discoveryInput == input else { return }
        connectionTestState = .connectedVerified(modelID: targetModelID.rawValue)
      } catch {
        guard !Task.isCancelled, discoveryID == requestID, discoveryInput == input else { return }
        connectionTestState = .failed("Connection failed: \(error.localizedDescription)")
      }
    }
  }

  private func fetchModels() {
    let resolved: ResolvedProviderAccount
    let storedCredentialID: ProviderAccountID?
    do {
      (resolved, storedCredentialID) = try makePreviewResolvedAccount()
    } catch {
      discoveryWarning = error.localizedDescription
      connectionTestState = .failed(error.localizedDescription)
      return
    }
    let input = discoveryInput
    let requestID = UUID()
    discoveryTask?.cancel()
    discoveryID = requestID
    isDiscoveryRunning = true
    discoveryWarning = nil
    connectionTestState = .fetchingModels
    discoveryTask = Task { @MainActor in
      defer {
        if discoveryID == requestID {
          isDiscoveryRunning = false
          discoveryTask = nil
        }
      }
      do {
        let models = try await model.previewModels(
          for: resolved,
          storedCredentialAccountID: storedCredentialID
        )
        guard !Task.isCancelled, discoveryID == requestID, discoveryInput == input else { return }
        discoveredModels = models
        connectionTestState = .discovered(modelCount: models.count)
        if !modelRecords.contains(where: { $0.model.id == selectedModelID }) {
          selectedModelID = modelRecords.first?.model.id
        }
        if models.isEmpty {
          discoveryWarning = "No models returned. Enter a model ID manually to continue."
        }
      } catch {
        guard !Task.isCancelled, discoveryID == requestID, discoveryInput == input else { return }
        connectionTestState = .failed("Model discovery failed: \(error.localizedDescription)")
      }
    }
  }

  private func requestDismiss() {
    if hasUnsavedChanges {
      showingDiscardAlert = true
    } else {
      dismiss()
    }
  }

  private var canSave: Bool {
    guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard !hasInvalidAdditionalHeaders else { return false }
    if isCustom {
      guard resolvedDraftEndpoint != nil else { return false }
      if authMode == "header" && customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return false
      }
    } else {
      let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedURL.isEmpty && resolvedDraftEndpoint == nil {
        return false
      }
    }
    if isCreate && requiresCredential && trimmedCredential.isEmpty {
      return false
    }
    return true
  }

  private func save() {
    guard canSave, !isSaving else { return }
    saveError = nil
    let headers: [String: String]
    do {
      headers = try MacAdditionalHeaderItem.validatedDictionary(
        from: additionalHeaders,
        policy: headerValidationPolicy
      )
    } catch {
      saveError = error.localizedDescription
      return
    }

    let metadata = draftMetadata
    let typedModel = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedModelID = typedModel.isEmpty ? selectedModelID : ModelID(rawValue: typedModel)
    let preview = discoveredModels
    let manualIDs = manualModels.map { $0.id.rawValue } + (typedModel.isEmpty ? [] : [typedModel])
    let seedModels = parseSeedModels(seedModelsText)
    let effectiveRemoved = removedManualModelIDs.subtracting(Set(manualIDs.map(ModelID.init(rawValue:))))

    cancelDiscovery()
    hideRevealedCredential()

    if case .edit(let accountID) = route, !hasUnsavedChanges {
      onFinished(accountID)
      dismiss()
      return
    }

    isSaving = true

    Task { @MainActor in
      switch route {
      case .create:
        let id = await model.createConnection(
          kind: kind,
          label: label,
          credential: credential,
          baseURL: isCustom ? baseURL : normalizedBuiltInOverride,
          defaultModel: resolvedModelID?.rawValue ?? "",
          headers: headers,
          metadata: metadata,
          chatCompletionsPath: isCustom ? chatPath : nil,
          modelsPath: isCustom ? modelsPath : nil,
          authChoice: isCustom ? effectiveAuthentication : nil,
          seedModelIDs: isCustom && !seedModels.isEmpty ? seedModels : nil,
          discoveredModels: preview,
          manualModelIDs: manualIDs
        )
        if let id {
          onFinished(id)
          dismiss()
        } else {
          saveError = model.errorMessage ?? "Unable to create connection."
          model.errorMessage = nil
          isSaving = false
        }

      case .edit(let accountID):
        let enabledChanged = existing.map { isEnabled != $0.isEnabled } ?? false
        let otherFieldsChanged = hasNonEnabledUnsavedChanges
        var succeeded = true
        if otherFieldsChanged {
          let modelSelectionChanged =
            !typedModel.isEmpty
            || resolvedModelID != existing?.defaultModelID
            || (resolvedModelID == nil && !effectiveRemoved.isEmpty)
          succeeded = await model.updateConnection(
            accountID: accountID,
            label: label,
            newCredential: trimmedCredential.isEmpty ? nil : credential,
            clearCredential: clearCredential,
            baseURL: isCustom ? baseURL : normalizedBuiltInOverride,
            headers: headers,
            metadata: metadata,
            chatCompletionsPath: isCustom ? chatPath : nil,
            modelsPath: isCustom ? modelsPath : nil,
            authChoice: isCustom ? effectiveAuthentication : nil,
            seedModelIDs: isCustom && !seedModels.isEmpty ? seedModels : nil,
            defaultModelID: modelSelectionChanged ? resolvedModelID : nil,
            clearDefaultModel: modelSelectionChanged && resolvedModelID == nil,
            discoveredModels: preview,
            manualModelIDs: manualIDs,
            removedManualModelIDs: effectiveRemoved
          )
        }
        if succeeded, enabledChanged {
          let priorWarning = model.errorMessage
          succeeded = await model.setAccountEnabled(isEnabled, accountID: accountID)
          if succeeded, let priorWarning, !priorWarning.isEmpty, model.errorMessage == nil {
            model.errorMessage = priorWarning
          }
        }
        if succeeded {
          onFinished(accountID)
          dismiss()
        } else {
          saveError = model.errorMessage ?? "Unable to save connection."
          model.errorMessage = nil
          isSaving = false
        }
      }
    }
  }

  private var normalizedBuiltInOverride: String {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let normalized = URL(string: trimmed).map { kind.normalizedBaseURL($0).absoluteString } ?? trimmed
    guard let defaultURL = kind.defaultEndpoint?.absoluteString else { return normalized }
    return normalized == defaultURL ? "" : normalized
  }

  private func revealCredential() {
    guard let accountID = existing?.id else { return }
    isRevealing = true
    didCopyRevealedCredential = false
    Task { @MainActor in
      if let value = await model.revealCredential(accountID: accountID) {
        revealedStoredCredential = value
      } else if let error = model.errorMessage {
        saveError = error
        model.errorMessage = nil
      }
      isRevealing = false
    }
  }

  private func hideRevealedCredential() {
    revealedStoredCredential = nil
    didCopyRevealedCredential = false
  }

  private func labeledField<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      content()
    }
  }

  private func editorCard<Content: View>(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      Label(title, systemImage: systemImage)
        .font(.headline)
      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
  }
}

// MARK: - Searchable Default Model Picker Sheet

private struct MacConnectionModelPickerSheet: View {
  let kind: ProviderKind
  let records: [AccountModelRecord]
  @Binding var selection: ModelID?
  @Binding var removedManualModelIDs: Set<ModelID>
  let onRemoveManual: (ModelID) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  private var filtered: [AccountModelRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let visible = records.filter { !removedManualModelIDs.contains($0.model.id) }
    let base = query.isEmpty
      ? visible
      : visible.filter {
        $0.model.displayName.localizedCaseInsensitiveContains(query)
          || $0.model.id.rawValue.localizedCaseInsensitiveContains(query)
      }
    return base.sorted { lhs, rhs in
      if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
      return lhs.model.displayName.localizedCaseInsensitiveCompare(rhs.model.displayName)
        == .orderedAscending
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Choose Default Model")
            .font(.title3.weight(.semibold))
          Text("\(filtered.count) model\(filtered.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        Spacer()
        Button("Close") { dismiss() }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
      }
      .padding(16)

      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        TextField("Search models", text: $searchText)
          .textFieldStyle(.plain)
        if !searchText.isEmpty {
          Button { searchText = "" } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)

      Divider()

      if filtered.isEmpty {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          ContentUnavailableView(
            "No Models",
            systemImage: "cube",
            description: Text("Fetch models or enter a model ID manually.")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView.search(text: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(filtered) { record in
              modelChoiceRow(record)
            }
          }
          .padding(14)
        }
      }
    }
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.standardHeight
    )
    .background(MacDesignTokens.Colors.canvas)
  }

  private func modelChoiceRow(_ record: AccountModelRecord) -> some View {
    let isSelected = record.model.id == selection
    return HStack(spacing: 10) {
      Button {
        selection = record.model.id
        dismiss()
      } label: {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              if record.isFavorite {
                Image(systemName: "star.fill")
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.accent)
              }
              Text(record.model.displayName)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                .lineLimit(1)
              if isSelected {
                Image(systemName: "checkmark")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(MacDesignTokens.Colors.accent)
              }
            }
            Text(record.model.id.rawValue)
              .font(.caption.monospaced())
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)
            MacModelCapabilityBadges(
              kind: kind,
              model: record.model,
              isManual: record.isManual,
              isHidden: record.isHidden,
              isAvailable: record.isAvailable
            )
          }
          Spacer(minLength: 6)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if record.isManual {
        Button {
          onRemoveManual(record.model.id)
        } label: {
          Image(systemName: "trash")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .buttonStyle(MacIconButtonStyle())
        .help("Remove custom model")
        .accessibilityLabel("Remove \(record.model.displayName)")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(
          isSelected
            ? MacDesignTokens.Colors.accent.opacity(0.6)
            : MacDesignTokens.Colors.separator.opacity(0.7),
          lineWidth: isSelected ? 1 : 0.5
        )
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

private func parseSeedModels(_ text: String) -> [String] {
  var seen: Set<String> = []
  var values: [String] = []
  for component in text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ","))) {
    let value = component.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, seen.insert(value).inserted else { continue }
    values.append(value)
  }
  return values
}

func providerSymbol(_ kind: ProviderKind) -> String {
  switch kind {
  case .anthropic: "a.circle.fill"
  case .openai: "circle.hexagongrid.fill"
  case .xAI: "bolt.horizontal.circle.fill"
  case .gemini: "sparkles"
  case .deepSeek: "wave.3.right.circle.fill"
  case .zAI: "z.circle.fill"
  case .moonshot: "moon.stars.fill"
  case .minimax: "m.circle.fill"
  case .qwen: "q.circle.fill"
  case .mistral: "wind"
  case .groq: "bolt.fill"
  case .together: "circle.grid.2x2.fill"
  case .fireworks: "flame.fill"
  case .openRouter: "arrow.triangle.branch"
  case .nvidia: "memorychip.fill"
  case .ollama: "desktopcomputer"
  case .lmStudio: "laptopcomputer"
  case .openAICompatible: "server.rack"
  }
}

private func providerDisplayName(_ kind: ProviderKind) -> String {
  kind == .openAICompatible ? "OpenAI-compatible" : kind.displayName
}
