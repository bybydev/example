import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct ConnectionDetailView: View {
  @Bindable var model: ProviderManagementModel
  let accountID: ProviderAccountID

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var showCredentialEditor = false
  @State private var showNameEditor = false
  @State private var showModels = false
  @State private var showAdvancedEditor = false
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
    account.flatMap { model.provider(for: $0.providerID) }
  }

  private var models: [AccountModelRecord] {
    model.models(for: accountID)
  }

  var body: some View {
    Group {
      if let account {
        List {
          overviewSection(account)
          configurationSection(account)
          actionsSection(account)
          deleteSection
        }
        .scrollContentBackground(.hidden)
      } else {
        ContentUnavailableView("Connection Missing", systemImage: "exclamationmark.triangle")
      }
    }
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle(account?.label ?? "Connection")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showCredentialEditor) {
      if let account, let provider {
        NavigationStack {
          ConnectionCredentialEditorView(model: model, account: account, provider: provider)
        }
      }
    }
    .sheet(isPresented: $showNameEditor) {
      if let account {
        NavigationStack {
          ConnectionNameEditorView(model: model, account: account)
        }
      }
    }
    .sheet(isPresented: $showModels) {
      NavigationStack {
        ConnectionModelsView(model: model, accountID: accountID)
      }
    }
    .sheet(isPresented: $showAdvancedEditor) {
      if let account, let provider {
        NavigationStack {
          ConnectionAdvancedEditorView(model: model, account: account, provider: provider)
        }
      }
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
      Text("The connection and its saved API key will be removed from this device. Existing chats keep their history but must be assigned another connection before sending again.")
    }
  }

  @ViewBuilder
  private func overviewSection(_ account: ProviderAccount) -> some View {
    Section {
      HStack(spacing: 14) {
        ConnectionProviderMark(definition: provider, size: 48)
        VStack(alignment: .leading, spacing: 4) {
          Text(provider?.displayName ?? account.providerID.rawValue)
            .font(.headline)
          HStack(spacing: 6) {
            let status = connectionStatus(model: model, account: account)
            Circle()
              .fill(status.isReady ? theme.accentColor : Color.secondary)
              .frame(width: 7, height: 7)
            Text(status.label)
              .font(.caption.weight(.medium))
              .foregroundStyle(theme.secondaryForegroundColor)
            if model.isDefaultAccount(account.id) {
              Text("· Default")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.accentColor)
            }
          }
        }
      }
      .padding(.vertical, 4)

      Toggle(
        "Enabled",
        isOn: Binding(
          get: { account.isEnabled },
          set: { enabled in
            Task { @MainActor in
              _ = await model.setAccountEnabled(enabled, accountID: account.id)
            }
          }
        )
      )
      .disabled(model.isBusy)

      if !model.isDefaultAccount(account.id) {
        Button("Make Default", systemImage: "checkmark.circle") {
          Task { @MainActor in
            _ = await model.setDefaultAccount(account.id)
          }
        }
        .disabled(model.isBusy || !connectionStatus(model: model, account: account).isReady)
      }
    } header: {
      Text("Connection")
    } footer: {
      if model.isDefaultAccount(account.id) {
        Text("New chats use this connection unless a project or chat selects another one.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  @ViewBuilder
  private func configurationSection(_ account: ProviderAccount) -> some View {
    Section("Configuration") {
      Button {
        showNameEditor = true
      } label: {
        LabeledContent("Name", value: account.label)
      }

      Button {
        showCredentialEditor = true
      } label: {
        LabeledContent("API Key", value: apiKeyStatus(account))
      }

      Button {
        showModels = true
      } label: {
        LabeledContent("Models") {
          VStack(alignment: .trailing, spacing: 2) {
            Text(account.defaultModelID.map {
              modelDisplayName(model: model, accountID: account.id, modelID: $0)
            } ?? "Choose model")
            .lineLimit(1)
            .foregroundStyle(theme.secondaryForegroundColor)
            Text("\(models.filter(\.isAvailable).count) available")
              .font(.caption2)
              .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
          }
        }
      }

      Button {
        showAdvancedEditor = true
      } label: {
        LabeledContent("Advanced") {
          Text(advancedSummary(account))
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
    }
    .buttonStyle(.plain)
    .listRowBackground(theme.surfaceColor)
  }

  @ViewBuilder
  private func actionsSection(_ account: ProviderAccount) -> some View {
    Section("Actions") {
      Button {
        testConnection(account)
      } label: {
        HStack {
          Label(testTitle, systemImage: testIcon)
          Spacer()
          if testState == .testing {
            ProgressView().controlSize(.small)
          }
        }
      }
      .disabled(testState == .testing || !account.isEnabled)

      Button("Refresh Models", systemImage: "arrow.clockwise") {
        Task { await model.refreshModels(accountID: account.id) }
      }
      .disabled(model.isBusy || !account.isEnabled)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var deleteSection: some View {
    Section {
      Button("Delete Connection", systemImage: "trash", role: .destructive) {
        showDelete = true
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func apiKeyStatus(_ account: ProviderAccount) -> String {
    guard let provider, connectionRequiresCredential(provider) else { return "Not required" }
    return model.credentialAccountIDs.contains(account.id) ? "Saved securely" : "Missing"
  }

  private func advancedSummary(_ account: ProviderAccount) -> String {
    if account.baseURLOverride != nil || !account.additionalHeaders.isEmpty {
      return "Customized"
    }
    if account.providerID == BuiltInProviders.openRouterID,
      account.metadata["httpReferer"]?.isEmpty == false
    {
      return "Customized"
    }
    return "Provider defaults"
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
      let selected = account.defaultModelID
        ?? models.first(where: { $0.isAvailable && !$0.isHidden })?.model.id
      let result = await model.testConnectionResult(accountID: account.id, modelID: selected)
      testState = result ? .success : .failed
    }
  }
}

private struct ConnectionNameEditorView: View {
  @Bindable var model: ProviderManagementModel
  let account: ProviderAccount

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var name: String

  init(model: ProviderManagementModel, account: ProviderAccount) {
    self.model = model
    self.account = account
    _name = State(initialValue: account.label)
  }

  var body: some View {
    Form {
      Section {
        TextField("Connection name", text: $name)
      } footer: {
        Text("Use a name that distinguishes this account when you have more than one connection to the same provider.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Connection Name")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(model.isBusy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func save() {
    var updated = account
    updated.label = name.trimmingCharacters(in: .whitespacesAndNewlines)
    Task { @MainActor in
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

private struct ConnectionCredentialEditorView: View {
  @Bindable var model: ProviderManagementModel
  let account: ProviderAccount
  let provider: ProviderDefinition

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var credential = ""
  @State private var showHelp = false

  private var hasStoredCredential: Bool {
    model.credentialAccountIDs.contains(account.id)
  }

  var body: some View {
    Form {
      if connectionRequiresCredential(provider) {
        Section {
          if hasStoredCredential {
            Label("Saved securely in Keychain", systemImage: "checkmark.shield.fill")
              .foregroundStyle(theme.secondaryForegroundColor)
          }
          SecureField(hasStoredCredential ? "New API key" : "API key", text: $credential)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("API Key")
        } footer: {
          Text(hasStoredCredential
            ? "Leave empty to keep the existing key. Enter a new key only when you want to replace it."
            : "The key is stored in Keychain and sent only to the configured provider when BYOKchat makes a request.")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)

        Section {
          Button("Where do I find my API key?", systemImage: "questionmark.circle") {
            showHelp = true
          }
        }
        .listRowBackground(theme.surfaceColor)
      } else {
        Section {
          Label("This provider does not require an API key.", systemImage: "checkmark.shield")
        }
        .listRowBackground(theme.surfaceColor)
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("API Key")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(model.isBusy || !canSave)
      }
    }
    .alert("Finding your API key", isPresented: $showHelp) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Open the \(provider.displayName) developer console, create an API key, then copy and paste it here. BYOKchat never needs your provider password.")
    }
  }

  private var canSave: Bool {
    guard connectionRequiresCredential(provider) else { return true }
    return hasStoredCredential || !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func save() {
    Task { @MainActor in
      let success = await model.updateAccount(
        account,
        newCredential: credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : credential,
        baseURL: account.baseURLOverride?.absoluteString ?? "",
        headers: account.additionalHeaders,
        metadata: account.metadata
      )
      if success { dismiss() }
    }
  }
}

struct ConnectionModelsView: View {
  @Bindable var model: ProviderManagementModel
  let accountID: ProviderAccountID

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var searchText = ""
  @State private var showHidden = false
  @State private var showManualModel = false

  private var account: ProviderAccount? {
    model.accounts.first { $0.id == accountID }
  }

  private var records: [AccountModelRecord] {
    var values = model.models(for: accountID, includeHidden: true)
    if !showHidden {
      values.removeAll(where: \.isHidden)
    }
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !query.isEmpty {
      values = values.filter {
        $0.model.displayName.localizedCaseInsensitiveContains(query)
          || $0.model.id.rawValue.localizedCaseInsensitiveContains(query)
      }
    }
    return values
  }

  var body: some View {
    List {
      if records.isEmpty {
        ContentUnavailableView(
          searchText.isEmpty ? "No Models" : "No Matching Models",
          systemImage: "cpu",
          description: Text(searchText.isEmpty
            ? "Refresh models or add a model ID manually."
            : "Try another model name or ID.")
        )
        .listRowBackground(Color.clear)
      } else {
        ForEach(records) { record in
          modelRow(record)
            .listRowBackground(theme.surfaceColor)
        }
      }

      Section {
        Button("Add Manual Model", systemImage: "plus") {
          showManualModel = true
        }
      } footer: {
        Text("Manual model IDs remain available even when the provider does not expose model discovery.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Models")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search models")
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button("Refresh", systemImage: "arrow.clockwise") {
          Task { await model.refreshModels(accountID: accountID) }
        }
        .disabled(model.isBusy)

        Menu {
          Toggle("Show Hidden Models", isOn: $showHidden)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Model options")
      }
    }
    .sheet(isPresented: $showManualModel) {
      ConnectionManualModelView(model: model, accountID: accountID)
    }
  }

  @ViewBuilder
  private func modelRow(_ record: AccountModelRecord) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Button {
        guard record.isAvailable, !record.isHidden else { return }
        Task { await model.setDefaultModel(record.model.id, accountID: accountID) }
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(record.model.displayName)
              .font(.body.weight(.medium))
            if account?.defaultModelID == record.model.id {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.accentColor)
            }
          }
          Text(record.model.id.rawValue)
            .font(.caption.monospaced())
            .foregroundStyle(theme.secondaryForegroundColor)
            .lineLimit(2)
          HStack(spacing: 7) {
            if record.isManual { Text("Manual") }
            if !record.isAvailable { Text("Unavailable").foregroundStyle(.orange) }
            if record.isHidden { Text("Hidden") }
            if let context = record.model.contextWindow {
              Text("\(context.formatted(.number.notation(.compactName))) context")
            }
          }
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor.opacity(0.78))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!record.isAvailable || record.isHidden)

      Button {
        Task {
          await model.setFavorite(
            !record.isFavorite,
            modelID: record.model.id,
            accountID: accountID
          )
        }
      } label: {
        Image(systemName: record.isFavorite ? "star.fill" : "star")
          .frame(width: 36, height: 36)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(record.isFavorite ? "Remove favorite" : "Add favorite")
    }
    .swipeActions(edge: .trailing) {
      Button(record.isHidden ? "Unhide" : "Hide") {
        Task {
          await model.setHidden(
            !record.isHidden,
            modelID: record.model.id,
            accountID: accountID
          )
        }
      }
      .tint(record.isHidden ? .accentColor : .secondary)
    }
  }
}

private struct ConnectionAdvancedEditorView: View {
  @Bindable var model: ProviderManagementModel
  let account: ProviderAccount
  let provider: ProviderDefinition

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var baseURL: String
  @State private var headersText: String
  @State private var appTitle: String
  @State private var httpReferer: String
  @State private var validationMessage: String?

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
        Text("Leave empty to use \(provider.defaultBaseURL.absoluteString). HTTP is accepted only for private-network custom providers.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

      if account.providerID == BuiltInProviders.openRouterID {
        Section("OpenRouter") {
          TextField("App title", text: $appTitle)
          TextField("HTTP referer", text: $httpReferer)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        }
        .listRowBackground(theme.surfaceColor)
      }

      Section {
        TextEditor(text: $headersText)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 120)
        if let validationMessage {
          Label(validationMessage, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      } header: {
        Text("Additional Headers")
      } footer: {
        Text("One header per line as Name: Value. Authentication and transport-level headers are managed by BYOKchat.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
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
    let parsed: [String: String]
    do {
      parsed = try parseHeadersStrict(headersText)
      validationMessage = nil
    } catch {
      validationMessage = error.localizedDescription
      return
    }

    var metadata = account.metadata
    if account.providerID == BuiltInProviders.openRouterID {
      let title = appTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      let referer = httpReferer.trimmingCharacters(in: .whitespacesAndNewlines)
      if title.isEmpty { metadata.removeValue(forKey: "appTitle") } else { metadata["appTitle"] = title }
      if referer.isEmpty { metadata.removeValue(forKey: "httpReferer") } else { metadata["httpReferer"] = referer }
    }

    Task { @MainActor in
      let success = await model.updateAccount(
        account,
        newCredential: nil,
        baseURL: baseURL,
        headers: parsed,
        metadata: metadata
      )
      if success { dismiss() }
    }
  }
}

struct ConnectionManualModelView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: ProviderManagementModel
  let accountID: ProviderAccountID
  @State private var modelID = ""
  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    NavigationStack {
      Form {
        TextField("Model ID", text: $modelID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .listRowBackground(theme.surfaceColor)
      }
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
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

private struct HeaderParseError: LocalizedError {
  let line: Int
  var errorDescription: String? {
    "Header line \(line) must use Name: Value."
  }
}

private func parseHeadersStrict(_ text: String) throws -> [String: String] {
  var values: [String: String] = [:]
  let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
  for (offset, rawLine) in lines.enumerated() {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { continue }
    guard let colon = line.firstIndex(of: ":") else {
      throw HeaderParseError(line: offset + 1)
    }
    let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !value.isEmpty else {
      throw HeaderParseError(line: offset + 1)
    }
    values[name] = value
  }
  return values
}
