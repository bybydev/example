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

  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var editorMode: EditorMode?
  @State private var showProUpsell = false
  @State private var didAutoPresentSetup = false

  /// Which editor presentation is active. Create mode is distinguished from a
  /// repair deep-link (prefilled kind + focused field).
  enum EditorMode: Identifiable {
    case create(kind: ProviderKind?, focus: ConnectionEditorView.FocusRequest?)
    case edit(accountID: ProviderAccountID)

    var id: String {
      switch self {
      case .create(let kind, let focus):
        "create-\(kind.map { $0.rawValue } ?? "any")-\(focus.map { "\($0)" } ?? "none")"
      case .edit(let id): "edit-\(id.rawValue)"
      }
    }
  }

  init(model: ProviderManagementModel, onConnectionReady: (() -> Void)? = nil) {
    self.model = model
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
    .navigationTitle("Providers")
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
    .sheet(item: $editorMode) { mode in
      NavigationStack {
        switch mode {
        case .create(let kind, let focus):
          ConnectionEditorView(
            model: model,
            existing: nil,
            initialKind: kind,
            focus: focus,
            onFinished: finishConnectionSetup
          )
        case .edit(let accountID):
          ConnectionEditorView(
            model: model,
            existing: model.accounts.first { $0.id == accountID },
            initialKind: nil,
            focus: nil,
            onFinished: nil
          )
        }
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
      .listRowBackground(theme.surfaceColor)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .refreshable { await model.load() }
  }

  @ViewBuilder
  private func connectionLink(_ account: ProviderAccount) -> some View {
    Button {
      editorMode = .edit(accountID: account.id)
    } label: {
      ProviderRow(model: model, account: account)
    }
    .buttonStyle(.plain)
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
      editorMode == nil
    else { return }
    didAutoPresentSetup = true
    addConnection()
  }

  private func finishConnectionSetup() {
    guard onConnectionReady != nil else { return }
    editorMode = nil
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
      editorMode = .create(kind: nil, focus: nil)
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
        Text(rowTitle)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(theme.primaryForegroundColor)
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
      Circle()
        .fill(status.isReady ? theme.accentColor : Color.secondary)
        .frame(width: 7, height: 7)
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }
}
