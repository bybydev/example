import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// Flat provider list: one row per account, no sections. Built-ins and custom
/// providers interleave alphabetically by provider then label.
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
        emptyState
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
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Add Connection", systemImage: "plus") {
          addConnection()
        }
      }
    }
    .task {
      if model.definitions.isEmpty {
        await model.load()
      }
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
    .alert(
      "Connection Error",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "Unknown error")
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
    .refreshable { await model.load() }
  }

  @ViewBuilder
  private func connectionLink(_ account: ProviderAccount) -> some View {
    NavigationLink {
      ConnectionEditorView(model: model, existing: account)
    } label: {
      ProviderRow(model: model, account: account)
    }
    .accessibilityHint("Edit connection.")
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

  private func finishConnectionSetup() {
    guard onConnectionReady != nil else { return }
    showAddConnection = false
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
/// reason it is not ready, status dot. The label is the provider name unless
/// the user renamed the account or a second account needs disambiguating.
private struct ProviderRow: View {
  let model: ProviderManagementModel
  let account: ProviderAccount

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
    // default) presents as the provider itself.
    if account.label == providerName || account.label == "Personal" {
      return providerName
    }
    return account.label
  }

  var body: some View {
    HStack(spacing: 14) {
      ConnectionProviderMark(definition: provider, size: 44)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(rowTitle)
            .font(.body.weight(.semibold))
            .foregroundStyle(theme.primaryForegroundColor)
            .lineLimit(1)
          Circle()
            .fill(status.isReady ? theme.accentColor : Color.secondary)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
        }
        HStack(spacing: 5) {
          if status.isReady, let modelID = account.defaultModelID {
            Text(modelDisplayName(model: model, accountID: account.id, modelID: modelID))
              .lineLimit(1)
          } else {
            Text(status.label)
          }
        }
        .font(.caption)
        .foregroundStyle(theme.secondaryForegroundColor)
      }
      Spacer(minLength: 8)
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityValue(status.isReady ? "Ready" : "")
  }
}
