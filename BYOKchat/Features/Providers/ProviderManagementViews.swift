import BYOKchatProviderCore
import SwiftUI

struct ProviderRootView: View {
  @Bindable var model: ProviderManagementModel

  var body: some View {
    TabView {
      NavigationStack {
        ProviderListView(model: model)
      }
      .tabItem { Label("Providers", systemImage: "key.horizontal") }

      NavigationStack {
        ProviderConsoleView(model: model)
      }
      .tabItem { Label("Console", systemImage: "bubble.left.and.text.bubble.right") }
    }
    .task { await model.load() }
    .overlay(alignment: .top) {
      if model.isBusy {
        ProgressView()
          .padding(10)
          .background(.regularMaterial, in: Capsule())
          .padding(.top, 8)
      }
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
}

struct ProviderListView: View {
  @Bindable var model: ProviderManagementModel
  @State private var showCustomProvider = false

  var body: some View {
    List {
      if !model.accounts.isEmpty {
        Section("Configured Accounts") {
          ForEach(model.accounts) { account in
            NavigationLink {
              AccountDetailView(model: model, accountID: account.id)
            } label: {
              AccountRow(model: model, account: account)
            }
          }
        }
      }

      Section("Providers") {
        ForEach(model.definitions) { definition in
          NavigationLink {
            ProviderDetailView(model: model, providerID: definition.id)
          } label: {
            HStack {
              ProviderMark(definition: definition)
              VStack(alignment: .leading, spacing: 3) {
                Text(definition.displayName)
                Text(providerSummary(definition))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              let count = model.accounts(for: definition.id).count
              if count > 0 {
                Text("\(count)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      Section {
        Button {
          showCustomProvider = true
        } label: {
          Label("Add Custom Provider", systemImage: "plus.circle")
        }
      } footer: {
        Text(
          "Custom providers use an OpenAI-compatible chat-completions API and remain fully local to this device."
        )
      }
    }
    .navigationTitle("Providers")
    .refreshable { await model.load() }
    .sheet(isPresented: $showCustomProvider) {
      NavigationStack {
        CustomProviderEditorView(model: model)
      }
    }
  }

  private func providerSummary(_ definition: ProviderDefinition) -> String {
    definition.isBuiltIn
      ? "Built in · \(definition.behavior.rawValue)" : definition.defaultBaseURL.host ?? "Custom"
  }
}

private struct ProviderMark: View {
  let definition: ProviderDefinition
  var body: some View {
    Image(systemName: definition.isBuiltIn ? "sparkles" : "server.rack")
      .frame(width: 32, height: 32)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct AccountRow: View {
  let model: ProviderManagementModel
  let account: ProviderAccount
  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(account.label)
        HStack(spacing: 5) {
          Text(model.provider(for: account.providerID)?.displayName ?? account.providerID.rawValue)
          if let modelID = account.defaultModelID {
            Text("·")
            Text(modelID.rawValue)
              .lineLimit(1)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Image(systemName: model.credentialAccountIDs.contains(account.id) ? "key.fill" : "key.slash")
        .foregroundStyle(model.credentialAccountIDs.contains(account.id) ? .primary : .secondary)
    }
  }
}

struct ProviderDetailView: View {
  @Bindable var model: ProviderManagementModel
  let providerID: ProviderID
  @State private var showAddAccount = false
  @State private var showDeleteConfirmation = false

  private var definition: ProviderDefinition? { model.provider(for: providerID) }

  var body: some View {
    List {
      if let definition {
        Section("Provider") {
          LabeledContent("API", value: definition.apiFamily.rawValue)
          LabeledContent("Base URL", value: definition.defaultBaseURL.absoluteString)
          LabeledContent("Authentication", value: authenticationName(definition.authentication))
        }
      }

      Section("Accounts") {
        let accounts = model.accounts(for: providerID)
        if accounts.isEmpty {
          ContentUnavailableView(
            "No Accounts", systemImage: "key",
            description: Text("Add an API account to use this provider."))
        } else {
          ForEach(accounts) { account in
            NavigationLink {
              AccountDetailView(model: model, accountID: account.id)
            } label: {
              AccountRow(model: model, account: account)
            }
          }
        }
        Button("Add Account", systemImage: "plus") { showAddAccount = true }
      }

      if definition?.isBuiltIn == false {
        Section {
          Button("Delete Custom Provider", role: .destructive) { showDeleteConfirmation = true }
        } footer: {
          Text("Delete all accounts for this provider first.")
        }
      }
    }
    .navigationTitle(definition?.displayName ?? providerID.rawValue)
    .sheet(isPresented: $showAddAccount) {
      NavigationStack {
        AccountEditorView(model: model, providerID: providerID)
      }
    }
    .confirmationDialog("Delete custom provider?", isPresented: $showDeleteConfirmation) {
      Button("Delete", role: .destructive) {
        Task { await model.deleteCustomProvider(providerID) }
      }
    }
  }

  private func authenticationName(_ value: ProviderAuthentication) -> String {
    switch value {
    case .bearer: "Bearer token"
    case .header(let name): name
    case .none: "None"
    }
  }
}

struct AccountEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: ProviderManagementModel
  let providerID: ProviderID
  let existingAccount: ProviderAccount?

  @State private var label: String
  @State private var credential = ""
  @State private var baseURL: String
  @State private var defaultModel: String
  @State private var headersText: String
  @State private var appTitle: String
  @State private var httpReferer: String

  init(
    model: ProviderManagementModel,
    providerID: ProviderID,
    existingAccount: ProviderAccount? = nil
  ) {
    self.model = model
    self.providerID = providerID
    self.existingAccount = existingAccount
    _label = State(initialValue: existingAccount?.label ?? "Personal")
    _baseURL = State(initialValue: existingAccount?.baseURLOverride?.absoluteString ?? "")
    _defaultModel = State(initialValue: existingAccount?.defaultModelID?.rawValue ?? "")
    _headersText = State(
      initialValue: Self.serializeHeaders(existingAccount?.additionalHeaders ?? [:]))
    _appTitle = State(initialValue: existingAccount?.metadata["appTitle"] ?? "BYOKchat")
    _httpReferer = State(initialValue: existingAccount?.metadata["httpReferer"] ?? "")
  }

  var body: some View {
    Form {
      Section("Account") {
        TextField("Label", text: $label)
        SecureField(
          existingAccount == nil ? "API key" : "New API key (optional)", text: $credential
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        TextField("Default model", text: $defaultModel)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }

      Section("Endpoint Override") {
        TextField("Use provider default", text: $baseURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
      } footer: {
        Text("Leave empty to use the provider's built-in HTTPS endpoint.")
      }

      if providerID == BuiltInProviders.openRouterID {
        Section("OpenRouter") {
          TextField("App title", text: $appTitle)
          TextField("HTTP referer", text: $httpReferer)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        }
      }

      Section("Additional Headers") {
        TextEditor(text: $headersText)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 100)
      } footer: {
        Text(
          "One header per line: Name: Value. Authorization and transport-level headers are blocked."
        )
      }
    }
    .navigationTitle(existingAccount == nil ? "Add Account" : "Edit Account")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func save() {
    let headers = Self.parseHeaders(headersText)
    var metadata: [String: String] = [:]
    if !appTitle.isEmpty { metadata["appTitle"] = appTitle }
    if !httpReferer.isEmpty { metadata["httpReferer"] = httpReferer }

    Task {
      let success: Bool
      if var account = existingAccount {
        account.label = label
        account.defaultModelID = defaultModel.isEmpty ? nil : ModelID(rawValue: defaultModel)
        success = await model.updateAccount(
          account,
          newCredential: credential.isEmpty ? nil : credential,
          baseURL: baseURL,
          headers: headers,
          metadata: metadata
        )
      } else {
        success = await model.createAccount(
          providerID: providerID,
          label: label,
          credential: credential,
          baseURL: baseURL,
          defaultModel: defaultModel,
          headers: headers,
          metadata: metadata
        )
      }
      if success { dismiss() }
    }
  }

  private static func parseHeaders(_ text: String) -> [String: String] {
    var values: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty, !value.isEmpty { values[name] = value }
    }
    return values
  }

  private static func serializeHeaders(_ headers: [String: String]) -> String {
    headers.keys.sorted().map { "\($0): \(headers[$0]!)" }.joined(separator: "\n")
  }
}

struct AccountDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: ProviderManagementModel
  let accountID: ProviderAccountID

  @State private var showEdit = false
  @State private var showManualModel = false
  @State private var showDelete = false

  private var account: ProviderAccount? { model.accounts.first { $0.id == accountID } }
  private var models: [AccountModelRecord] { model.models(for: accountID) }

  var body: some View {
    List {
      if let account {
        Section("Account") {
          LabeledContent(
            "Provider",
            value: model.provider(for: account.providerID)?.displayName
              ?? account.providerID.rawValue)
          LabeledContent(
            "Credential",
            value: model.credentialAccountIDs.contains(account.id) ? "Saved" : "Missing")
          if let modelID = account.defaultModelID {
            LabeledContent("Default model", value: modelID.rawValue)
          }
          if let override = account.baseURLOverride {
            LabeledContent("Endpoint", value: override.absoluteString)
          }
        }

        Section("Actions") {
          Button("Test Connection", systemImage: "bolt.horizontal.circle") {
            Task {
              await model.testConnection(
                accountID: account.id, modelID: account.defaultModelID ?? models.first?.model.id)
            }
          }
          Button("Refresh Models", systemImage: "arrow.clockwise") {
            Task { await model.refreshModels(accountID: account.id) }
          }
          Button("Add Manual Model", systemImage: "plus") { showManualModel = true }
        }

        Section("Models") {
          if models.isEmpty {
            Text("Refresh models or add one manually.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(models) { record in
              ModelRow(model: model, account: account, record: record)
            }
          }
        }

        Section {
          Button("Delete Account", role: .destructive) { showDelete = true }
        }
      } else {
        ContentUnavailableView("Account Missing", systemImage: "exclamationmark.triangle")
      }
    }
    .navigationTitle(account?.label ?? "Account")
    .toolbar {
      if account != nil {
        ToolbarItem(placement: .primaryAction) {
          Button("Edit") { showEdit = true }
        }
      }
    }
    .sheet(isPresented: $showEdit) {
      if let account {
        NavigationStack {
          AccountEditorView(model: model, providerID: account.providerID, existingAccount: account)
        }
      }
    }
    .sheet(isPresented: $showManualModel) {
      ManualModelView(model: model, accountID: accountID)
    }
    .confirmationDialog("Delete this account and its saved key?", isPresented: $showDelete) {
      Button("Delete", role: .destructive) {
        Task {
          await model.deleteAccount(accountID)
          dismiss()
        }
      }
    }
  }
}

private struct ModelRow: View {
  let model: ProviderManagementModel
  let account: ProviderAccount
  let record: AccountModelRecord

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 3) {
        Text(record.model.displayName)
        Text(record.model.id.rawValue)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        if !record.isAvailable {
          Text("Not returned by latest refresh")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button {
        Task {
          await model.setFavorite(
            !record.isFavorite, modelID: record.model.id, accountID: account.id)
        }
      } label: {
        Image(systemName: record.isFavorite ? "star.fill" : "star")
      }
      .buttonStyle(.plain)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      Task { await model.setDefaultModel(record.model.id, accountID: account.id) }
    }
    .swipeActions(edge: .trailing) {
      Button("Hide") {
        Task { await model.setHidden(true, modelID: record.model.id, accountID: account.id) }
      }
    }
    .overlay(alignment: .topTrailing) {
      if account.defaultModelID == record.model.id {
        Image(systemName: "checkmark.circle.fill")
          .font(.caption)
          .offset(x: 2, y: -5)
      }
    }
  }
}

private struct ManualModelView: View {
  @Environment(\.dismiss) private var dismiss
  let model: ProviderManagementModel
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
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            Task {
              if await model.addManualModel(modelID, accountID: accountID) { dismiss() }
            }
          }
          .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }
}

struct CustomProviderEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: ProviderManagementModel

  @State private var providerID = "custom."
  @State private var name = ""
  @State private var baseURL = ""
  @State private var chatPath = "/chat/completions"
  @State private var modelsPath = "/models"
  @State private var authentication: AuthenticationChoice = .bearer
  @State private var headerName = "X-API-Key"
  @State private var seedModels = ""

  var body: some View {
    Form {
      Section("Identity") {
        TextField("Provider ID", text: $providerID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Display name", text: $name)
      }

      Section("Endpoint") {
        TextField("https://example.com/v1", text: $baseURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        TextField("Chat path", text: $chatPath)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Models path (optional)", text: $modelsPath)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }

      Section("Authentication") {
        Picker("Type", selection: $authentication) {
          ForEach(AuthenticationChoice.allCases) { choice in
            Text(choice.title).tag(choice)
          }
        }
        if authentication == .header {
          TextField("Header name", text: $headerName)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
      }

      Section("Seed Models") {
        TextEditor(text: $seedModels)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 100)
      } footer: {
        Text(
          "One model ID per line. These remain available when the provider does not expose model discovery."
        )
      }
    }
    .navigationTitle("Custom Provider")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(providerID.isEmpty || name.isEmpty || baseURL.isEmpty)
      }
    }
  }

  private func save() {
    let auth: ProviderAuthentication =
      switch authentication {
      case .bearer: .bearer
      case .header: .header(name: headerName)
      case .none: .none
      }
    let seeds =
      seedModels
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    Task {
      let success = await model.createCustomProvider(
        id: providerID,
        name: name,
        baseURL: baseURL,
        chatPath: chatPath,
        modelsPath: modelsPath,
        authentication: auth,
        seedModels: seeds
      )
      if success { dismiss() }
    }
  }
}

private enum AuthenticationChoice: String, CaseIterable, Identifiable {
  case bearer
  case header
  case none
  var id: Self { self }
  var title: String {
    switch self {
    case .bearer: "Bearer token"
    case .header: "Named header"
    case .none: "No authentication"
    }
  }
}
