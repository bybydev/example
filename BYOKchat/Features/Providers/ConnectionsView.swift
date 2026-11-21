import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// Inset-grouped provider list: one row per account. Active accounts appear
/// first with the default account pinned at the top; disabled accounts are
/// grouped into a separate section when present.
struct ProvidersView: View {
  @Bindable var model: ProviderManagementModel
  /// Non-nil means this screen was opened to repair/setup a chat rather than
  /// as the persistent Settings manager; completing setup returns to the chat.
  let onConnectionReady: (() -> Void)?
  /// Set when providers is a top-level sidebar destination. Other call sites
  /// present this view inside a navigation stack and keep the system back or
  /// sheet dismissal path instead.
  let openSidebar: (() -> Void)?

  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var showAddConnection = false
  @State private var showProUpsell = false
  @State private var didHandleInitialSetup = false
  @State private var isVisible = false
  @State private var hasLoaded = false
  @State private var pendingDelete: ProviderAccount?

  init(
    model: ProviderManagementModel,
    openSidebar: (() -> Void)? = nil,
    onConnectionReady: (() -> Void)? = nil
  ) {
    self.model = model
    self.openSidebar = openSidebar
    self.onConnectionReady = onConnectionReady
  }

  var body: some View {
    Group {
      if model.accounts.isEmpty {
        if model.isBusy || (!hasLoaded && model.definitions.isEmpty) {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Loading AI providers")
        } else {
          emptyState
        }
      } else {
        managerList
      }
    }
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("AI Providers")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if let openSidebar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Open Sidebar", systemImage: "text.alignleft", action: openSidebar)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Open sidebar")
        }
      } else if onConnectionReady != nil {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Add Connection", systemImage: "plus") {
          addConnection()
        }
        .disabled(model.isBusy)
      }
    }
    .task {
      if model.definitions.isEmpty {
        await model.load()
      }
      hasLoaded = true
      // Automatic setup is for an initially empty list, not deleting the last
      // account while an existing connection editor is being popped.
      if !model.accounts.isEmpty { didHandleInitialSetup = true }
      autoPresentSetupIfNeeded()
    }
    .onChange(of: model.accounts.count) { _, _ in
      autoPresentSetupIfNeeded()
    }
    .sheet(isPresented: $showAddConnection) {
      NavigationStack {
        ConnectionEditorView(
          model: model,
          onFinished: finishConnectionSetup
        )
      }
      .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showProUpsell) {
      BYOKProUpsellFlow(feature: .providerAccounts)
    }
    .onAppear { isVisible = true }
    .onDisappear { isVisible = false }
    .alert(
      "Connection Error",
      isPresented: Binding(
        get: { isVisible && !showAddConnection && model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
    .confirmationDialog(
      deleteConfirmationTitle,
      isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Connection", role: .destructive) {
        guard let account = pendingDelete else { return }
        pendingDelete = nil
        Task { @MainActor in
          await model.deleteAccount(account.id)
        }
      }
      Button("Cancel", role: .cancel) { pendingDelete = nil }
    } message: {
      Text(
        "This removes the saved connection settings and API key from Keychain. Your existing chats will not be deleted."
      )
    }
  }

  private var enabledAccounts: [ProviderAccount] {
    model.accounts.filter(\.isEnabled)
  }

  private var disabledAccounts: [ProviderAccount] {
    model.accounts.filter { !$0.isEnabled }
  }

  private var deleteConfirmationTitle: String {
    guard let account = pendingDelete else { return "Delete this connection?" }
    return "Delete \"\(ProviderRow.displayTitle(for: account, in: model))\"?"
  }

  private var managerList: some View {
    List {
      if !enabledAccounts.isEmpty {
        Section {
          ForEach(enabledAccounts) { account in
            connectionLink(account)
          }
          .listRowSeparatorTint(theme.borderColor)
        } header: {
          if !disabledAccounts.isEmpty {
            Text("Active")
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        } footer: {
          if enabledAccounts.count > 1 {
            Text(
              "The default connection is used for new chats. Swipe right on a connection to make it the default."
            )
            .foregroundStyle(theme.secondaryForegroundColor)
          }
        }
        .listRowBackground(theme.surfaceColor)
      }

      if !disabledAccounts.isEmpty {
        Section {
          ForEach(disabledAccounts) { account in
            connectionLink(account)
          }
          .listRowSeparatorTint(theme.borderColor)
        } header: {
          Text("Disabled")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .disabled(model.isBusy)
    .refreshable { await model.load() }
  }

  @ViewBuilder
  private func connectionLink(_ account: ProviderAccount) -> some View {
    let canMakeDefault =
      model.accounts.count > 1
      && !model.isDefaultAccount(account.id)
      && model.isReady(account)
    let canRefreshModels =
      account.isEnabled
      && model.isReady(account)
      && (model.provider(for: account.providerID)?.modelsPath ?? account.definition.modelsPath)
        != nil
    NavigationLink {
      ConnectionEditorView(
        model: model,
        existing: account,
        onFinished: onConnectionReady == nil ? nil : { finishEditSetup(accountID: account.id) }
      )
    } label: {
      ProviderRow(
        model: model,
        account: account,
        showsDefaultBadge: model.accounts.count > 1 && model.isDefaultAccount(account.id)
      )
    }
    .accessibilityHint("Edit connection.")
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      if canMakeDefault {
        Button("Default", systemImage: "star.fill") {
          Task { @MainActor in
            _ = await model.setDefaultAccount(account.id)
          }
        }
        .tint(theme.accentColor)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button("Delete", systemImage: "trash", role: .destructive) {
        pendingDelete = account
      }
    }
    .contextMenu {
      if canMakeDefault {
        Button("Set as Default", systemImage: "star") {
          Task { @MainActor in
            _ = await model.setDefaultAccount(account.id)
          }
        }
      }
      if canRefreshModels {
        Button("Refresh Models", systemImage: "arrow.clockwise") {
          Task { @MainActor in
            _ = await model.refreshModelsResult(accountID: account.id)
          }
        }
      }
      Button(
        account.isEnabled ? "Disable" : "Enable",
        systemImage: account.isEnabled ? "pause.circle" : "play.circle"
      ) {
        let nextEnabled = !account.isEnabled
        Task { @MainActor in
          _ = await model.setAccountEnabled(nextEnabled, accountID: account.id)
        }
      }
      Divider()
      Button("Delete Connection", systemImage: "trash", role: .destructive) {
        pendingDelete = account
      }
    }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("Connect your AI", systemImage: "link")
    } description: {
      Text("Add a connection to use your own AI provider and API key in BYOKchat.")
    } actions: {
      Button("Add Connection", action: addConnection)
        .buttonStyle(.borderedProminent)
    }
  }

  private func autoPresentSetupIfNeeded() {
    guard onConnectionReady != nil,
      model.accounts.isEmpty,
      !didHandleInitialSetup,
      !showAddConnection
    else { return }
    didHandleInitialSetup = true
    addConnection()
  }

  private func finishEditSetup(accountID: ProviderAccountID) {
    guard onConnectionReady != nil else { return }
    if let updated = model.accounts.first(where: { $0.id == accountID }),
      model.isReady(updated)
    {
      finishConnectionSetup()
    }
  }

  private func finishConnectionSetup() {
    guard let onConnectionReady else { return }
    showAddConnection = false
    onConnectionReady()
    Task { @MainActor in
      await Task.yield()
      dismiss()
    }
  }

  private func addConnection() {
    if BYOKProAccess.canCreateProviderAccount(
      currentCount: model.accounts.count,
      hasPro: purchaseManager.hasPro
    ) {
      showAddConnection = true
    } else {
      showProUpsell = true
    }
  }
}

/// One row per account: logo, provider-derived label, default model or the
/// reason it is not ready, status dot, and optional default badge.
private struct ProviderRow: View {
  let model: ProviderManagementModel
  let account: ProviderAccount
  let showsDefaultBadge: Bool

  @Environment(\.appFoundationTheme) private var theme

  private var provider: ProviderDefinition? {
    model.provider(for: account.providerID)
  }

  private var providerName: String {
    provider?.displayName ?? account.providerID.rawValue
  }

  private var status: ConnectionStatus {
    connectionStatus(model: model, account: account)
  }

  private var rowTitle: String {
    Self.displayTitle(for: account, in: model)
  }

  static func displayTitle(for account: ProviderAccount, in model: ProviderManagementModel) -> String {
    let providerName = model.provider(for: account.providerID)?.displayName ?? account.providerID.rawValue
    // A user label matching the provider name (or the legacy "Personal"
    // default when it is the only account for that provider) presents as the
    // provider itself.
    let isLegacySinglePersonal =
      account.label == "Personal" && model.accounts(for: account.providerID).count == 1
    if account.label == providerName || isLegacySinglePersonal {
      return providerName
    }
    return account.label
  }

  private var statusDotColor: Color {
    if status.isReady { return .green }
    return account.isEnabled ? .orange : theme.secondaryForegroundColor.opacity(0.6)
  }

  private var subtitleColor: Color {
    if !status.isReady && account.isEnabled {
      return .orange
    }
    return theme.secondaryForegroundColor
  }

  private var providerContextPrefix: String? {
    if account.kind == .openAICompatible {
      let host = (account.baseURLOverride ?? provider?.defaultBaseURL)?.host
      if let host, !host.isEmpty, host.localizedCaseInsensitiveCompare(rowTitle) != .orderedSame {
        return host
      }
      return nil
    }
    if rowTitle != providerName {
      return providerName
    }
    return nil
  }

  private var subtitleText: String {
    let detail: String
    if status.isReady, let modelName = activeVisibleModelName {
      detail = modelName
    } else {
      detail = status.label
    }
    guard let prefix = providerContextPrefix else {
      return detail
    }
    return "\(prefix) · \(detail)"
  }

  private var activeVisibleModelName: String? {
    let visible = model.models(for: account.id).filter(\.isAvailable)
    if let defaultID = account.defaultModelID,
      let match = visible.first(where: { $0.model.id == defaultID })
    {
      return match.model.displayName
    }
    return visible.first?.model.displayName
  }

  var body: some View {
    HStack(spacing: 12) {
      ConnectionProviderMark(definition: provider, size: 38)
        .opacity(account.isEnabled ? 1 : 0.55)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(rowTitle)
            .font(.body.weight(.semibold))
            .foregroundStyle(
              account.isEnabled ? theme.primaryForegroundColor : theme.secondaryForegroundColor
            )
            .lineLimit(1)
          Circle()
            .fill(statusDotColor)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
          if showsDefaultBadge {
            Text("Default")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(theme.accentColor)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(theme.accentColor.opacity(0.14), in: Capsule())
              .fixedSize()
          }
        }
        Text(subtitleText)
          .font(.caption)
          .foregroundStyle(subtitleColor)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityValue(status.isReady ? "Ready" : "")
  }
}
