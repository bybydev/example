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
  case proRequired = "Pro required"
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
  if model.isProviderRestricted(account.id) { return .proRequired }
  guard account.isEnabled else { return .disabled }
  if account.definition.requiresCredential, !model.hasCredential(account.id) {
    return .credentialRequired
  }
  guard model.models(for: account.id).contains(where: { $0.isAvailable }) else {
    return .modelRequired
  }
  return .ready
}

struct MacProviderManagementView: View {
  @Bindable var model: MacProviderModel
  let showsCloseButton: Bool

  @Environment(\.dismiss) private var dismiss
  @Environment(\.macToastCenter) private var toastCenter
  @State private var selectedAccountID: ProviderAccountID?
  @State private var searchText = ""
  @State private var showingProviderPicker = false
  @State private var showingSupportedProviders = false
  @State private var editorRoute: MacConnectionEditorRoute?
  @State private var deleteAccount: ProviderAccount?
  @State private var testingAccountID: ProviderAccountID?
  @State private var refreshingAccountID: ProviderAccountID?
  @State private var testResultAccountID: ProviderAccountID?
  @State private var testSucceeded: Bool?

  init(model: MacProviderModel, showsCloseButton: Bool = true) {
    self.model = model
    self.showsCloseButton = showsCloseButton
  }

  private var selectedAccount: ProviderAccount? {
    model.account(selectedAccountID)
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
          MacSheetCloseButton(accessibilityLabel: "Close AI Providers") {
            dismiss()
          }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(MacDesignTokens.Colors.surface)

        Divider()
      }

      Group {
        if let account = selectedAccount {
          MacProviderWorkspaceDetailView(
            model: model,
            account: account,
            back: { selectedAccountID = nil },
            edit: { editorRoute = .edit(account.id) },
            requestDelete: { deleteAccount = account }
          )
          .id(account.id.rawValue)
        } else {
          providersHome
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 920, minHeight: 620)
    .background(MacDesignTokens.Colors.canvas)
    .onChange(of: model.accounts.map(\.id)) { _, ids in
      if let selectedAccountID, !ids.contains(selectedAccountID) {
        self.selectedAccountID = nil
      }
    }
    .sheet(isPresented: $showingProviderPicker) {
      MacProviderKindPickerSheet { kind in
        editorRoute = .create(kind)
      }
    }
    .sheet(isPresented: $showingSupportedProviders) {
      MacSupportedProvidersCatalogView(model: model) { kind in
        editorRoute = .create(kind)
      }
    }
    .sheet(item: $editorRoute) { route in
      MacConnectionEditorView(model: model, route: route) { accountID in
        if let accountID { selectedAccountID = accountID }
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
          if selectedAccountID == account.id { selectedAccountID = nil }
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
          VStack(alignment: .leading, spacing: 12) {
            if showsFreeLimitBanner {
              freeLimitBanner
            }

            Text("\(visibleAccounts.count) connection\(visibleAccounts.count == 1 ? "" : "s")")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)

            if visibleAccounts.isEmpty {
              ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
              let partition = MacActiveDisabledPartition(visibleAccounts, isEnabled: \.isEnabled)
              let columns = [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
              ]

              if !partition.active.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                  if partition.showsSectionHeaders {
                    providerSectionHeader("Active", count: partition.active.count)
                  }
                  LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(partition.active) { account in
                      providerCard(account)
                    }
                  }
                }
              }

              if !partition.disabled.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                  providerSectionHeader("Disabled", count: partition.disabled.count)
                  LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(partition.disabled) { account in
                      providerCard(account)
                    }
                  }
                }
                .padding(.top, partition.active.isEmpty ? 0 : 6)
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
          showingSupportedProviders = true
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

  private func providerCard(_ account: ProviderAccount) -> some View {
    let state = macProviderPresentationState(model: model, account: account)
    let visibleRecords = model.models(for: account.id)
    let availableCount = visibleRecords.filter(\.isAvailable).count
    let hiddenCount = model.models(for: account.id, includeHidden: true).count - visibleRecords.count
    let isDefault = model.defaultAccountID == account.id && state == .ready
    let isTesting = testingAccountID == account.id

    return MacProviderAccountCard(onOpen: { selectedAccountID = account.id }) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 11) {
          MacProviderMark(account: account, size: 40, isReady: state == .ready)
          VStack(alignment: .leading, spacing: 2) {
            Text(account.label)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .lineLimit(1)
            Text(providerTypeName(account))
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          Spacer()
          Menu {
            providerCardMenuItems(for: account, state: state, isDefault: isDefault)
          } label: {
            MacIconMenuLabel(systemImage: "ellipsis")
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
        }

        HStack(spacing: 8) {
          MacProviderStateLabel(state: state)
          if isDefault {
            Text("DEFAULT")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(MacDesignTokens.Colors.accent)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(MacDesignTokens.Colors.accent.opacity(0.10), in: Capsule())
          }
        }

        VStack(alignment: .leading, spacing: 3) {
          Text(defaultModelSummary(account))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .lineLimit(1)
          Text(modelCountSummary(available: availableCount, hidden: hiddenCount))
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        if testResultAccountID == account.id, let testSucceeded {
          Label(
            testSucceeded ? "Connection succeeded" : "Connection failed",
            systemImage: testSucceeded ? "checkmark.circle" : "exclamationmark.triangle"
          )
          .font(.caption)
          .foregroundStyle(testSucceeded ? MacDesignTokens.Colors.textMuted : Color.orange)
        }

        HStack {
          if state == .ready {
            Button(isTesting ? "Testing…" : "Test") { testConnection(account) }
              .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
              .disabled(isTesting || model.isBusy)
          } else if state == .proRequired {
            Button("Upgrade") { MacProAccess.requestUpgrade(.providerAccounts) }
              .buttonStyle(MacActionButtonStyle(.primary, size: .small))
          }
          Spacer()
          Button(state == .ready || state == .proRequired ? "Manage" : "Configure") {
            selectedAccountID = account.id
          }
          .buttonStyle(
            MacActionButtonStyle(
              state == .ready || state == .proRequired ? .secondary : .primary,
              size: .small
            )
          )
        }
      }
    }
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
    guard state == .ready || state == .modelRequired, !model.isProviderRestricted(account.id) else {
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
    Button("Manage", systemImage: "arrow.right.circle") { selectedAccountID = account.id }
    if state == .proRequired {
      Button("Upgrade to BYOK Pro", systemImage: "crown.fill") {
        MacProAccess.requestUpgrade(.providerAccounts)
      }
    } else {
      Button("Edit Connection…", systemImage: "pencil") { editorRoute = .edit(account.id) }
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
    showingProviderPicker = true
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
    guard state == .ready || state == .modelRequired, !model.isProviderRestricted(account.id) else {
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
        if state == .proRequired {
          Button("Upgrade to Pro", systemImage: "crown.fill") {
            MacProAccess.requestUpgrade(.providerAccounts)
          }
          .buttonStyle(MacActionButtonStyle(.primary))
        } else {
          Button(isTesting ? "Testing…" : "Test Connection", systemImage: "bolt.horizontal.circle") {
            testConnection()
          }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .disabled(isTesting || state != .ready || model.isBusy)
          Button("Edit", systemImage: "pencil", action: edit)
            .buttonStyle(MacActionButtonStyle(.secondary))
        }
        Menu {
          if state == .proRequired {
            Button("Upgrade to BYOK Pro", systemImage: "crown.fill") {
              MacProAccess.requestUpgrade(.providerAccounts)
            }
          } else {
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

      if state == .proRequired {
        HStack(spacing: 12) {
          Image(systemName: "crown.fill")
            .foregroundStyle(MacDesignTokens.Colors.accent)
          Text("This restored connection exceeds the Free 1-connection limit. Upgrade to BYOK Pro or remove another connection to unlock it.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Button("Upgrade") {
            MacProAccess.requestUpgrade(.providerAccounts)
          }
          .buttonStyle(MacActionButtonStyle(.primary, size: .small))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(MacDesignTokens.Colors.accentSoft.opacity(0.65))

        Divider()
      }

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
    (state == .ready || state == .modelRequired) && !model.isProviderRestricted(account.id)
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
          .disabled(state == .proRequired)
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
    .sheet(isPresented: $showingAddModel) {
      MacProviderAddModelSheet { modelID in
        Task {
          if await model.addManualModel(modelID, accountID: account.id) {
            toastCenter?.success("Added \(modelID)")
          }
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

      if account.defaultModelID != record.model.id && record.isAvailable && !record.isHidden && state != .proRequired {
        Button("Make Default") {
          Task {
            if await model.setDefaultModel(record.model.id, accountID: account.id) {
              toastCenter?.success("Default model set to \(record.model.displayName)")
            }
          }
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
      }

      if record.isManual && state != .proRequired {
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
      if record.isManual && state != .proRequired {
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
                .disabled(macProviderPresentationState(model: model, account: account) == .proRequired)
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
                .disabled(macProviderPresentationState(model: model, account: account) == .proRequired)
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
                .disabled(macProviderPresentationState(model: model, account: account) == .proRequired)
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
                  .disabled(macProviderPresentationState(model: model, account: account) == .proRequired)
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
  var currentSelection: ProviderKind? = nil
  let selected: (ProviderKind) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  private var filteredCloud: [ProviderKind] {
    ProviderKind.cloudCatalog.filter { $0.matchesMacProviderSearch(searchText) }
  }

  private var filteredLocalAndCustom: [ProviderKind] {
    ProviderKind.localAndCustomCatalog.filter { $0.matchesMacProviderSearch(searchText) }
  }

  var body: some View {
    VStack(spacing: 0) {
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

      Divider()

      if filteredCloud.isEmpty && filteredLocalAndCustom.isEmpty {
        ContentUnavailableView.search(text: searchText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            if !filteredCloud.isEmpty {
              providerGroup(title: "Cloud Providers", kinds: filteredCloud)
            }
            if !filteredLocalAndCustom.isEmpty {
              providerGroup(title: "Local & Custom", kinds: filteredLocalAndCustom)
            }
          }
          .padding(18)
        }
      }
    }
    .frame(width: 640, height: 540)
    .background(MacDesignTokens.Colors.canvas)
  }

  private func providerGroup(title: String, kinds: [ProviderKind]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .textCase(.uppercase)

      LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
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
        if isSelected {
          Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.accent)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }
    .buttonStyle(MacCardButtonStyle(cornerRadius: 10, isSelected: isSelected))
  }

  private func choose(_ kind: ProviderKind) {
    dismiss()
    selected(kind)
  }
}

/// Searchable catalog of every supported provider, reachable from the Free
/// 1-connection limit banner so users can browse cloud, local, and custom
/// providers with live search and Connected badges.
struct MacSupportedProvidersCatalogView: View {
  @Bindable var model: MacProviderModel
  let onSelect: (ProviderKind) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

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
    .frame(width: 640, height: 540)
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
      dismiss()
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
    VStack(alignment: .leading, spacing: 14) {
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
          .buttonStyle(MacActionButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
        Button("Add") { submit() }
          .buttonStyle(MacActionButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedModelID.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
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

private struct MacProviderAccountCard<Content: View>: View {
  let onOpen: () -> Void
  @ViewBuilder let content: Content

  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
    content
      .padding(14)
      .frame(maxWidth: .infinity, minHeight: 185, alignment: .topLeading)
      .background(MacDesignTokens.Colors.surface, in: shape)
      .overlay {
        shape.fill(Color.primary.opacity(isHovered ? 0.03 : 0))
          .allowsHitTesting(false)
      }
      .overlay {
        shape.stroke(
          isHovered
            ? MacDesignTokens.Colors.accent.opacity(0.45)
            : MacDesignTokens.Colors.separator.opacity(0.75),
          lineWidth: isHovered ? 0.85 : 0.5
        )
        .allowsHitTesting(false)
      }
      .contentShape(shape)
      .onTapGesture(perform: onOpen)
      .onHover { isHovered = $0 }
      .animation(
        .easeOut(duration: MacDesignTokens.Control.interactionDuration),
        value: isHovered
      )
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
    case .proRequired:
      MacDesignTokens.Colors.accent
    case .ready, .disabled:
      MacDesignTokens.Colors.textMuted
    }
  }

  private var symbol: String {
    switch state {
    case .ready: "checkmark.circle.fill"
    case .disabled: "pause.circle"
    case .proRequired: "crown.fill"
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
