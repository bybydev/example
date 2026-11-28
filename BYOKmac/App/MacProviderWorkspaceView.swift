import BYOKchatProviderCore
import Foundation
import SwiftUI

enum MacProviderDetailTab: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case models = "Models"
  case connection = "Connection"

  var id: String { rawValue }
}

enum MacProviderPresentationState: String, Equatable {
  case ready = "Ready"
  case disabled = "Disabled"
  case credentialRequired = "Credential required"
  case modelRequired = "Model required"
}

nonisolated struct MacActiveDisabledPartition<Element> {
  let active: [Element]
  let disabled: [Element]

  var showsSectionHeaders: Bool {
    !disabled.isEmpty
  }

  init(_ elements: [Element], isEnabled: (Element) -> Bool) {
    var activeItems: [Element] = []
    var disabledItems: [Element] = []
    for element in elements {
      if isEnabled(element) {
        activeItems.append(element)
      } else {
        disabledItems.append(element)
      }
    }
    self.active = activeItems
    self.disabled = disabledItems
  }
}

extension MacActiveDisabledPartition: Equatable where Element: Equatable {}
extension MacActiveDisabledPartition: Sendable where Element: Sendable {}

@MainActor
func macProviderPresentationState(
  model: MacProviderModel,
  account: ProviderAccount
) -> MacProviderPresentationState {
  guard account.isEnabled else { return .disabled }
  if account.definition.requiresCredential, !model.hasCredential(account.id) {
    return .credentialRequired
  }
  guard model.models(for: account.id).contains(where: { $0.isAvailable }) else {
    return .modelRequired
  }
  return .ready
}

private enum MacProviderWorkspaceRoute: Equatable {
  case list
  case detail(ProviderAccountID)
  case pickProvider
  case supportedProviders
  case editor(MacConnectionEditorRoute, returnTo: EditorReturnDestination)

  enum EditorReturnDestination: Equatable {
    case list
    case detail(ProviderAccountID)
    case pickProvider
    case supportedProviders
  }
}

struct MacProviderManagementView: View {
  @Bindable var model: MacProviderModel
  let showsCloseButton: Bool

  @Environment(\.dismiss) private var dismiss
  @Environment(\.macToastCenter) private var toastCenter
  @State private var route: MacProviderWorkspaceRoute = .list
  @State private var searchText = ""
  @State private var deleteAccount: ProviderAccount?
  @State private var testingAccountID: ProviderAccountID?
  @State private var refreshingAccountID: ProviderAccountID?
  @State private var testResultAccountID: ProviderAccountID?
  @State private var testSucceeded: Bool?

  init(model: MacProviderModel, showsCloseButton: Bool = true) {
    self.model = model
    self.showsCloseButton = showsCloseButton
  }

  private var visibleAccounts: [ProviderAccount] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return model.accounts }
    return model.accounts.filter { account in
      account.label.localizedCaseInsensitiveContains(query)
        || providerTypeName(account).localizedCaseInsensitiveContains(query)
        || defaultModelSummary(account).localizedCaseInsensitiveContains(query)
        || endpointSummary(account).localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsCloseButton {
        HStack(spacing: 10) {
          Image(systemName: "sparkles")
            .foregroundStyle(MacDesignTokens.Colors.accent)
          Text("AI Providers")
            .font(.headline)
          Spacer()
          if route == .list {
            MacSheetCloseButton(accessibilityLabel: "Close AI Providers") {
              dismiss()
            }
          } else {
            Button {
              dismiss()
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(MacSheetCloseButtonStyle())
            .help("Close")
            .accessibilityLabel("Close AI Providers")
          }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(MacDesignTokens.Colors.surface)

        Divider()
      }

      Group {
        switch route {
        case .list:
          providersHome
        case .detail(let accountID):
          if let account = model.account(accountID) {
            MacProviderWorkspaceDetailView(
              model: model,
              account: account,
              back: { route = .list },
              edit: {
                route = .editor(.edit(account.id), returnTo: .detail(account.id))
              },
              requestDelete: { deleteAccount = account }
            )
            .id(account.id.rawValue)
          } else {
            providersHome
          }
        case .pickProvider:
          MacProviderKindPickerSheet(
            presentation: .embedded(backTitle: "AI Providers", onBack: { route = .list })
          ) { kind in
            route = .editor(.create(kind), returnTo: .pickProvider)
          }
        case .supportedProviders:
          MacSupportedProvidersCatalogView(
            model: model,
            backTitle: "AI Providers",
            onBack: { route = .list }
          ) { kind in
            route = .editor(.create(kind), returnTo: .supportedProviders)
          }
        case .editor(let editorRoute, let returnTo):
          MacConnectionEditorView(
            model: model,
            route: editorRoute,
            backTitle: editorBackTitle(for: returnTo),
            onCancel: {
              route = routeFor(returnTo)
            },
            onFinished: { accountID in
              if let accountID {
                route = .detail(accountID)
              } else {
                route = routeFor(returnTo)
              }
            }
          )
          .id(editorRoute.id)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(
      minWidth: showsCloseButton ? MacDesignTokens.Sheet.workspaceMinWidth : nil,
      idealWidth: showsCloseButton ? MacDesignTokens.Sheet.workspaceIdealWidth : nil,
      maxWidth: .infinity,
      minHeight: showsCloseButton ? MacDesignTokens.Sheet.workspaceMinHeight : nil,
      idealHeight: showsCloseButton ? MacDesignTokens.Sheet.workspaceIdealHeight : nil,
      maxHeight: .infinity
    )
    .background(MacDesignTokens.Colors.canvas)
    .onChange(of: model.accounts.map(\.id)) { _, ids in
      switch route {
      case .detail(let accountID) where !ids.contains(accountID):
        route = .list
      case .editor(.edit(let accountID), _) where !ids.contains(accountID):
        route = .list
      default:
        break
      }
    }
    .confirmationDialog(
      deleteAccount.map { "Delete \"\($0.label)\"?" } ?? "Delete connection?",
      isPresented: Binding(
        get: { deleteAccount != nil },
        set: { if !$0 { deleteAccount = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Connection", role: .destructive) {
        guard let account = deleteAccount else { return }
        let label = account.label
        deleteAccount = nil
        Task { @MainActor in
          await model.deleteConnection(account.id)
          if model.errorMessage == nil {
            toastCenter?.success("Deleted \(label)")
          }
          if case .detail(let id) = route, id == account.id {
            route = .list
          }
        }
      }
      Button("Cancel", role: .cancel) { deleteAccount = nil }
    }
    .alert(
      "Provider Error",
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

  private func routeFor(
    _ destination: MacProviderWorkspaceRoute.EditorReturnDestination
  ) -> MacProviderWorkspaceRoute {
    switch destination {
    case .list:
      .list
    case .detail(let accountID):
      model.account(accountID) != nil ? .detail(accountID) : .list
    case .pickProvider:
      .pickProvider
    case .supportedProviders:
      .supportedProviders
    }
  }

  private func editorBackTitle(
    for destination: MacProviderWorkspaceRoute.EditorReturnDestination
  ) -> String {
    switch destination {
    case .list:
      "AI Providers"
    case .detail(let accountID):
      model.account(accountID)?.label ?? "AI Providers"
    case .pickProvider:
      "Providers"
    case .supportedProviders:
      "Supported"
    }
  }

  @ViewBuilder
  private var providersHome: some View {
    if model.accounts.isEmpty {
      ContentUnavailableView {
        Label("No AI Providers", systemImage: "sparkles")
      } description: {
        Text("Connect an AI provider to choose models and start chatting.")
      } actions: {
        Button("Add AI Provider", systemImage: "plus") { beginAddProvider() }
          .buttonStyle(MacActionButtonStyle(.primary))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          MacProviderSearchField(placeholder: "Search providers", text: $searchText)
            .frame(maxWidth: 360)
          Spacer()
          Button("Add AI Provider", systemImage: "plus") { beginAddProvider() }
            .buttonStyle(MacActionButtonStyle(.primary))
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(MacDesignTokens.Colors.surface.opacity(0.45))

        Divider()

        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if showsFreeLimitBanner {
              freeLimitBanner
            }

            if visibleAccounts.isEmpty {
              ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
              let partition = MacActiveDisabledPartition(visibleAccounts, isEnabled: \.isEnabled)

              if !partition.active.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                  if partition.showsSectionHeaders {
                    providerSectionHeader("Active", count: partition.active.count)
                  }
                  providerRowsGroup(partition.active)
                }
              }

              if !partition.disabled.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                  providerSectionHeader("Disabled", count: partition.disabled.count)
                  providerRowsGroup(partition.disabled)
                }
              }
            }
          }
          .padding(16)
        }
      }
    }
  }

  private func providerSectionHeader(_ title: String, count: Int) -> some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      Text("\(count)")
        .font(.caption2.weight(.medium))
        .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.8))
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(MacDesignTokens.Colors.surface, in: Capsule())
    }
    .accessibilityAddTraits(.isHeader)
  }

  private var showsFreeLimitBanner: Bool {
    MacProAccess.providerAccountCapacityDecision(currentCount: model.accounts.count) == .requiresPro
  }

  private var freeLimitBanner: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: "crown.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .frame(width: 32, height: 32)
        .background(MacDesignTokens.Colors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text("Free includes 1 connection")
          .font(.system(size: 13.5, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        Text("Upgrade to BYOK Pro to add unlimited cloud, local, and custom providers.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }

      Spacer(minLength: 12)

      HStack(spacing: 8) {
        Button("Supported Providers") {
          route = .supportedProviders
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))

        Button("Upgrade") {
          MacProAccess.requestUpgrade(.providerAccounts)
        }
        .buttonStyle(MacActionButtonStyle(.primary, size: .small))
      }
    }
    .padding(13)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
  }

  private func providerRowsGroup(_ accounts: [ProviderAccount]) -> some View {
    MacProviderInsetGroup {
      ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
        if index > 0 {
          Rectangle()
            .fill(MacDesignTokens.Colors.separator.opacity(0.65))
            .frame(height: 0.5)
            .padding(.leading, 55)
        }
        providerRow(account)
      }
    }
  }

  private func providerRow(_ account: ProviderAccount) -> some View {
    let state = macProviderPresentationState(model: model, account: account)
    let visibleRecords = model.models(for: account.id)
    let availableCount = visibleRecords.filter(\.isAvailable).count
    let hiddenCount = model.models(for: account.id, includeHidden: true).count - visibleRecords.count
    let isDefault = model.defaultAccountID == account.id && state == .ready
    let isTesting = testingAccountID == account.id
    let rowTestResult: Bool? = testResultAccountID == account.id ? testSucceeded : nil
    let typeName = providerTypeName(account)
    let customTypeSubtitle: String? =
      account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        .caseInsensitiveCompare(typeName) == .orderedSame
      ? nil
      : typeName
    let countText: String? =
      (availableCount > 0 || hiddenCount > 0)
      ? modelCountSummary(available: availableCount, hidden: hiddenCount)
      : nil

    return MacProviderAccountRow(
      account: account,
      typeSubtitle: customTypeSubtitle,
      state: state,
      isDefault: isDefault,
      defaultModelName: defaultModelSummary(account),
      hasDefaultModel: account.defaultModelID != nil,
      modelCountText: countText,
      isTesting: isTesting,
      isBusy: model.isBusy,
      testResult: rowTestResult,
      onOpen: { route = .detail(account.id) },
      onTest: { testConnection(account) },
      menuItems: {
        providerCardMenuItems(for: account, state: state, isDefault: isDefault)
      }
    )
    .contextMenu {
      providerCardMenuItems(for: account, state: state, isDefault: isDefault)
    }
  }

  private func modelCountSummary(available: Int, hidden: Int) -> String {
    let base = "\(available) model\(available == 1 ? "" : "s")"
    guard hidden > 0 else { return base }
    return "\(base) · \(hidden) hidden"
  }

  private func canRefreshModels(_ account: ProviderAccount, state: MacProviderPresentationState) -> Bool {
    guard state == .ready || state == .modelRequired else {
      return false
    }
    let modelsPath = model.provider(for: account.providerID)?.modelsPath ?? account.definition.modelsPath
    return modelsPath != nil
  }

  @ViewBuilder
  private func providerCardMenuItems(
    for account: ProviderAccount,
    state: MacProviderPresentationState,
    isDefault: Bool
  ) -> some View {
    Button("Manage", systemImage: "arrow.right.circle") { route = .detail(account.id) }
    Button("Edit Connection…", systemImage: "pencil") {
      route = .editor(.edit(account.id), returnTo: .list)
    }
    if !isDefault && state == .ready {
      Button("Make Default", systemImage: "checkmark.circle") {
        Task {
          if await model.setDefaultAccount(account.id) {
            toastCenter?.success("Default connection set to \(account.label)")
          }
        }
      }
    }
    if canRefreshModels(account, state: state) {
      Button(
        refreshingAccountID == account.id ? "Refreshing Models…" : "Refresh Models",
        systemImage: "arrow.clockwise"
      ) {
        refreshModels(account)
      }
      .disabled(model.isBusy || refreshingAccountID == account.id)
    }
    Button(
      account.isEnabled ? "Disable" : "Enable",
      systemImage: account.isEnabled ? "pause.circle" : "play.circle"
    ) {
      let nextEnabled = !account.isEnabled
      Task {
        if await model.setAccountEnabled(nextEnabled, accountID: account.id) {
          toastCenter?.success("\(account.label) \(nextEnabled ? "enabled" : "disabled")")
        }
      }
    }
    Divider()
    Button("Delete Connection…", systemImage: "trash", role: .destructive) {
      deleteAccount = account
    }
  }

  private func refreshModels(_ account: ProviderAccount) {
    guard refreshingAccountID == nil else { return }
    refreshingAccountID = account.id
    Task { @MainActor in
      defer { refreshingAccountID = nil }
      if await model.refreshModels(accountID: account.id) {
        let count = model.models(for: account.id).filter(\.isAvailable).count
        toastCenter?.success("Refreshed \(count) model\(count == 1 ? "" : "s") for \(account.label)")
      }
    }
  }

  private func beginAddProvider() {
    guard MacProAccess.requireProviderAccountCapacity(currentCount: model.accounts.count) else { return }
    route = .pickProvider
  }

  private func testConnection(_ account: ProviderAccount) {
    guard testingAccountID == nil else { return }
    testingAccountID = account.id
    testResultAccountID = nil
    testSucceeded = nil
    let targetModelID = account.defaultModelID
      ?? model.models(for: account.id).first(where: { $0.isAvailable })?.model.id
    Task { @MainActor in
      let succeeded = await model.testConnection(accountID: account.id, modelID: targetModelID)
      testResultAccountID = account.id
      testSucceeded = succeeded
      testingAccountID = nil
    }
  }

  private func providerTypeName(_ account: ProviderAccount) -> String {
    account.kind == .openAICompatible ? "OpenAI-compatible" : account.kind.displayName
  }

  private func defaultModelSummary(_ account: ProviderAccount) -> String {
    guard let modelID = account.defaultModelID else { return "No default model" }
    return model.models(for: account.id, includeHidden: true)
      .first(where: { $0.model.id == modelID })?.model.displayName ?? modelID.rawValue
  }

  private func endpointSummary(_ account: ProviderAccount) -> String {
    account.baseURLOverride?.absoluteString ?? account.kind.defaultEndpoint?.absoluteString ?? ""
  }
}

private struct MacProviderWorkspaceDetailView: View {
  @Bindable var model: MacProviderModel
  let account: ProviderAccount
  let back: () -> Void
  let edit: () -> Void
  let requestDelete: () -> Void

  @Environment(\.macToastCenter) private var toastCenter
  @State private var tab: MacProviderDetailTab = .overview
  @State private var isTesting = false
  @State private var isRefreshing = false
  @State private var testResult: Bool?

  private var state: MacProviderPresentationState {
    macProviderPresentationState(model: model, account: account)
  }

  private var canRefreshModels: Bool {
    guard state == .ready || state == .modelRequired else {
      return false
    }
    return (model.provider(for: account.providerID)?.modelsPath ?? account.definition.modelsPath) != nil
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Button(action: back) {
          Label("AI Providers", systemImage: "chevron.left")
            .foregroundStyle(MacDesignTokens.Colors.accent)
        }
        .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
        .keyboardShortcut(.cancelAction)
        Divider().frame(height: 24)
        MacProviderMark(account: account, size: 40, isReady: state == .ready)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text(account.label).font(.title3.weight(.semibold)).lineLimit(1)
            if model.defaultAccountID == account.id && state == .ready {
              Text("DEFAULT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(MacDesignTokens.Colors.accent)
            }
          }
          Text("\(providerTypeName) · \(state.rawValue)")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        Spacer()
        Button(isTesting ? "Testing…" : "Test Connection", systemImage: "bolt.horizontal.circle") {
          testConnection()
        }
        .buttonStyle(MacActionButtonStyle(.secondary))
        .disabled(isTesting || state != .ready || model.isBusy)
        Button("Edit", systemImage: "pencil", action: edit)
          .buttonStyle(MacActionButtonStyle(.secondary))
        Menu {
          if model.defaultAccountID != account.id && state == .ready {
            Button("Make Default", systemImage: "checkmark.circle") {
              Task {
                if await model.setDefaultAccount(account.id) {
                  toastCenter?.success("Default connection set to \(account.label)")
                }
              }
            }
          }
          if canRefreshModels {
            Button(
              isRefreshing ? "Refreshing Models…" : "Refresh Models",
              systemImage: "arrow.clockwise"
            ) {
              refreshModels()
            }
            .disabled(model.isBusy || isRefreshing)
          }
          Button(
            account.isEnabled ? "Disable" : "Enable",
            systemImage: account.isEnabled ? "pause.circle" : "play.circle"
          ) {
            let nextEnabled = !account.isEnabled
            Task {
              if await model.setAccountEnabled(nextEnabled, accountID: account.id) {
                toastCenter?.success("\(account.label) \(nextEnabled ? "enabled" : "disabled")")
              }
            }
          }
          Divider()
          Button("Delete Connection…", systemImage: "trash", role: .destructive, action: requestDelete)
        } label: {
          MacIconMenuLabel(systemImage: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
      .padding(.horizontal, 18)
      .frame(height: 70)
      .background(MacDesignTokens.Colors.surface.opacity(0.45))

      Divider()

      MacSegmentedControl(
        options: MacProviderDetailTab.allCases,
        selection: $tab,
        title: \.rawValue
      )
      .padding(.horizontal, 18)
      .padding(.vertical, 12)

      Group {
        switch tab {
        case .overview:
          MacProviderOverviewView(
            model: model,
            account: account,
            testResult: testResult,
            showModels: { tab = .models },
            showConnection: { tab = .connection }
          )
        case .models:
          MacProviderModelsWorkspaceView(model: model, account: account)
        case .connection:
          MacProviderConnectionWorkspaceView(
            model: model,
            account: account,
            edit: edit,
            requestDelete: requestDelete,
            isTesting: $isTesting,
            testResult: $testResult
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private var providerTypeName: String {
    account.kind == .openAICompatible ? "OpenAI-compatible" : account.kind.displayName
  }

  private func refreshModels() {
    guard !isRefreshing else { return }
    isRefreshing = true
    Task { @MainActor in
      defer { isRefreshing = false }
      if await model.refreshModels(accountID: account.id) {
        let count = model.models(for: account.id).filter(\.isAvailable).count
        toastCenter?.success("Refreshed \(count) model\(count == 1 ? "" : "s")")
      }
    }
  }

  private func testConnection() {
    guard !isTesting else { return }
    isTesting = true
    testResult = nil
    let targetModelID = account.defaultModelID
      ?? model.models(for: account.id).first(where: { $0.isAvailable })?.model.id
    Task { @MainActor in
      testResult = await model.testConnection(accountID: account.id, modelID: targetModelID)
      isTesting = false
    }
  }
}

private struct MacProviderOverviewView: View {
  @Bindable var model: MacProviderModel
  let account: ProviderAccount
  let testResult: Bool?
  let showModels: () -> Void
  let showConnection: () -> Void

  @Environment(\.macToastCenter) private var toastCenter

  private var records: [AccountModelRecord] {
    model.models(for: account.id, includeHidden: true)
  }

  private var state: MacProviderPresentationState {
    macProviderPresentationState(model: model, account: account)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        MacProviderSectionCard(title: "Status", systemImage: "checkmark.circle") {
          VStack(alignment: .leading, spacing: 9) {
            MacProviderStateLabel(state: state)
            MacProviderValueRow(title: "Connection", value: account.isEnabled ? "Enabled" : "Disabled")
            MacProviderValueRow(title: "Credential", value: credentialSummary)
            if let testResult {
              MacProviderValueRow(title: "Last Test", value: testResult ? "Connection succeeded" : "Connection failed")
            }
          }
        }

        MacProviderSectionCard(title: "Default", systemImage: "checkmark.seal") {
          VStack(alignment: .leading, spacing: 9) {
            MacProviderValueRow(
              title: "Default Connection",
              value: (model.defaultAccountID == account.id && state == .ready) ? "Yes" : "No"
            )
            MacProviderValueRow(title: "Default Model", value: defaultModelLabel)
            if model.defaultAccountID != account.id && state == .ready {
              HStack(spacing: 8) {
                Spacer()
                Button("Make Default") {
                  Task {
                    if await model.setDefaultAccount(account.id) {
                      toastCenter?.success("Default connection set to \(account.label)")
                    }
                  }
                }
                .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
              }
            }
          }
        }

        MacProviderSectionCard(title: "Models", systemImage: "cube") {
          VStack(alignment: .leading, spacing: 9) {
            MacProviderValueRow(title: "Available", value: records.filter(\.isAvailable).count.formatted())
            MacProviderValueRow(title: "Favorites", value: records.filter(\.isFavorite).count.formatted())
            MacProviderValueRow(title: "Hidden", value: records.filter(\.isHidden).count.formatted())
            if account.definition.modelsPath != nil {
              MacProviderValueRow(
                title: "Last Refreshed",
                value: model.lastModelRefreshAt(for: account.id)?
                  .formatted(date: .abbreviated, time: .shortened) ?? "Not refreshed yet"
              )
            }
            HStack {
              Spacer()
              Button("View Models", action: showModels)
                .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
            }
          }
        }

        MacProviderSectionCard(title: "Connection", systemImage: "network") {
          VStack(alignment: .leading, spacing: 9) {
            MacProviderValueRow(title: "Endpoint", value: endpoint)
            MacProviderValueRow(title: "Authentication", value: authenticationSummary)
            MacProviderValueRow(
              title: "Custom Headers",
              value: account.additionalHeaders.isEmpty ? "None" : "\(account.additionalHeaders.count) configured"
            )
            HStack {
              Spacer()
              Button("View Connection", action: showConnection)
                .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
            }
          }
        }
      }
      .padding(18)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
  }

  private var credentialSummary: String {
    if account.definition.authentication == .none { return "Not required" }
    if model.hasCredential(account.id) { return "Stored in Keychain" }
    return account.definition.requiresCredential ? "Missing" : "Optional (not set)"
  }

  private var defaultModelLabel: String {
    guard let id = account.defaultModelID else { return "Not set" }
    return records.first(where: { $0.model.id == id })?.model.displayName ?? id.rawValue
  }

  private var endpoint: String {
    account.baseURLOverride?.absoluteString ?? account.kind.defaultEndpoint?.absoluteString ?? "Not configured"
  }

  private var authenticationSummary: String {
    let authentication = account.authChoice ?? account.definition.authentication
    switch authentication {
    case .none: return "None"
    case .bearer: return "Bearer Token"
    case .header(let name): return "Custom Header · \(name)"
    }
  }
}

private struct MacProviderModelsWorkspaceView: View {
  @Bindable var model: MacProviderModel
  let account: ProviderAccount

  @Environment(\.macToastCenter) private var toastCenter
  @State private var searchText = ""
  @State private var showHidden = false
  @State private var showingAddModel = false
  @State private var isRefreshing = false

  private var state: MacProviderPresentationState {
    macProviderPresentationState(model: model, account: account)
  }

  private var canRefreshModels: Bool {
    state == .ready || state == .modelRequired
  }

  private var records: [AccountModelRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.models(for: account.id, includeHidden: true).filter { record in
      (showHidden || !record.isHidden)
        && (query.isEmpty
          || record.model.displayName.localizedCaseInsensitiveContains(query)
          || record.model.id.rawValue.localizedCaseInsensitiveContains(query))
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        MacProviderSearchField(placeholder: "Search models", text: $searchText)
          .frame(maxWidth: 360)
        Toggle("Show Hidden", isOn: $showHidden).toggleStyle(.checkbox)
        Spacer()
        if account.definition.modelsPath != nil {
          if let refreshedAt = model.lastModelRefreshAt(for: account.id) {
            Text("Checked \(refreshedAt.formatted(date: .abbreviated, time: .shortened))")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)
          }
          Button {
            refreshModels()
          } label: {
            if isRefreshing {
              HStack(spacing: 6) {
                ProgressView()
                  .controlSize(.small)
                Text("Refreshing…")
              }
            } else {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
          }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .disabled(isRefreshing || model.isBusy || !canRefreshModels)
        }
        Button("Add Model", systemImage: "plus") { showingAddModel = true }
          .buttonStyle(MacActionButtonStyle(.primary))
          .popover(isPresented: $showingAddModel, arrowEdge: .bottom) {
            MacProviderAddModelSheet { modelID in
              Task {
                if await model.addManualModel(modelID, accountID: account.id) {
                  toastCenter?.success("Added \(modelID)")
                }
              }
            }
          }
      }
      .padding(.horizontal, 16)
      .frame(height: 54)
      .background(MacDesignTokens.Colors.surface.opacity(0.35))

      Divider()

      if records.isEmpty {
        ContentUnavailableView(
          searchText.isEmpty ? "No Models" : "No Matching Models",
          systemImage: "cube",
          description: Text(searchText.isEmpty
            ? "Refresh discovery or add a model ID manually."
            : "Try a different search or show hidden models.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(records) { record in modelRow(record) }
          }
          .padding(16)
        }
      }
    }
  }

  private func refreshModels() {
    guard !isRefreshing else { return }
    isRefreshing = true
    Task { @MainActor in
      defer { isRefreshing = false }
      if await model.refreshModels(accountID: account.id) {
        let count = model.models(for: account.id).filter(\.isAvailable).count
        toastCenter?.success("Refreshed \(count) model\(count == 1 ? "" : "s")")
      }
    }
  }

  private func modelRow(_ record: AccountModelRecord) -> some View {
    HStack(spacing: 12) {
      Button {
        Task { await model.setFavorite(!record.isFavorite, modelID: record.model.id, accountID: account.id) }
      } label: {
        Image(systemName: record.isFavorite ? "star.fill" : "star")
      }
      .buttonStyle(MacIconButtonStyle())
      .foregroundStyle(record.isFavorite ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(record.model.displayName)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          if account.defaultModelID == record.model.id {
            Text("DEFAULT").font(.caption2.weight(.semibold)).foregroundStyle(MacDesignTokens.Colors.accent)
          }
        }
        Text("\(record.model.id.rawValue) · \(record.isAvailable ? "Available" : "Unavailable")")
          .font(.caption.monospaced())
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        MacModelCapabilityBadges(
          kind: account.kind,
          model: record.model,
          isManual: record.isManual,
          isHidden: record.isHidden,
          isAvailable: record.isAvailable
        )
      }
      .opacity(record.isAvailable ? 1 : 0.55)

      Spacer()

      if account.defaultModelID != record.model.id && record.isAvailable && !record.isHidden {
        Button("Make Default") {
          Task {
            if await model.setDefaultModel(record.model.id, accountID: account.id) {
              toastCenter?.success("Default model set to \(record.model.displayName)")
            }
          }
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
      }

      if record.isManual {
        Button {
          Task {
            if await model.removeManualModel(record.model.id, accountID: account.id) {
              toastCenter?.success("Removed \(record.model.displayName)")
            }
          }
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(MacIconButtonStyle())
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .help("Remove custom model")
        .accessibilityLabel("Remove \(record.model.displayName)")
      }

      Button {
        Task { await model.setHidden(!record.isHidden, modelID: record.model.id, accountID: account.id) }
      } label: {
        Image(systemName: record.isHidden ? "eye.slash.fill" : "eye")
      }
      .buttonStyle(MacIconButtonStyle())
      .foregroundStyle(MacDesignTokens.Colors.textMuted)
      .help(record.isHidden ? "Show model" : "Hide model")
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 11)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.72), lineWidth: 0.5)
    }
    .contextMenu {
      if record.isManual {
        Button("Remove Custom Model", systemImage: "trash", role: .destructive) {
          Task {
            if await model.removeManualModel(record.model.id, accountID: account.id) {
              toastCenter?.success("Removed \(record.model.displayName)")
            }
          }
        }
      }
    }
  }
}

private struct MacProviderConnectionWorkspaceView: View {
  @Bindable var model: MacProviderModel
  let account: ProviderAccount
  let edit: () -> Void
  let requestDelete: () -> Void
  @Binding var isTesting: Bool
  @Binding var testResult: Bool?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        MacProviderSectionCard(title: "Endpoint", systemImage: "network") {
          VStack(alignment: .leading, spacing: 9) {
            MacProviderValueRow(title: "Base URL", value: endpoint)
            if account.kind == .openAICompatible {
              MacProviderValueRow(title: "Chat Endpoint", value: account.chatCompletionsPath ?? "/chat/completions")
              MacProviderValueRow(title: "Models Endpoint", value: account.modelsPath ?? "Discovery disabled")
            } else {
              Text(account.baseURLOverride == nil ? "Using the provider default endpoint." : "Using a custom endpoint override.")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            HStack {
              Spacer()
              Button("Edit", action: edit)
                .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
            }
          }
        }

        MacProviderSectionCard(title: "Authentication", systemImage: "key") {
          VStack(alignment: .leading, spacing: 9) {
            MacProviderValueRow(title: "Method", value: authenticationSummary)
            MacProviderValueRow(title: "Credential", value: credentialSummary)
            Text("Stored credentials remain in Keychain and are never shown on this summary screen.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            HStack {
              Spacer()
              Button("Edit", action: edit)
                .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
            }
          }
        }

        MacProviderSectionCard(title: "Custom Headers", systemImage: "list.bullet.rectangle") {
          VStack(alignment: .leading, spacing: 8) {
            if account.additionalHeaders.isEmpty {
              Text("No custom headers").foregroundStyle(MacDesignTokens.Colors.textMuted)
            } else {
              ForEach(account.additionalHeaders.keys.sorted(), id: \.self) { key in
                MacProviderValueRow(
                  title: key,
                  value: account.additionalHeaders[key] ?? ""
                )
              }
            }
            HStack {
              Spacer()
              Button("Edit", action: edit)
                .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
            }
          }
        }

        if account.kind == .openRouter {
          MacProviderSectionCard(title: "OpenRouter", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 9) {
              MacProviderValueRow(title: "App Title", value: account.metadata["appTitle"] ?? "Not set")
              MacProviderValueRow(title: "HTTP Referer", value: account.metadata["httpReferer"] ?? "Not set")
              HStack {
                Spacer()
                Button("Edit", action: edit)
                  .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
              }
            }
          }
        }

        MacProviderSectionCard(title: "Connection Test", systemImage: "bolt.horizontal.circle") {
          HStack {
            if let testResult {
              Label(
                testResult ? "Connection succeeded" : "Connection failed",
                systemImage: testResult ? "checkmark.circle" : "exclamationmark.triangle"
              )
              .foregroundStyle(testResult ? MacDesignTokens.Colors.textMuted : Color.orange)
            } else {
              Text("Verify this connection using its default or first available model.")
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            Spacer()
            Button(isTesting ? "Testing…" : "Test Connection") { testConnection() }
              .buttonStyle(MacActionButtonStyle(.secondary))
              .disabled(isTesting || macProviderPresentationState(model: model, account: account) != .ready)
          }
        }

        Divider().padding(.vertical, 4)

        VStack(alignment: .leading, spacing: 10) {
          Text("Danger Zone").font(.headline)
          Text("Deleting this connection removes its provider configuration and stored credential.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Button("Delete Connection…", role: .destructive, action: requestDelete)
            .buttonStyle(MacActionButtonStyle(.destructive))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.25), lineWidth: 0.5)
        }
      }
      .padding(18)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
  }

  private var endpoint: String {
    account.baseURLOverride?.absoluteString ?? account.kind.defaultEndpoint?.absoluteString ?? "Not configured"
  }

  private var credentialSummary: String {
    if account.definition.authentication == .none { return "Not required" }
    if model.hasCredential(account.id) { return "Stored in Keychain" }
    return account.definition.requiresCredential ? "Missing" : "Optional (not set)"
  }

  private var authenticationSummary: String {
    let authentication = account.authChoice ?? account.definition.authentication
    switch authentication {
    case .none: return "None"
    case .bearer: return "Bearer Token"
    case .header(let name): return "Custom Header · \(name)"
    }
  }

  private func testConnection() {
    guard !isTesting else { return }
    isTesting = true
    testResult = nil
    let targetModelID = account.defaultModelID
      ?? model.models(for: account.id).first(where: { $0.isAvailable })?.model.id
    Task { @MainActor in
      testResult = await model.testConnection(accountID: account.id, modelID: targetModelID)
      isTesting = false
    }
  }
}

struct MacProviderKindPickerSheet: View {
  enum Presentation {
    case sheet
    case popover
    case embedded(backTitle: String, onBack: () -> Void)
  }

  var currentSelection: ProviderKind? = nil
  var presentation: Presentation = .sheet
  let selected: (ProviderKind) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  private var filteredCloud: [ProviderKind] {
    ProviderKind.cloudCatalog.filter { $0.matchesMacProviderSearch(searchText) }
  }

  private var filteredLocalAndCustom: [ProviderKind] {
    ProviderKind.localAndCustomCatalog.filter { $0.matchesMacProviderSearch(searchText) }
  }

  private var isPopover: Bool {
    if case .popover = presentation { return true }
    return false
  }

  private var isEmbedded: Bool {
    if case .embedded = presentation { return true }
    return false
  }

  var body: some View {
    VStack(spacing: 0) {
      switch presentation {
      case .embedded(let backTitle, let onBack):
        HStack(spacing: 12) {
          Button(action: onBack) {
            Label(backTitle, systemImage: "chevron.left")
              .foregroundStyle(MacDesignTokens.Colors.accent)
          }
          .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
          .keyboardShortcut(.cancelAction)
          Divider().frame(height: 24)
          VStack(alignment: .leading, spacing: 2) {
            Text(currentSelection == nil ? "Add AI Provider" : "Choose AI Provider")
              .font(.headline)
            Text("Choose a cloud, local, or OpenAI-compatible service.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          Spacer()
          MacProviderSearchField(placeholder: "Search providers", text: $searchText)
            .frame(maxWidth: 260)
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .background(MacDesignTokens.Colors.surface.opacity(0.45))

      case .popover:
        VStack(alignment: .leading, spacing: 10) {
          Text(currentSelection == nil ? "Add AI Provider" : "Choose AI Provider")
            .font(.headline)
          MacProviderSearchField(placeholder: "Search providers", text: $searchText)
        }
        .padding(14)

      case .sheet:
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(currentSelection == nil ? "Add AI Provider" : "Choose AI Provider")
              .font(.title3.weight(.semibold))
            Text("Choose a cloud, local, or OpenAI-compatible service.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          Spacer()
          MacSheetCloseButton(accessibilityLabel: "Close Provider Picker") {
            dismiss()
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)

        MacProviderSearchField(placeholder: "Search providers", text: $searchText)
          .padding(.horizontal, 18)
          .padding(.bottom, 12)
      }

      Divider()

      if filteredCloud.isEmpty && filteredLocalAndCustom.isEmpty {
        ContentUnavailableView.search(text: searchText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if !filteredCloud.isEmpty {
              providerGroup(title: "Cloud Providers", kinds: filteredCloud)
            }
            if !filteredLocalAndCustom.isEmpty {
              providerGroup(title: "Local & Custom", kinds: filteredLocalAndCustom)
            }
          }
          .padding(isPopover ? 14 : 18)
        }
      }
    }
    .frame(
      width: isEmbedded ? nil : (isPopover ? 440 : MacDesignTokens.Sheet.standardWidth),
      height: isEmbedded ? nil : (isPopover ? 380 : MacDesignTokens.Sheet.standardHeight)
    )
    .frame(maxWidth: isEmbedded ? .infinity : nil, maxHeight: isEmbedded ? .infinity : nil)
    .background(MacDesignTokens.Colors.canvas)
  }

  private func providerGroup(title: String, kinds: [ProviderKind]) -> some View {
    let columns = isPopover
      ? [GridItem(.flexible(), spacing: 8)]
      : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    return VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .textCase(.uppercase)

      LazyVGrid(columns: columns, spacing: isPopover ? 6 : 10) {
        ForEach(kinds, id: \.rawValue) { kind in
          providerChoice(kind)
        }
      }
    }
  }

  private func providerChoice(_ kind: ProviderKind) -> some View {
    let isSelected = kind == currentSelection
    return Button { choose(kind) } label: {
      HStack(spacing: 11) {
        MacProviderMark(kind: kind, size: isPopover ? 30 : 36, isReady: true)
        VStack(alignment: .leading, spacing: 2) {
          Text(kind.macPickerTitle)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .lineLimit(1)
          Text(kind.macPickerDescription)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(1)
        }
        Spacer(minLength: 6)
        if isSelected {
          Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.accent)
        }
      }
      .padding(isPopover ? 10 : 12)
      .frame(maxWidth: .infinity, minHeight: isPopover ? 52 : 64, alignment: .leading)
    }
    .buttonStyle(MacCardButtonStyle(cornerRadius: 10, isSelected: isSelected))
  }

  private func choose(_ kind: ProviderKind) {
    if !isEmbedded {
      dismiss()
    }
    selected(kind)
  }
}

/// Searchable catalog of every supported provider, reachable from the Free
/// 1-connection limit banner so users can browse cloud, local, and custom
/// providers with live search and Connected badges.
struct MacSupportedProvidersCatalogView: View {
  @Bindable var model: MacProviderModel
  var backTitle: String? = nil
  var onBack: (() -> Void)? = nil
  let onSelect: (ProviderKind) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  private var isEmbedded: Bool { onBack != nil }

  private var connectedKinds: Set<ProviderKind> {
    Set(model.accounts.map(\.kind))
  }

  private var filteredCloud: [ProviderKind] {
    ProviderKind.cloudCatalog.filter { $0.matchesMacProviderSearch(searchText) }
  }

  private var filteredLocalAndCustom: [ProviderKind] {
    ProviderKind.localAndCustomCatalog.filter { $0.matchesMacProviderSearch(searchText) }
  }

  var body: some View {
    VStack(spacing: 0) {
      if let onBack {
        HStack(spacing: 12) {
          Button(action: onBack) {
            Label(backTitle ?? "AI Providers", systemImage: "chevron.left")
              .foregroundStyle(MacDesignTokens.Colors.accent)
          }
          .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
          .keyboardShortcut(.cancelAction)
          Divider().frame(height: 24)
          VStack(alignment: .leading, spacing: 2) {
            Text("Supported Providers")
              .font(.headline)
            Text("Cloud, local, and OpenAI-compatible providers supported by BYOKchat.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          Spacer()
          MacProviderSearchField(placeholder: "Search providers", text: $searchText)
            .frame(maxWidth: 260)
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .background(MacDesignTokens.Colors.surface.opacity(0.45))
      } else {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("Supported Providers")
              .font(.title3.weight(.semibold))
            Text("Cloud, local, and OpenAI-compatible providers supported by BYOKchat.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          Spacer()
          MacSheetCloseButton(accessibilityLabel: "Close Supported Providers") {
            dismiss()
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)

        MacProviderSearchField(placeholder: "Search providers", text: $searchText)
          .padding(.horizontal, 18)
          .padding(.bottom, 12)
      }

      Divider()

      if filteredCloud.isEmpty && filteredLocalAndCustom.isEmpty {
        ContentUnavailableView.search(text: searchText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            if !filteredCloud.isEmpty {
              catalogGroup(title: "Cloud Providers", kinds: filteredCloud)
            }
            if !filteredLocalAndCustom.isEmpty {
              catalogGroup(title: "Local & Custom", kinds: filteredLocalAndCustom)
            }
          }
          .padding(18)
        }
      }
    }
    .frame(
      width: isEmbedded ? nil : MacDesignTokens.Sheet.standardWidth,
      height: isEmbedded ? nil : MacDesignTokens.Sheet.standardHeight
    )
    .frame(maxWidth: isEmbedded ? .infinity : nil, maxHeight: isEmbedded ? .infinity : nil)
    .background(MacDesignTokens.Colors.canvas)
  }

  private func catalogGroup(title: String, kinds: [ProviderKind]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .textCase(.uppercase)

      LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
        ForEach(kinds, id: \.rawValue) { kind in
          catalogRow(kind)
        }
      }
    }
  }

  private func catalogRow(_ kind: ProviderKind) -> some View {
    let isConnected = connectedKinds.contains(kind)
    return Button {
      guard MacProAccess.requireProviderAccountCapacity(currentCount: model.accounts.count) else {
        return
      }
      if !isEmbedded {
        dismiss()
      }
      onSelect(kind)
    } label: {
      HStack(spacing: 11) {
        MacProviderMark(kind: kind, size: 36, isReady: true)
        VStack(alignment: .leading, spacing: 2) {
          Text(kind.macPickerTitle)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .lineLimit(1)
          Text(kind.macPickerDescription)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(1)
        }
        Spacer(minLength: 6)
        if isConnected {
          Text("Connected")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.14), in: Capsule())
            .fixedSize()
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }
    .buttonStyle(MacCardButtonStyle(cornerRadius: 10))
  }
}

private struct MacProviderAddModelSheet: View {
  let add: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @FocusState private var isModelFieldFocused: Bool
  @State private var modelID = ""

  private var trimmedModelID: String {
    modelID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add Model").font(.headline)
      TextField("Model ID", text: $modelID)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 13, design: .monospaced))
        .focused($isModelFieldFocused)
        .onSubmit { submit() }
      Text("Add a model ID manually when discovery does not list it.")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      HStack(spacing: 8) {
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          .keyboardShortcut(.cancelAction)
        Button("Add") { submit() }
          .buttonStyle(MacActionButtonStyle(.primary, size: .small))
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedModelID.isEmpty)
      }
    }
    .padding(16)
    .frame(width: 340)
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      isModelFieldFocused = true
    }
  }

  private func submit() {
    guard !trimmedModelID.isEmpty else { return }
    add(trimmedModelID)
    dismiss()
  }
}

private struct MacProviderInsetGroup<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
    VStack(spacing: 0) {
      content
    }
    .background(MacDesignTokens.Colors.surface, in: shape)
    .clipShape(shape)
    .overlay {
      shape.stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
        .allowsHitTesting(false)
    }
  }
}

private struct MacProviderAccountRow<MenuContent: View>: View {
  let account: ProviderAccount
  let typeSubtitle: String?
  let state: MacProviderPresentationState
  let isDefault: Bool
  let defaultModelName: String
  let hasDefaultModel: Bool
  let modelCountText: String?
  let isTesting: Bool
  let isBusy: Bool
  let testResult: Bool?
  let onOpen: () -> Void
  let onTest: () -> Void
  @ViewBuilder let menuItems: MenuContent

  @State private var isHovered = false
  @State private var suppressHoverActionsUntilExit = false

  private var showsHoverActions: Bool {
    isHovered && !isTesting && !suppressHoverActionsUntilExit
  }

  var body: some View {
    HStack(spacing: 14) {
      HStack(spacing: 11) {
        MacProviderMark(account: account, size: 30, isReady: state == .ready)
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 5) {
            Text(account.label)
              .font(.system(size: 13.5, weight: .semibold))
              .foregroundStyle(
                state == .disabled
                  ? MacDesignTokens.Colors.textMuted
                  : MacDesignTokens.Colors.textPrimary
              )
              .lineLimit(1)
            if isDefault {
              Text("·")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
              Text("Default")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MacDesignTokens.Colors.accent)
                .fixedSize()
            }
          }
          if let typeSubtitle {
            Text(typeSubtitle)
              .font(.system(size: 11))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)
          }
        }
      }
      .frame(width: 244, alignment: .leading)

      HStack(spacing: 5) {
        Text(defaultModelName)
          .font(.system(size: 13))
          .foregroundStyle(
            hasDefaultModel && state != .disabled
              ? MacDesignTokens.Colors.textPrimary.opacity(0.85)
              : MacDesignTokens.Colors.textMuted
          )
          .lineLimit(1)
          .truncationMode(.tail)
        if let modelCountText {
          Text("·")
            .font(.system(size: 12.5))
            .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.7))
          Text(modelCountText)
            .font(.system(size: 12.5))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .fixedSize()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 8) {
        ZStack(alignment: .trailing) {
          statusIndicator
            .opacity(showsHoverActions ? 0 : 1)
            .allowsHitTesting(false)

          HStack(spacing: 4) {
            if state == .ready {
              Button("Test", action: onTest)
                .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
                .disabled(isTesting || isBusy)
            }
            Menu {
              menuItems
            } label: {
              MacIconMenuLabel(systemImage: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
          }
          .opacity(showsHoverActions ? 1 : 0)
          .allowsHitTesting(showsHoverActions)
        }
        .frame(minWidth: 108, alignment: .trailing)

        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(
            isHovered
              ? MacDesignTokens.Colors.textPrimary.opacity(0.75)
              : MacDesignTokens.Colors.textMuted.opacity(0.5)
          )
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(minHeight: 52)
    .background(Color.primary.opacity(isHovered ? 0.035 : 0))
    .contentShape(Rectangle())
    .onTapGesture(perform: onOpen)
    .onHover { hovering in
      isHovered = hovering
      if !hovering {
        suppressHoverActionsUntilExit = false
      }
    }
    .onChange(of: isTesting) { _, testing in
      if testing {
        suppressHoverActionsUntilExit = true
      }
    }
    .animation(
      .easeOut(duration: MacDesignTokens.Control.interactionDuration),
      value: isHovered
    )
    .animation(
      .easeOut(duration: MacDesignTokens.Control.interactionDuration),
      value: showsHoverActions
    )
  }

  @ViewBuilder
  private var statusIndicator: some View {
    if isTesting {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.mini)
        Text("Testing…")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    } else if let testResult {
      HStack(spacing: 5) {
        Image(systemName: testResult ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .font(.system(size: 11))
        Text(testResult ? "Connected" : "Failed")
          .font(.system(size: 12, weight: .medium))
      }
      .foregroundStyle(testResult ? MacDesignTokens.Colors.accent : Color.orange)
    } else {
      switch state {
      case .ready:
        HStack(spacing: 6) {
          Circle()
            .fill(MacDesignTokens.Colors.accent)
            .frame(width: 6, height: 6)
          Text("Ready")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      case .disabled:
        HStack(spacing: 6) {
          Circle()
            .strokeBorder(MacDesignTokens.Colors.textMuted.opacity(0.65), lineWidth: 1.2)
            .frame(width: 6, height: 6)
          Text("Disabled")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      case .credentialRequired:
        HStack(spacing: 5) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5))
          Text("No key")
            .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Color.orange)
      case .modelRequired:
        HStack(spacing: 5) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5))
          Text("No model")
            .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Color.orange)
      }
    }
  }
}

private struct MacProviderSearchField: View {
  let placeholder: String
  @Binding var text: String

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass").foregroundStyle(MacDesignTokens.Colors.textMuted)
      TextField(placeholder, text: $text).textFieldStyle(.plain)
      if !text.isEmpty {
        Button { text = "" } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(MacDesignTokens.Colors.textMuted)
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
  }
}

private struct MacProviderStateLabel: View {
  let state: MacProviderPresentationState

  var body: some View {
    Label(state.rawValue, systemImage: symbol)
      .font(.caption.weight(.medium))
      .foregroundStyle(tint)
  }

  private var tint: Color {
    switch state {
    case .credentialRequired, .modelRequired:
      Color.orange
    case .ready, .disabled:
      MacDesignTokens.Colors.textMuted
    }
  }

  private var symbol: String {
    switch state {
    case .ready: "checkmark.circle.fill"
    case .disabled: "pause.circle"
    case .credentialRequired: "key.horizontal"
    case .modelRequired: "cube"
    }
  }
}

private struct MacProviderSectionCard<Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder let content: Content

  init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: systemImage)
        .font(.headline)
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      content
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

private struct MacProviderValueRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title).foregroundStyle(MacDesignTokens.Colors.textMuted)
      Spacer()
      Text(value)
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
    .font(.system(size: 13))
  }
}
