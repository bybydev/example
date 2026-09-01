import BYOKchatProviderCore
import SwiftUI

struct ConnectionFlowView: View {
  @Bindable var model: ProviderManagementModel
  let initialProviderID: ProviderID?
  let completionTitle: String
  let onFinished: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var page: Int
  @State private var selectedProviderID: ProviderID?
  @State private var connectionName = "Personal"
  @State private var credential = ""
  @State private var baseURL = ""
  @State private var headersText = ""
  @State private var appTitle = "BYOKchat"
  @State private var httpReferer = ""
  @State private var selectedModelID: ModelID?
  @State private var manualModelID = ""
  @State private var createdAccountID: ProviderAccountID?
  @State private var highestUnlockedPage: Int
  @State private var isAdvancing = false
  @State private var showCustomProvider = false
  @State private var discoveryWarning: String?

  init(
    model: ProviderManagementModel,
    initialProviderID: ProviderID? = nil,
    completionTitle: String = "Done",
    onFinished: (() -> Void)? = nil
  ) {
    self.model = model
    self.initialProviderID = initialProviderID
    self.completionTitle = completionTitle
    self.onFinished = onFinished
    _selectedProviderID = State(initialValue: initialProviderID)
    let startingPage = initialProviderID == nil ? 0 : 1
    _page = State(initialValue: startingPage)
    _highestUnlockedPage = State(initialValue: startingPage)
  }

  private var provider: ProviderDefinition? {
    selectedProviderID.flatMap { model.provider(for: $0) }
  }

  private var models: [AccountModelRecord] {
    guard let createdAccountID else { return [] }
    return model.models(for: createdAccountID).filter(\.isAvailable)
  }

  private var minimumAllowedPage: Int {
    createdAccountID == nil ? 0 : 1
  }

  var body: some View {
    ZStack {
      theme.backgroundColor.ignoresSafeArea()
      VStack(spacing: 0) {
        ConnectionProgressView(current: page, count: 3)
          .padding(.top, 8)
          .padding(.bottom, 8)

        TabView(selection: $page) {
          providerStep.tag(0)
          credentialStep.tag(1)
          preferencesStep.tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: page) { oldValue, newValue in
          if newValue > highestUnlockedPage || newValue < minimumAllowedPage {
            page = oldValue
          }
        }
      }
    }
    .interactiveDismissDisabled(isAdvancing || createdAccountID != nil)
    .navigationTitle("Add Connection")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { cancel() }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if page > 0 {
        bottomAction
      }
    }
    .sheet(isPresented: $showCustomProvider) {
      NavigationStack {
        CustomProviderEditorView(model: model) { providerID in
          selectedProviderID = providerID
          highestUnlockedPage = max(highestUnlockedPage, 1)
          withAnimation { page = 1 }
        }
      }
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

  private var providerStep: some View {
    ScrollView {
      VStack(spacing: 22) {
        ConnectionStepHeader(
          icon: "sparkles",
          title: "Choose your AI",
          subtitle: "Pick the provider you want to connect. You can add more connections later."
        )

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
          ForEach(model.definitions) { definition in
            Button {
              selectedProviderID = definition.id
              highestUnlockedPage = max(highestUnlockedPage, 1)
              withAnimation { page = 1 }
            } label: {
              VStack(alignment: .leading, spacing: 12) {
                ConnectionProviderMark(definition: definition, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                  Text(definition.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                  Text(providerDescription(definition))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                }
              }
              .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
              .padding(14)
              .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                  .stroke(theme.borderColor, lineWidth: 1)
              }
            }
            .buttonStyle(.plain)
          }
        }

        Button {
          showCustomProvider = true
        } label: {
          Label("Add Custom Provider", systemImage: "server.rack")
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
        }
        .buttonStyle(.bordered)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 20)
    }
  }

  private var credentialStep: some View {
    ScrollView {
      VStack(spacing: 22) {
        ConnectionStepHeader(
          definition: provider,
          title: provider.map { "Connect \($0.displayName)" } ?? "Connect provider",
          subtitle: provider.map { credentialSubtitle($0) }
            ?? "Add the credentials for this connection."
        )
        if let provider {
          ConnectionCredentialFields(
            provider: provider,
            hasStoredCredential: false,
            credential: $credential,
            baseURL: $baseURL,
            headersText: $headersText,
            appTitle: $appTitle,
            httpReferer: $httpReferer
          )
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 20)
    }
  }

  private var preferencesStep: some View {
    ScrollView {
      VStack(spacing: 18) {
        ConnectionStepHeader(
          definition: provider,
          title: "Choose a model",
          subtitle: "Name this connection and choose the model new chats should use by default."
        )

        if let discoveryWarning {
          Label(discoveryWarning, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 14))
        }

        ConnectionPreferencesFields(
          connectionName: $connectionName,
          selectedModelID: $selectedModelID,
          manualModelID: $manualModelID,
          models: models
        )

        Text("BYOKchat verifies the selected model before saving this connection.")
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor.opacity(0.75))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 12)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 20)
    }
  }

  private var bottomAction: some View {
    VStack(spacing: 0) {
      Divider().opacity(0.4)
      Button {
        primaryAction()
      } label: {
        HStack(spacing: 8) {
          if isAdvancing { ProgressView().controlSize(.small) }
          Text(page == 1 ? "Continue" : completionTitle)
            .font(.system(size: 16, weight: .semibold))
          if page == 1 { Image(systemName: "arrow.right") }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
      }
      .buttonStyle(.borderedProminent)
      .tint(theme.accentColor)
      .disabled(isAdvancing || !canPerformPrimaryAction)
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      .background(.regularMaterial)
    }
  }

  private var canPerformPrimaryAction: Bool {
    switch page {
    case 1:
      guard let provider else { return false }
      return !connectionRequiresCredential(provider)
        || !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case 2:
      let nameReady = !connectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let modelReady = selectedModelID != nil
        || !manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      return nameReady && modelReady
    default:
      return false
    }
  }

  private func primaryAction() {
    switch page {
    case 1: saveCredentialsAndDiscoverModels()
    case 2: verifyAndFinish()
    default: break
    }
  }

  private func saveCredentialsAndDiscoverModels() {
    guard let provider else { return }
    isAdvancing = true
    discoveryWarning = nil

    Task { @MainActor in
      defer { isAdvancing = false }
      let metadata = connectionMetadata()
      let headers: [String: String]
      do {
        headers = try parseSetupHeaders(headersText)
      } catch {
        model.errorMessage = error.localizedDescription
        return
      }

      let accountID: ProviderAccountID?
      if let existingID = createdAccountID,
        var account = model.accounts.first(where: { $0.id == existingID })
      {
        account.label = connectionName
        let success = await model.updateAccount(
          account,
          newCredential: credential.isEmpty ? nil : credential,
          baseURL: baseURL,
          headers: headers,
          metadata: metadata
        )
        accountID = success ? existingID : nil
      } else {
        accountID = await model.createConnection(
          providerID: provider.id,
          label: connectionName,
          credential: credential,
          baseURL: baseURL,
          defaultModel: "",
          headers: headers,
          metadata: metadata
        )
      }
      guard let accountID else { return }
      createdAccountID = accountID

      if provider.modelsPath != nil {
        let refreshed = await model.refreshModelsResult(accountID: accountID)
        if !refreshed {
          discoveryWarning = model.errorMessage
            ?? "Model discovery failed. Enter a model ID manually to continue."
          model.errorMessage = nil
        }
      }

      let available = model.models(for: accountID).filter(\.isAvailable)
      if selectedModelID == nil {
        selectedModelID = model.accounts.first(where: { $0.id == accountID })?.defaultModelID
          ?? available.first?.model.id
      }

      highestUnlockedPage = 2
      withAnimation { page = 2 }
    }
  }

  private func verifyAndFinish() {
    guard let accountID = createdAccountID,
      var account = model.accounts.first(where: { $0.id == accountID })
    else { return }

    isAdvancing = true
    Task { @MainActor in
      defer { isAdvancing = false }

      let trimmedManual = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
      if selectedModelID == nil, !trimmedManual.isEmpty {
        guard await model.addManualModel(trimmedManual, accountID: accountID) else { return }
        selectedModelID = ModelID(rawValue: trimmedManual)
      }
      guard let selectedModelID else { return }

      account.label = connectionName.trimmingCharacters(in: .whitespacesAndNewlines)
      account.defaultModelID = selectedModelID
      let success = await model.updateAccount(
        account,
        newCredential: nil,
        baseURL: account.baseURLOverride?.absoluteString ?? "",
        headers: account.additionalHeaders,
        metadata: account.metadata
      )
      guard success else { return }

      guard await model.testConnectionResult(accountID: accountID, modelID: selectedModelID) else {
        return
      }

      dismiss()
      onFinished?()
    }
  }

  private func cancel() {
    guard let createdAccountID else {
      dismiss()
      return
    }
    Task { @MainActor in
      await model.deleteAccount(createdAccountID)
      dismiss()
    }
  }

  private func connectionMetadata() -> [String: String] {
    guard selectedProviderID == BuiltInProviders.openRouterID else { return [:] }
    var metadata: [String: String] = [:]
    let title = appTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let referer = httpReferer.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty { metadata["appTitle"] = title }
    if !referer.isEmpty { metadata["httpReferer"] = referer }
    return metadata
  }
}

private struct SetupHeaderParseError: LocalizedError {
  let line: Int
  var errorDescription: String? { "Header line \(line) must use Name: Value." }
}

private func parseSetupHeaders(_ text: String) throws -> [String: String] {
  var values: [String: String] = [:]
  let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
  for (offset, rawLine) in lines.enumerated() {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { continue }
    guard let colon = line.firstIndex(of: ":") else {
      throw SetupHeaderParseError(line: offset + 1)
    }
    let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !value.isEmpty else {
      throw SetupHeaderParseError(line: offset + 1)
    }
    values[name] = value
  }
  return values
}
