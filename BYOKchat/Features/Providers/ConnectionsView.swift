import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// Flat provider list: one row per account, no sections. The default account
/// is pinned first; remaining built-in and custom connections interleave
/// alphabetically by display name then label.
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
      "Delete this connection?",
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

  private var managerList: some View {
    List {
      ForEach(model.accounts) { account in
        connectionLink(account)
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
      .listRowSeparatorTint(theme.borderColor)
    }
    .listStyle(.plain)
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

  private var status: ConnectionStatus {
    connectionStatus(model: model, account: account)
  }

  private var rowTitle: String {
    let providerName = provider?.displayName ?? account.providerID.rawValue
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
    if status.isReady { return theme.accentColor }
    return account.isEnabled ? .orange : Color.secondary
  }

  private var subtitleColor: Color {
    if !status.isReady && account.isEnabled {
      return .orange
    }
    return theme.secondaryForegroundColor
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
    HStack(spacing: 14) {
      ConnectionProviderMark(definition: provider, size: 44)
        .opacity(account.isEnabled ? 1 : 0.55)
      VStack(alignment: .leading, spacing: 4) {
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
        HStack(spacing: 5) {
          if status.isReady, let modelName = activeVisibleModelName {
            Text(modelName)
              .lineLimit(1)
          } else {
            Text(status.label)
          }
        }
        .font(.caption)
        .foregroundStyle(subtitleColor)
      }
      Spacer(minLength: 8)
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityValue(status.isReady ? "Ready" : "")
  }
}
