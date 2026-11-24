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

struct MacProviderManagementView: View {
  @Bindable var model: MacProviderModel
  let showsCloseButton: Bool

  @Environment(\.dismiss) private var dismiss
  @State private var selectedAccountID: ProviderAccountID?
  @State private var searchText = ""
  @State private var showingProviderPicker = false
  @State private var editorRoute: MacConnectionEditorRoute?
  @State private var deleteAccount: ProviderAccount?
  @State private var testingAccountID: ProviderAccountID?
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
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          .help("Close")
          .accessibilityLabel("Close AI Providers")
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
        deleteAccount = nil
        Task { @MainActor in
          await model.deleteConnection(account.id)
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
          .buttonStyle(.borderedProminent)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          MacProviderSearchField(placeholder: "Search providers", text: $searchText)
            .frame(maxWidth: 360)
          Spacer()
          Button("Add AI Provider", systemImage: "plus") { beginAddProvider() }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(MacDesignTokens.Colors.surface.opacity(0.45))

        Divider()

        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            Text("\(visibleAccounts.count) connection\(visibleAccounts.count == 1 ? "" : "s")")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)

            if visibleAccounts.isEmpty {
              ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
              LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
              ) {
                ForEach(visibleAccounts) { account in
                  providerCard(account)
                }
              }
            }
          }
          .padding(16)
        }
      }
    }
  }

  private func providerCard(_ account: ProviderAccount) -> some View {
    let state = macProviderPresentationState(model: model, account: account)
    let records = model.models(for: account.id, includeHidden: true)
    let isDefault = model.defaultAccountID == account.id
    let isTesting = testingAccountID == account.id

    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 11) {
        MacProviderIcon(kind: account.kind, size: 40, isReady: state == .ready)
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
          Button("Manage", systemImage: "arrow.right.circle") { selectedAccountID = account.id }
          Button("Edit Connection…", systemImage: "pencil") { editorRoute = .edit(account.id) }
          if !isDefault && state == .ready {
            Button("Make Default", systemImage: "checkmark.circle") {
              Task { _ = await model.setDefaultAccount(account.id) }
            }
          }
          Button(
            account.isEnabled ? "Disable" : "Enable",
            systemImage: account.isEnabled ? "pause.circle" : "play.circle"
          ) {
            Task { _ = await model.setAccountEnabled(!account.isEnabled, accountID: account.id) }
          }
          Divider()
          Button("Delete Connection…", systemImage: "trash", role: .destructive) {
            deleteAccount = account
          }
        } label: {
          Image(systemName: "ellipsis").frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
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
        Text("\(records.count) model\(records.count == 1 ? "" : "s")")
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
            .controlSize(.small)
            .disabled(isTesting || model.isBusy)
        }
        Spacer()
        Button(state == .ready ? "Manage" : "Configure") { selectedAccountID = account.id }
          .controlSize(.small)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 185, alignment: .topLeading)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
    .contentShape(Rectangle())
    .onTapGesture { selectedAccountID = account.id }
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

  @State private var tab: MacProviderDetailTab = .overview
  @State private var isTesting = false
  @State private var testResult: Bool?

  private var state: MacProviderPresentationState {
    macProviderPresentationState(model: model, account: account)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Button(action: back) { Label("AI Providers", systemImage: "chevron.left") }
          .buttonStyle(.plain)
          .foregroundStyle(MacDesignTokens.Colors.accent)
        Divider().frame(height: 24)
        MacProviderIcon(kind: account.kind, size: 40, isReady: state == .ready)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text(account.label).font(.title3.weight(.semibold)).lineLimit(1)
            if model.defaultAccountID == account.id {
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
        .disabled(isTesting || state != .ready || model.isBusy)
        Button("Edit", systemImage: "pencil", action: edit)
        Menu {
          if model.defaultAccountID != account.id && state == .ready {
            Button("Make Default", systemImage: "checkmark.circle") {
              Task { _ = await model.setDefaultAccount(account.id) }
            }
          }
          Button(
            account.isEnabled ? "Disable" : "Enable",
            systemImage: account.isEnabled ? "pause.circle" : "play.circle"
          ) {
            Task { _ = await model.setAccountEnabled(!account.isEnabled, accountID: account.id) }
          }
          Divider()
          Button("Delete Connection…", systemImage: "trash", role: .destructive, action: requestDelete)
        } label: {
          Image(systemName: "ellipsis").frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      .padding(.horizontal, 18)
      .frame(height: 70)
      .background(MacDesignTokens.Colors.surface.opacity(0.45))

      Divider()

      Picker("Section", selection: $tab) {
        ForEach(MacProviderDetailTab.allCases) { value in Text(value.rawValue).tag(value) }
      }
      .pickerStyle(.segmented)
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

  private var records: [AccountModelRecord] {
    model.models(for: account.id, includeHidden: true)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        MacProviderSectionCard(title: "Status", systemImage: "checkmark.circle") {
          VStack(alignment: .leading, spacing: 9) {
            MacProviderStateLabel(state: macProviderPresentationState(model: model, account: account))
            MacProviderValueRow(title: "Connection", value: account.isEnabled ? "Enabled" : "Disabled")
            MacProviderValueRow(title: "Credential", value: credentialSummary)
            if let testResult {
              MacProviderValueRow(title: "Last Test", value: testResult ? "Connection succeeded" : "Connection failed")
            }
          }
        }

        MacProviderSectionCard(title: "Default", systemImage: "checkmark.seal") {
          VStack(alignment: .leading, spacing: 9) {
            MacProviderValueRow(title: "Default Connection", value: model.defaultAccountID == account.id ? "Yes" : "No")
            MacProviderValueRow(title: "Default Model", value: defaultModelLabel)
            HStack {
              Spacer()
              if model.defaultAccountID != account.id,
                macProviderPresentationState(model: model, account: account) == .ready
              {
                Button("Make Default") { Task { _ = await model.setDefaultAccount(account.id) } }
              }
              Button("View Models", action: showModels)
            }
          }
        }

        MacProviderSectionCard(title: "Models", systemImage: "cube") {
          VStack(alignment: .leading, spacing: 9) {
            MacProviderValueRow(title: "Available", value: records.filter(\.isAvailable).count.formatted())
            MacProviderValueRow(title: "Favorites", value: records.filter(\.isFavorite).count.formatted())
            MacProviderValueRow(title: "Hidden", value: records.filter(\.isHidden).count.formatted())
            HStack { Spacer(); Button("View Models", action: showModels) }
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
            HStack { Spacer(); Button("View Connection", action: showConnection) }
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

  @State private var searchText = ""
  @State private var showHidden = false
  @State private var showingAddModel = false

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
          Button("Refresh", systemImage: "arrow.clockwise") {
            Task { _ = await model.refreshModels(accountID: account.id) }
          }
          .disabled(model.isBusy)
        }
        Button("Add Model", systemImage: "plus") { showingAddModel = true }
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
        Task { _ = await model.addManualModel(modelID, accountID: account.id) }
      }
    }
  }

  private func modelRow(_ record: AccountModelRecord) -> some View {
    HStack(spacing: 12) {
      Button {
        Task { await model.setFavorite(!record.isFavorite, modelID: record.model.id, accountID: account.id) }
      } label: {
        Image(systemName: record.isFavorite ? "star.fill" : "star")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .foregroundStyle(record.isFavorite ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted)

      VStack(alignment: .leading, spacing: 3) {
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
      }
      .opacity(record.isAvailable ? 1 : 0.55)

      Spacer()

      if account.defaultModelID != record.model.id && record.isAvailable && !record.isHidden {
        Button("Make Default") {
          Task { _ = await model.setDefaultModel(record.model.id, accountID: account.id) }
        }
        .controlSize(.small)
      }

      Button {
        Task { await model.setHidden(!record.isHidden, modelID: record.model.id, accountID: account.id) }
      } label: {
        Image(systemName: record.isHidden ? "eye.slash.fill" : "eye")
          .frame(width: 26, height: 26)
      }
      .buttonStyle(.plain)
      .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 11)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.72), lineWidth: 0.5)
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
            HStack { Spacer(); Button("Edit", action: edit) }
          }
        }

        MacProviderSectionCard(title: "Authentication", systemImage: "key") {
          VStack(alignment: .leading, spacing: 9) {
            MacProviderValueRow(title: "Method", value: authenticationSummary)
            MacProviderValueRow(title: "Credential", value: credentialSummary)
            Text("Stored credentials remain in Keychain and are never shown on this summary screen.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            HStack { Spacer(); Button("Edit", action: edit) }
          }
        }

        MacProviderSectionCard(title: "Custom Headers", systemImage: "list.bullet.rectangle") {
          VStack(alignment: .leading, spacing: 8) {
            if account.additionalHeaders.isEmpty {
              Text("No custom headers").foregroundStyle(MacDesignTokens.Colors.textMuted)
            } else {
              ForEach(account.additionalHeaders.keys.sorted(), id: \.self) { key in
                MacProviderValueRow(title: key, value: "Configured")
              }
            }
            HStack { Spacer(); Button("Edit", action: edit) }
          }
        }

        if account.kind == .openRouter {
          MacProviderSectionCard(title: "OpenRouter", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 9) {
              MacProviderValueRow(title: "App Title", value: account.metadata["appTitle"] ?? "Not set")
              MacProviderValueRow(title: "HTTP Referer", value: account.metadata["httpReferer"] ?? "Not set")
              HStack { Spacer(); Button("Edit", action: edit) }
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

private struct MacProviderKindPickerSheet: View {
  let selected: (ProviderKind) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Add AI Provider").font(.title3.weight(.semibold))
          Text("Choose a service to connect.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          .help("Close")
          .accessibilityLabel("Close Add AI Provider")
      }
      .padding(18)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(ProviderKind.catalog, id: \.rawValue) { kind in providerChoice(kind) }
          }
          Divider()
          Button { choose(.openAICompatible) } label: {
            HStack(spacing: 12) {
              MacProviderIcon(kind: .openAICompatible, size: 38, isReady: true)
              VStack(alignment: .leading, spacing: 3) {
                Text("OpenAI-compatible Server")
                  .font(.system(size: 13.5, weight: .semibold))
                  .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                Text("Connect Ollama, LM Studio, a LAN server, or another compatible API.")
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
              Spacer()
              Image(systemName: "chevron.right").foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            .padding(13)
            .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
              RoundedRectangle(cornerRadius: 10)
                .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
            }
          }
          .buttonStyle(.plain)
        }
        .padding(18)
      }
    }
    .frame(width: 620, height: 500)
    .background(MacDesignTokens.Colors.canvas)
  }

  private func providerChoice(_ kind: ProviderKind) -> some View {
    Button { choose(kind) } label: {
      HStack(spacing: 11) {
        MacProviderIcon(kind: kind, size: 36, isReady: true)
        VStack(alignment: .leading, spacing: 2) {
          Text(kind.displayName)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          Text(providerDescription(kind))
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        Spacer()
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
      .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
      }
    }
    .buttonStyle(.plain)
  }

  private func choose(_ kind: ProviderKind) {
    dismiss()
    selected(kind)
  }

  private func providerDescription(_ kind: ProviderKind) -> String {
    switch kind {
    case .openai: "GPT models"
    case .xAI: "Grok models"
    case .anthropic: "Claude models"
    case .gemini: "Gemini models"
    case .deepSeek: "DeepSeek models"
    case .zAI: "GLM models"
    case .moonshot: "Kimi models"
    case .minimax: "MiniMax models"
    case .qwen: "Qwen models"
    case .mistral: "Mistral models"
    case .groq: "Fast LPU inference"
    case .together: "Open-source hosted models"
    case .fireworks: "Fast hosted inference"
    case .openRouter: "Multi-provider routing"
    case .nvidia: "NVIDIA hosted models"
    case .ollama: "Local Ollama server"
    case .lmStudio: "Local LM Studio server"
    case .openAICompatible: "Compatible APIs"
    }
  }
}

private struct MacProviderAddModelSheet: View {
  let add: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var modelID = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Add Model").font(.headline)
      TextField("Model ID", text: $modelID)
      Text("Add a model ID manually when discovery does not list it.")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Add") {
          add(modelID.trimmingCharacters(in: .whitespacesAndNewlines))
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
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

private struct MacProviderIcon: View {
  let kind: ProviderKind
  let size: CGFloat
  let isReady: Bool

  var body: some View {
    Image(systemName: providerSymbol(kind))
      .font(.system(size: size * 0.48, weight: .semibold))
      .foregroundStyle(isReady ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted)
      .frame(width: size, height: size)
      .background(
        (isReady ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted).opacity(0.11),
        in: RoundedRectangle(cornerRadius: size * 0.27)
      )
      .accessibilityHidden(true)
  }
}

private struct MacProviderStateLabel: View {
  let state: MacProviderPresentationState

  var body: some View {
    Label(state.rawValue, systemImage: symbol)
      .font(.caption.weight(.medium))
      .foregroundStyle(state == .credentialRequired || state == .modelRequired ? Color.orange : MacDesignTokens.Colors.textMuted)
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
