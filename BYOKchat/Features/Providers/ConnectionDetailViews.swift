import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct ConnectionDetailView: View {
  @Bindable var model: ProviderManagementModel
  let accountID: ProviderAccountID

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var showCredentialEditor = false
  @State private var showPreferencesEditor = false
  @State private var showAdvancedEditor = false
  @State private var showManualModel = false
  @State private var showDelete = false
  @State private var testState: TestState = .idle

  private enum TestState {
    case idle
    case testing
    case success
    case failed
  }

  private var account: ProviderAccount? {
    model.accounts.first { $0.id == accountID }
  }

  private var provider: ProviderDefinition? {
    guard let account else { return nil }
    return model.provider(for: account.providerID)
  }

  private var models: [AccountModelRecord] {
    model.models(for: accountID)
  }

  var body: some View {
    ZStack {
      theme.backgroundColor.ignoresSafeArea()
      if let account {
        ScrollView {
          VStack(spacing: 18) {
            connectionHero(account)
            detailCard(account)
            modelCard(account)
            actionsCard(account)
            Button("Delete Connection", role: .destructive) { showDelete = true }
              .padding(.top, 6)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 16)
        }
      } else {
        ContentUnavailableView("Connection Missing", systemImage: "exclamationmark.triangle")
      }
    }
    .navigationTitle(account?.label ?? "Connection")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showCredentialEditor) {
      if let account, let provider {
        NavigationStack {
          ConnectionCredentialEditorView(model: model, account: account, provider: provider)
        }
      }
    }
    .sheet(isPresented: $showPreferencesEditor) {
      if let account {
        NavigationStack {
          ConnectionPreferencesEditorView(model: model, account: account)
        }
      }
    }
    .sheet(isPresented: $showAdvancedEditor) {
      if let account, let provider {
        NavigationStack {
          ConnectionAdvancedEditorView(model: model, account: account, provider: provider)
        }
      }
    }
    .sheet(isPresented: $showManualModel) {
      ConnectionManualModelView(model: model, accountID: accountID)
    }
    .confirmationDialog("Delete this connection?", isPresented: $showDelete) {
      Button("Delete Connection", role: .destructive) {
        Task { @MainActor in
          await model.deleteAccount(accountID)
          dismiss()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The connection and its saved API key will be removed from this device.")
    }
  }

  private func connectionHero(_ account: ProviderAccount) -> some View {
    VStack(spacing: 10) {
      ConnectionProviderMark(definition: provider, size: 58)
      Text(provider?.displayName ?? account.providerID.rawValue)
        .font(.system(size: 24, weight: .semibold))
      HStack(spacing: 6) {
        Circle()
          .fill(connectionStatus(model: model, account: account).isReady ? theme.accentColor : Color.secondary)
          .frame(width: 8, height: 8)
        Text(connectionStatus(model: model, account: account).label)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
  }

  private func detailCard(_ account: ProviderAccount) -> some View {
    ConnectionSurface {
      ConnectionDetailButton(title: "Connection Name", value: account.label, systemImage: "person.text.rectangle") {
        showPreferencesEditor = true
      }
      Divider()
      ConnectionDetailButton(
        title: "API Key",
        value: apiKeyStatus(account),
        systemImage: apiKeySymbol(account)
      ) {
        showCredentialEditor = true
      }
      Divider()
      ConnectionDetailButton(
        title: "Advanced",
        value: account.baseURLOverride == nil && account.additionalHeaders.isEmpty ? "Provider defaults" : "Customized",
        systemImage: "slider.horizontal.3"
      ) {
        showAdvancedEditor = true
      }
    }
  }

  private func apiKeyStatus(_ account: ProviderAccount) -> String {
    guard let provider, connectionRequiresCredential(provider) else { return "Not required" }
    return model.credentialAccountIDs.contains(account.id) ? "Saved securely" : "Missing"
  }

  private func apiKeySymbol(_ account: ProviderAccount) -> String {
    guard let provider, connectionRequiresCredential(provider) else { return "checkmark.shield" }
    return model.credentialAccountIDs.contains(account.id) ? "key.fill" : "key.slash"
  }

  private func modelCard(_ account: ProviderAccount) -> some View {
    ConnectionSurface {
      ConnectionDetailButton(
        title: "Default Model",
        value: account.defaultModelID.map { modelDisplayName(model: model, accountID: account.id, modelID: $0) } ?? "Choose model",
        systemImage: "cpu"
      ) {
        showPreferencesEditor = true
      }
      Divider()
      Button {
        Task { await model.refreshModels(accountID: account.id) }
      } label: {
        ConnectionActionLabel(title: "Refresh Models", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.plain)
      Divider()
      Button { showManualModel = true } label: {
        ConnectionActionLabel(title: "Add Manual Model", systemImage: "plus")
      }
      .buttonStyle(.plain)
    }
  }

  private func actionsCard(_ account: ProviderAccount) -> some View {
    ConnectionSurface {
      Button {
        testConnection(account)
      } label: {
        HStack(spacing: 12) {
          Image(systemName: testIcon)
            .frame(width: 24)
            .foregroundStyle(theme.accentColor)
          Text(testTitle)
            .font(.system(size: 15, weight: .medium))
          Spacer()
          if testState == .testing { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 2)
      }
      .buttonStyle(.plain)
      .disabled(testState == .testing)
    }
  }

  private var testTitle: String {
    switch testState {
    case .idle: "Test Connection"
    case .testing: "Testing…"
    case .success: "Connection Working"
    case .failed: "Test Again"
    }
  }

  private var testIcon: String {
    switch testState {
    case .idle, .testing: "bolt.horizontal.circle"
    case .success: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle"
    }
  }

  private func testConnection(_ account: ProviderAccount) {
    testState = .testing
    Task { @MainActor in
      let result = await model.testConnectionResult(
        accountID: account.id,
        modelID: account.defaultModelID ?? models.first?.model.id
      )
      testState = result ? .success : .failed
    }
  }
}

private struct ConnectionCredentialEditorView: View {
  @Bindable var model: ProviderManagementModel
  let account: ProviderAccount
  let provider: ProviderDefinition

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var credential = ""
  @State private var baseURL: String
  @State private var headersText: String
  @State private var appTitle: String
  @State private var httpReferer: String

  init(model: ProviderManagementModel, account: ProviderAccount, provider: ProviderDefinition) {
    self.model = model
    self.account = account
    self.provider = provider
    _baseURL = State(initialValue: account.baseURLOverride?.absoluteString ?? "")
    _headersText = State(initialValue: serializeHeaders(account.additionalHeaders))
    _appTitle = State(initialValue: account.metadata["appTitle"] ?? "BYOKchat")
    _httpReferer = State(initialValue: account.metadata["httpReferer"] ?? "")
  }

  var body: some View {
    ZStack {
      theme.backgroundColor.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 22) {
          ConnectionStepHeader(
            definition: provider,
            title: "API Key",
            subtitle: "Replace the credential for this connection or review its advanced request settings."
          )
          ConnectionCredentialFields(
            provider: provider,
            hasStoredCredential: model.credentialAccountIDs.contains(account.id),
            credential: $credential,
            baseURL: $baseURL,
            headersText: $headersText,
            appTitle: $appTitle,
            httpReferer: $httpReferer
          )
        }
        .padding(20)
      }
    }
    .navigationTitle("Connection")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(model.isBusy || !canSave)
      }
    }
  }

  private var canSave: Bool {
    if !connectionRequiresCredential(provider) { return true }
    if model.credentialAccountIDs.contains(account.id) { return true }
    return !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func save() {
    var metadata = account.metadata
    if account.providerID == BuiltInProviders.openRouterID {
      metadata["appTitle"] = appTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      metadata["httpReferer"] = httpReferer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    Task { @MainActor in
      let success = await model.updateAccount(
        account,
        newCredential: credential.isEmpty ? nil : credential,
        baseURL: baseURL,
        headers: parseHeaders(headersText),
        metadata: metadata
      )
      if success { dismiss() }
    }
  }
}

private struct ConnectionPreferencesEditorView: View {
  @Bindable var model: ProviderManagementModel
  let account: ProviderAccount

  @Environment(\.dismiss) private var dismiss
  @State private var connectionName: String
  @State private var selectedModelID: ModelID?
  @State private var manualModelID = ""

  init(model: ProviderManagementModel, account: ProviderAccount) {
    self.model = model
    self.account = account
    _connectionName = State(initialValue: account.label)
    _selectedModelID = State(initialValue: account.defaultModelID)
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        ConnectionStepHeader(
          definition: model.provider(for: account.providerID),
          title: "Connection Preferences",
          subtitle: "Update the name and default model for this connection."
        )
        ConnectionPreferencesFields(
          connectionName: $connectionName,
          selectedModelID: $selectedModelID,
          manualModelID: $manualModelID,
          models: model.models(for: account.id).filter(\.isAvailable)
        )
      }
      .padding(20)
    }
    .navigationTitle("Preferences")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(!canSave || model.isBusy)
      }
    }
  }

  private var canSave: Bool {
    let hasName = !connectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasModel = selectedModelID != nil || !manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return hasName && hasModel
  }

  private func save() {
    Task { @MainActor in
      let trimmedManual = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
      if selectedModelID == nil, !trimmedManual.isEmpty {
        guard await model.addManualModel(trimmedManual, accountID: account.id) else { return }
        selectedModelID = ModelID(rawValue: trimmedManual)
      }
      var updated = account
      updated.label = connectionName.trimmingCharacters(in: .whitespacesAndNewlines)
      updated.defaultModelID = selectedModelID
      let success = await model.updateAccount(
        updated,
        newCredential: nil,
        baseURL: updated.baseURLOverride?.absoluteString ?? "",
        headers: updated.additionalHeaders,
        metadata: updated.metadata
      )
      if success { dismiss() }
    }
  }
}

private struct ConnectionAdvancedEditorView: View {
  @Bindable var model: ProviderManagementModel
  let account: ProviderAccount
  let provider: ProviderDefinition

  @Environment(\.dismiss) private var dismiss
  @State private var baseURL: String
  @State private var headersText: String
  @State private var appTitle: String
  @State private var httpReferer: String

  init(model: ProviderManagementModel, account: ProviderAccount, provider: ProviderDefinition) {
    self.model = model
    self.account = account
    self.provider = provider
    _baseURL = State(initialValue: account.baseURLOverride?.absoluteString ?? "")
    _headersText = State(initialValue: serializeHeaders(account.additionalHeaders))
    _appTitle = State(initialValue: account.metadata["appTitle"] ?? "BYOKchat")
    _httpReferer = State(initialValue: account.metadata["httpReferer"] ?? "")
  }

  var body: some View {
    Form {
      Section {
        TextField("Provider default", text: $baseURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
      } header: {
        Text("Endpoint Override")
      } footer: {
        Text("Leave empty to use the provider's built-in endpoint.")
      }

      if account.providerID == BuiltInProviders.openRouterID {
        Section("OpenRouter") {
          TextField("App title", text: $appTitle)
          TextField("HTTP referer", text: $httpReferer)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        }
      }

      Section {
        TextEditor(text: $headersText)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 120)
      } header: {
        Text("Additional Headers")
      } footer: {
        Text("One header per line as Name: Value. Authentication headers are managed by BYOKchat.")
      }
    }
    .navigationTitle("Advanced")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(model.isBusy)
      }
    }
  }

  private func save() {
    var metadata = account.metadata
    if account.providerID == BuiltInProviders.openRouterID {
      metadata["appTitle"] = appTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      metadata["httpReferer"] = httpReferer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    Task { @MainActor in
      let success = await model.updateAccount(
        account,
        newCredential: nil,
        baseURL: baseURL,
        headers: parseHeaders(headersText),
        metadata: metadata
      )
      if success { dismiss() }
    }
  }
}


private struct ConnectionManualModelView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: ProviderManagementModel
  let accountID: ProviderAccountID
  @State private var modelID = ""

  var body: some View {
    NavigationStack {
      Form {
        TextField("Model ID", text: $modelID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }
      .navigationTitle("Add Model")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            Task { @MainActor in
              if await model.addManualModel(modelID, accountID: accountID) { dismiss() }
            }
          }
          .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }
}
