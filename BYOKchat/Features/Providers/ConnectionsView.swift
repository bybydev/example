import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct ConnectionsView: View {
  @Bindable var model: ProviderManagementModel
  /// Non-nil means this screen was opened to repair/setup a chat rather than
  /// as the persistent Settings manager. The legacy callback is intentionally
  /// retained for source compatibility; successful setup now returns directly
  /// to the presenting chat instead of opening another surface.
  let onConnectionReady: (() -> Void)?

  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var showAddConnection = false
  @State private var showProUpsell = false
  @State private var didAutoPresentSetup = false

  init(model: ProviderManagementModel, onConnectionReady: (() -> Void)? = nil) {
    self.model = model
    self.onConnectionReady = onConnectionReady
  }

  var body: some View {
    Group {
      if model.accounts.isEmpty {
        emptyState
      } else {
        accountList
      }
    }
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Connections")
    .toolbar {
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
      autoPresentSetupIfNeeded()
    }
    .onChange(of: model.accounts.count) { _, _ in
      autoPresentSetupIfNeeded()
    }
    .sheet(isPresented: $showAddConnection) {
      NavigationStack {
        ConnectionFlowView(
          model: model,
          completionTitle: onConnectionReady == nil ? "Done" : "Start Chatting",
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

  private var accountList: some View {
    List {
      if let defaultID = model.defaultAccountID,
        let account = model.accounts.first(where: { $0.id == defaultID })
      {
        Section("Default") {
          connectionLink(account)
        }
      }

      let remaining = model.accounts.filter { $0.id != model.defaultAccountID }
      if !remaining.isEmpty {
        Section(model.defaultAccountID == nil ? "Connections" : "Other Connections") {
          ForEach(remaining) { account in
            connectionLink(account)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .refreshable { await model.load() }
  }

  @ViewBuilder
  private func connectionLink(_ account: ProviderAccount) -> some View {
    NavigationLink {
      ConnectionDetailView(model: model, accountID: account.id)
    } label: {
      ConnectionRow(model: model, account: account)
    }
    .listRowBackground(theme.surfaceColor)
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
      !didAutoPresentSetup,
      !showAddConnection
    else { return }
    didAutoPresentSetup = true
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

private struct ConnectionRow: View {
  let model: ProviderManagementModel
  let account: ProviderAccount

  @Environment(\.appFoundationTheme) private var theme

  private var provider: ProviderDefinition? {
    model.provider(for: account.providerID)
  }

  private var status: ConnectionStatus {
    connectionStatus(model: model, account: account)
  }

  var body: some View {
    HStack(spacing: 14) {
      ConnectionProviderMark(definition: provider, size: 44)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(account.label)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(theme.primaryForegroundColor)
          if model.isDefaultAccount(account.id) {
            Text("Default")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(theme.accentColor)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(theme.accentColor.opacity(0.12), in: Capsule())
          }
        }
        HStack(spacing: 5) {
          Text(provider?.displayName ?? account.providerID.rawValue)
          if let modelID = account.defaultModelID {
            Text("·")
            Text(modelDisplayName(model: model, accountID: account.id, modelID: modelID))
              .lineLimit(1)
          }
        }
        .font(.caption)
        .foregroundStyle(theme.secondaryForegroundColor)
      }
      Spacer(minLength: 8)
      HStack(spacing: 6) {
        Circle()
          .fill(status.isReady ? theme.accentColor : Color.secondary)
          .frame(width: 7, height: 7)
        Text(status.label)
          .font(.caption.weight(.medium))
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }
}
