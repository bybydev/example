import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct ConnectionFlowView: View {
  @Bindable var model: ProviderManagementModel
  let initialProviderID: ProviderID?
  let completionTitle: String
  let onFinished: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var page = 0
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
    guard let selectedProviderID else { return nil }
    return model.provider(for: selectedProviderID)
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
        ConnectionProgressView(current: page, count: 4)
          .padding(.top, 8)
          .padding(.bottom, 8)

        TabView(selection: $page) {
          providerStep.tag(0)
          credentialStep.tag(1)
          preferencesStep.tag(2)
          completionStep.tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: page) { oldValue, newValue in
          if newValue > highestUnlockedPage || newValue < minimumAllowedPage {
            page = oldValue
          }
        }
      }
    }
    .interactiveDismissDisabled(isAdvancing || (createdAccountID != nil && page < 3))
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
        CustomProviderEditorView(model: model)
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
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                }
              }
              .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
              .padding(14)
              .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                  .stroke(Color.primary.opacity(0.08), lineWidth: 1)
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
          subtitle: provider.map { credentialSubtitle($0) } ?? "Add the credentials for this connection."
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
      VStack(spacing: 22) {
        ConnectionStepHeader(
          definition: provider,
          title: "Make it yours",
          subtitle: "Give this connection a name and choose the model BYOKchat should use by default."
        )
        ConnectionPreferencesFields(
          connectionName: $connectionName,
          selectedModelID: $selectedModelID,
          manualModelID: $manualModelID,
          models: models
        )
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 20)
    }
  }

  private var completionStep: some View {
    VStack(spacing: 20) {
      Spacer()
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 64, weight: .medium))
        .foregroundStyle(theme.accentColor)
      Text("You're connected")
        .font(.system(size: 30, weight: .semibold))
      if let provider {
        Text(provider.displayName)
          .font(.headline)
      }
      Text(connectionName)
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
      if let selectedModelID {
        Text(modelDisplayName(model: model, accountID: createdAccountID, modelID: selectedModelID))
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      Text("BYOKchat is ready to use this connection.")
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
      Spacer()
    }
    .multilineTextAlignment(.center)
    .padding(24)
  }

  private var bottomAction: some View {
    VStack(spacing: 0) {
      Divider().opacity(0.4)
      Button {
        primaryAction()
      } label: {
        HStack(spacing: 8) {
          if isAdvancing { ProgressView().controlSize(.small) }
          Text(primaryActionTitle)
            .font(.system(size: 16, weight: .semibold))
          if page < 3 { Image(systemName: "arrow.right") }
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

  private var primaryActionTitle: String {
    switch page {
    case 1: "Connect"
    case 2: "Continue"
    case 3: completionTitle
    default: "Continue"
    }
  }

  private var canPerformPrimaryAction: Bool {
    switch page {
    case 1:
      guard let provider else { return false }
      return !connectionRequiresCredential(provider) || !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case 2:
      let nameReady = !connectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      return nameReady && (selectedModelID != nil || !manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    case 3:
      return true
    default:
      return false
    }
  }

  private func primaryAction() {
    switch page {
    case 1:
      connectAndAdvance()
    case 2:
      savePreferencesAndAdvance()
    case 3:
      dismiss()
      onFinished?()
    default:
      break
    }
  }

  private func connectAndAdvance() {
    guard let provider else { return }
    isAdvancing = true
    Task { @MainActor in
      defer { isAdvancing = false }
      let metadata = connectionMetadata()
      let accountID: ProviderAccountID?
      if let existingID = createdAccountID,
        var account = model.accounts.first(where: { $0.id == existingID })
      {
        account.label = connectionName
        let success = await model.updateAccount(
          account,
          newCredential: credential.isEmpty ? nil : credential,
          baseURL: baseURL,
          headers: parseHeaders(headersText),
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
          headers: parseHeaders(headersText),
          metadata: metadata
        )
      }
      guard let accountID else { return }
      createdAccountID = accountID

      if provider.modelsPath != nil {
        guard await model.refreshModelsResult(accountID: accountID) else { return }
      }

      let available = model.models(for: accountID).filter(\.isAvailable)
      if selectedModelID == nil {
        selectedModelID = model.accounts.first(where: { $0.id == accountID })?.defaultModelID
          ?? available.first?.model.id
      }

      if let modelID = selectedModelID {
        guard await model.testConnectionResult(accountID: accountID, modelID: modelID) else { return }
      } else if provider.modelsPath != nil {
        model.errorMessage = "No available models were returned for this connection."
        return
      }

      highestUnlockedPage = max(highestUnlockedPage, 2)
      withAnimation { page = 2 }
    }
  }

  private func savePreferencesAndAdvance() {
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
      highestUnlockedPage = 3
      withAnimation { page = 3 }
    }
  }

  private func cancel() {
    if let createdAccountID, page < 3 {
      Task { @MainActor in
        await model.deleteAccount(createdAccountID)
        dismiss()
      }
    } else {
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
