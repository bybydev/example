import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// One editor for every provider account, create and edit. Fields are
/// conditioned on the account's (or prospective) `ProviderKind`: built-in
/// kinds hide wire configuration, `.openAICompatible` accounts expose auth and
/// paths in both create and edit. Nothing is persisted until Save/Done.
struct ConnectionEditorView: View {
  /// What a presenting surface wants fixed or focused.
  enum FocusRequest: Hashable {
    case apiKey
    case model
  }

  @Bindable var model: ProviderManagementModel
  /// nil = create mode. Otherwise the account being edited; its kind and
  /// provider identity are locked.
  let existing: ProviderAccount?
  /// Preselected kind in create mode (e.g. deep-links from an empty chat).
  let initialKind: ProviderKind?
  let focus: FocusRequest?
  let onFinished: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @FocusState private var focusedField: FocusRequest?

  // Provider & custom wire state
  @State private var selectedKind: ProviderKind
  @State private var customAuth: AuthenticationChoice = .bearer
  @State private var customHeaderName = "X-API-Key"
  @State private var customChatPath = "/chat/completions"
  @State private var customModelsPath = "/models"

  // Shared field state
  @State private var label = ""
  @State private var isEnabled = true
  @State private var credential = ""
  @State private var isDraftCredentialVisible = false
  @State private var baseURL = ""
  @State private var headersText = ""
  @State private var appTitle = ""
  @State private var httpReferer = ""
  @State private var isAdvancedExpanded = false
  @State private var selectedModelID: ModelID?
  @State private var manualModelID = ""
  @State private var discoveredModels: [ProviderModel]? = nil
  @State private var manualModels: [ProviderModel] = []
  /// Staged until the editor's Done; Cancel leaves persisted models intact.
  @State private var removedManualModelIDs: Set<ModelID> = []
  @State private var discoveryTask: Task<Void, Never>?
  @State private var discoveryID: UUID?
  @State private var isDiscoveryRunning = false
  @State private var discoveryWarning: String?
  @State private var connectionTestState: ConnectionTestState = .idle
  @State private var showDelete = false
  @State private var isSaving = false
  @State private var replaceCredential = false
  @State private var clearCredential = false
  @State private var isDirty = false
  @State private var isRevealingCredential = false
  @State private var revealedCredential: String?
  @State private var revealFailed = false
  /// False until the user edits the name field; while false, the name
  /// pre-fills/updates with the provider-named suggestion.
  @State private var didEditName = false
  @State private var isApplyingSuggestedLabel = false

  init(
    model: ProviderManagementModel,
    existing: ProviderAccount? = nil,
    initialKind: ProviderKind? = nil,
    focus: FocusRequest? = nil,
    onFinished: (() -> Void)? = nil
  ) {
    self.model = model
    self.existing = existing
    self.initialKind = initialKind
    self.focus = focus
    self.onFinished = onFinished
    _selectedKind = State(
      initialValue: existing?.kind ?? initialKind ?? .anthropic)
    if let existing {
      _label = State(initialValue: existing.label)
      _isEnabled = State(initialValue: existing.isEnabled)
      _baseURL = State(initialValue: existing.baseURLOverride?.absoluteString ?? "")
      _headersText = State(initialValue: serializeHeaders(existing.additionalHeaders))
      _selectedModelID = State(initialValue: existing.defaultModelID)
      _appTitle = State(initialValue: existing.metadata["appTitle"] ?? "")
      _httpReferer = State(initialValue: existing.metadata["httpReferer"] ?? "")
      if existing.kind == .openAICompatible {
        let definition = existing.definition
        switch definition.authentication {
        case .bearer:
          _customAuth = State(initialValue: .bearer)
        case .header(let name):
          _customAuth = State(initialValue: .header)
          _customHeaderName = State(initialValue: name)
        case .none:
          _customAuth = State(initialValue: .none)
        }
        _customChatPath = State(initialValue: definition.chatCompletionsPath)
        _customModelsPath = State(initialValue: definition.modelsPath ?? "")
      }
      let hasEndpointOverride =
        !existing.kind.isLocalServer && existing.kind != .openAICompatible
        && existing.baseURLOverride != nil
      let hasHeaders = !existing.additionalHeaders.isEmpty
      let hasOpenRouterMeta =
        !(existing.metadata["appTitle"] ?? "").isEmpty
        || !(existing.metadata["httpReferer"] ?? "").isEmpty
      _isAdvancedExpanded = State(
        initialValue: hasEndpointOverride || hasHeaders || hasOpenRouterMeta)
    } else {
      let initial = initialKind ?? .anthropic
      // Built-in cloud providers inherit `kind.defaultEndpoint` when left empty
      // so we don't persist a redundant `baseURLOverride`.
      _baseURL = State(initialValue: "")
      _selectedModelID = State(initialValue: initial.seedModels.first?.id)
    }
  }

  private var isCreate: Bool { existing == nil }

  private var currentAccount: ProviderAccount? {
    guard let existing else { return nil }
    return model.accounts.first { $0.id == existing.id } ?? existing
  }

  private var kind: ProviderKind { existing?.kind ?? selectedKind }

  private var isCustom: Bool { kind == .openAICompatible }

  private var isLocalServer: Bool { kind.isLocalServer }

  private var showsServerSection: Bool { isLocalServer || isCustom }

  private var draftAuthentication: ProviderAuthentication {
    switch customAuth {
    case .bearer: .bearer
    case .header: .header(name: customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines))
    case .none: .none
    }
  }

  /// For built-in kinds in edit mode, the account's derived definition supplies
  /// fixed wire defaults; for `.openAICompatible` (create or edit) and create
  /// mode, it is built from the live form fields.
  private var draftDefinition: ProviderDefinition {
    if let existing, !isCustom { return existing.definition }
    let endpoint = resolvedDraftEndpoint
    let chatPath = customChatPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelsPath = customModelsPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return kind.definition(
      providerID: existing?.providerID ?? kind.defaultProviderID ?? "custom",
      displayName: label.trimmingCharacters(in: .whitespacesAndNewlines),
      baseURLOverride: endpoint,
      chatPath: chatPath,
      modelsPath: modelsPath.isEmpty ? nil : modelsPath,
      authentication: draftAuthentication,
      seedModelIDs: existing?.seedModelIDs ?? []
    )
    .withKind(kind)
  }

  private var trimmedCredential: String {
    credential.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var showsCredentialField: Bool {
    draftDefinition.authentication != .none
  }

  private var requiresCredential: Bool {
    draftDefinition.requiresCredential
  }

  private var hasStoredCredential: Bool {
    existing.map { model.credentialAccountIDs.contains($0.id) } ?? false
  }

  private var resolvedDraftEndpoint: URL? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      let requiresExplicitURL =
        isCustom || (isLocalServer && (isCreate || existing?.baseURLOverride != nil))
      return requiresExplicitURL ? nil : kind.defaultEndpoint
    }
    guard let parsed = URL(string: trimmed),
      let scheme = parsed.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      let host = parsed.host, !host.isEmpty
    else { return nil }
    return kind.normalizedBaseURL(parsed)
  }

  private var showsPhysicalDeviceLoopbackWarning: Bool {
    #if targetEnvironment(simulator)
      return false
    #else
      let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let host = URL(string: trimmed)?.host else { return false }
      return ProviderHTTP.isLoopbackHost(host)
    #endif
  }

  private var canSave: Bool {
    guard resolvedDraftEndpoint != nil else { return false }
    if isCustom {
      guard !customChatPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return false
      }
      if customAuth == .header,
        customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return false
      }
    }
    if requiresCredential && isCreate, trimmedCredential.isEmpty {
      return false
    }
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    if isCreate {
      if trimmedLabel.isEmpty, suggestedName.isEmpty {
        return false
      }
    } else if trimmedLabel.isEmpty {
      return false
    }
    if !manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
    let records = modelRecords
    if let existing {
      if records.isEmpty { return true }
      if let selectedModelID, records.contains(where: { $0.model.id == selectedModelID }) {
        return true
      }
      return selectedModelID == existing.defaultModelID
    }
    guard let selectedModelID else { return false }
    return records.contains { $0.model.id == selectedModelID }
  }

  var body: some View {
    Form {
      if isCreate {
        createProviderSection
        nameSection
        if isLocalServer {
          localServerSection
        } else if isCustom {
          customWireSection
        }
        credentialSection
        modelSection
        advancedSection
      } else {
        lockedProviderHeader
        nameSection
        if isLocalServer {
          localServerSection
        } else if isCustom {
          customWireSection
        }
        credentialSection
        modelSection
        advancedSection
        infoSection
        enabledSection
        deleteSection
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle(isCreate ? "Add Connection" : "Edit Connection")
    .navigationBarTitleDisplayMode(.inline)
    .interactiveDismissDisabled(isSaving)
    .navigationBarBackButtonHidden(isSaving)
    .toolbar {
      if isCreate {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { cancel() }
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(isCreate ? "Save" : "Done") { save() }
          .disabled(isSaving || !canSave)
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
    .confirmationDialog("Delete this connection?", isPresented: $showDelete) {
      Button("Delete Connection", role: .destructive) {
        guard let id = existing?.id else { return }
        isSaving = true
        Task { @MainActor in
          defer { isSaving = false }
          await model.deleteAccount(id)
          if !model.accounts.contains(where: { $0.id == id }) {
            dismiss()
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This removes the saved connection settings and API key from Keychain. Your existing chats will not be deleted."
      )
    }
    .onAppear {
      // Pre-fill the name with the suggestion without marking the form dirty.
      if isCreate, !didEditName {
        applySuggestedLabel()
      }
      if let focus {
        focusedField = focus
      }
    }
    .onChange(of: discoveryInput) { _, _ in invalidateDiscovery() }
    .onChange(of: selectedKind) { _, newValue in
      guard isCreate else { return }
      handleSelectedKindChange(to: newValue)
    }
    .onDisappear { cancelDiscovery() }
    .disabled(isSaving)
  }

  // MARK: - Sections

  private var lockedProviderHeader: some View {
    Section {
      HStack(spacing: 12) {
        ConnectionProviderMark(
          definition: isCustom ? draftDefinition : currentAccount?.definition,
          size: 38
        )
        VStack(alignment: .leading, spacing: 2) {
          Text(isCustom ? "Custom (OpenAI-Compatible)" : kind.displayName)
            .font(.system(size: 15, weight: .medium))
          Text("Provider is fixed for this connection")
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var providerTitle: String {
    if isCustom {
      let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
      return existing?.label ?? "OpenAI-compatible"
    }
    return kind.displayName
  }

  private var createProviderSection: some View {
    Section {
      NavigationLink {
        ConnectionProviderPickerView(selection: $selectedKind)
      } label: {
        HStack(spacing: 12) {
          ConnectionProviderMark(kind: selectedKind, size: 34)
          VStack(alignment: .leading, spacing: 2) {
            Text(selectedKind.pickerTitle)
              .font(.body.weight(.medium))
              .foregroundStyle(theme.primaryForegroundColor)
              .lineLimit(1)
            if let subtitle = selectedKind.pickerSubtitle {
              Text(subtitle)
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
                .lineLimit(1)
            }
          }
        }
        .padding(.vertical, 2)
      }
      .accessibilityLabel("Provider")
      .accessibilityValue(selectedKind.pickerTitle)
    } header: {
      Text("Provider")
    } footer: {
      Text("One connection per server or API key. Add the same provider twice to use multiple configurations.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func handleSelectedKindChange(to newValue: ProviderKind) {
    invalidateDiscovery()
    baseURL = ""
    credential = ""
    isDraftCredentialVisible = false
    clearCredential = false
    headersText = ""
    appTitle = ""
    httpReferer = ""
    customAuth = .bearer
    customHeaderName = "X-API-Key"
    customChatPath = "/chat/completions"
    customModelsPath = "/models"
    manualModelID = ""
    manualModels = []
    removedManualModelIDs = []
    selectedModelID = newValue.seedModels.first?.id
    if !didEditName { applySuggestedLabel() }
    isDirty = true
  }

  private var localServerPlaceholder: String {
    switch kind {
    case .ollama: "http://192.168.1.x:11434/v1"
    case .lmStudio: "http://192.168.1.x:1234/v1"
    default: "http://192.168.1.x:11434/v1"
    }
  }

  private var localServerHint: String {
    switch kind {
    case .ollama: "Enable 'Expose Ollama to the network' in Ollama settings."
    case .lmStudio: "Enable 'Serve on Local Network' in LM Studio's Developer tab."
    default: "HTTPS is required for internet hosts; HTTP is allowed for local and LAN hosts."
    }
  }

  private var localServerSection: some View {
    Section {
      TextField(localServerPlaceholder, text: $baseURL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .onChange(of: baseURL) { _, _ in isDirty = true }
      if showsPhysicalDeviceLoopbackWarning {
        loopbackWarningLabel
      }
      testConnectionButton
      connectionTestStatusRow
    } header: {
      Text("Server")
    } footer: {
      Text(localServerHint)
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var loopbackWarningLabel: some View {
    Label(
      "localhost refers to this device. Use your computer's LAN IP or .local hostname instead.",
      systemImage: "exclamationmark.triangle"
    )
    .font(.caption)
    .foregroundStyle(.orange)
  }

  private var testConnectionButton: some View {
    Button {
      fetchModels(recordConnectionTest: true)
    } label: {
      HStack {
        Label("Test Connection", systemImage: "network")
        Spacer()
        if isDiscoveryRunning {
          ProgressView().controlSize(.small)
        }
      }
    }
    .disabled(
      isDiscoveryRunning
        || resolvedDraftEndpoint == nil
        || (requiresCredential && !keyAvailableForDiscovery)
    )
  }

  @ViewBuilder
  private var connectionTestStatusRow: some View {
    switch connectionTestState {
    case .idle:
      EmptyView()
    case .testing:
      Text("Testing connection…")
        .font(.caption)
        .foregroundStyle(theme.secondaryForegroundColor)
    case .connected(let count):
      let summary =
        count == 0
        ? "Connected — no models loaded yet"
        : "Connected — \(count) \(count == 1 ? "model" : "models") found"
      Label(summary, systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
    }
  }

  private var customWireSection: some View {
    Section {
      TextField("https://example.com/v1", text: $baseURL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .onChange(of: baseURL) { _, _ in isDirty = true }
      if showsPhysicalDeviceLoopbackWarning {
        loopbackWarningLabel
      }
      Picker("Authentication", selection: $customAuth) {
        ForEach(AuthenticationChoice.allCases) { choice in
          Text(choice.title).tag(choice)
        }
      }
      .onChange(of: customAuth) { _, newValue in
        isDirty = true
        if newValue == .none {
          credential = ""
          isDraftCredentialVisible = false
          replaceCredential = false
        }
      }
      if customAuth == .header {
        TextField("Header name", text: $customHeaderName)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onChange(of: customHeaderName) { _, _ in isDirty = true }
      }
      TextField("Chat path", text: $customChatPath)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: customChatPath) { _, _ in isDirty = true }
      TextField("Models path (optional)", text: $customModelsPath)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: customModelsPath) { _, _ in isDirty = true }
      if draftDefinition.modelsPath != nil {
        testConnectionButton
        connectionTestStatusRow
      }
    } header: {
      Text("OpenAI-Compatible Server")
    } footer: {
      Text("HTTPS is required for internet hosts; HTTP is allowed for local and LAN addresses.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var credentialSection: some View {
    Section {
      if isCreate {
        if showsCredentialField {
          credentialField
        } else {
          Label("No API key required", systemImage: "checkmark.shield")
        }
      } else if showsCredentialField {
        if hasStoredCredential && !replaceCredential && !clearCredential {
          HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
              .foregroundStyle(theme.secondaryForegroundColor)
            VStack(alignment: .leading, spacing: 3) {
              Text("API Key").font(.system(size: 15, weight: .medium))
              Text(storedCredentialSubtitle)
                .font(.caption)
                .foregroundStyle(revealFailed ? .orange : theme.secondaryForegroundColor)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
              toggleReveal()
            } label: {
              if isRevealingCredential {
                ProgressView()
                  .controlSize(.small)
                  .frame(width: 36, height: 36)
              } else {
                Image(systemName: revealedCredential == nil ? "eye" : "eye.slash")
                  .frame(width: 36, height: 36)
              }
            }
            .buttonStyle(.plain)
            .disabled(isRevealingCredential)
            .accessibilityLabel(revealedCredential == nil ? "Reveal API key" : "Hide API key")
          }

          Button("Replace API Key") {
            replaceCredential = true
            clearCredential = false
            revealedCredential = nil
            revealFailed = false
            isDraftCredentialVisible = false
            focusedField = .apiKey
          }

          if !requiresCredential {
            Button("Remove API Key", role: .destructive) {
              clearCredential = true
              replaceCredential = false
              credential = ""
              revealedCredential = nil
              revealFailed = false
              isDraftCredentialVisible = false
              isDirty = true
            }
          }
        } else {
          credentialField
          if hasStoredCredential && clearCredential {
            Text("Saved API key will be removed when you tap Done.")
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
            Button("Keep Saved Key") {
              clearCredential = false
              credential = ""
              isDraftCredentialVisible = false
            }
          } else if hasStoredCredential && replaceCredential {
            Text("Leave blank to keep your saved key.")
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
            Button("Keep Saved Key") {
              replaceCredential = false
              credential = ""
              isDraftCredentialVisible = false
            }
          }
        }
      } else {
        Label("This provider does not require an API key.", systemImage: "checkmark.shield")
        if hasStoredCredential {
          Text("Saved API key will be removed when you tap Done.")
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
    } header: {
      Text(showsCredentialField && !requiresCredential ? "API Key (Optional)" : "API Key")
    } footer: {
      if showsCredentialField {
        if requiresCredential {
          Text(
            "Stored in Keychain and sent only to \(providerTitle) when BYOKchat makes a request."
          )
          .foregroundStyle(theme.secondaryForegroundColor)
        } else {
          Text(
            "Optional. Only sent when configured on your server. Stored in Keychain if provided."
          )
          .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var storedCredentialSubtitle: String {
    if revealFailed { return "Unable to read saved key from Keychain" }
    return revealedCredential == nil ? "Saved securely in Keychain" : maskedSummary
  }

  @ViewBuilder
  private var credentialField: some View {
    let placeholder =
      !requiresCredential
      ? (hasStoredCredential && replaceCredential ? "New API key (optional)" : "Optional API key")
      : (hasStoredCredential ? "New API key" : "Paste your API key")
    HStack(spacing: 8) {
      Group {
        if isDraftCredentialVisible {
          TextField(placeholder, text: $credential)
        } else {
          SecureField(placeholder, text: $credential)
        }
      }
      .focused($focusedField, equals: .apiKey)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .onChange(of: credential) { _, newValue in
        if !newValue.isEmpty { clearCredential = false }
        isDirty = true
      }

      if !credential.isEmpty {
        Button {
          isDraftCredentialVisible.toggle()
        } label: {
          Image(systemName: isDraftCredentialVisible ? "eye.slash" : "eye")
            .foregroundStyle(theme.secondaryForegroundColor)
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDraftCredentialVisible ? "Hide API key" : "Show API key")
      }
    }
  }

  private var maskedSummary: String {
    guard let value = revealedCredential else { return "" }
    if value.count > 8 {
      return "\(value.prefix(4))···\(value.suffix(4))  (\(value.count) chars)"
    }
    if value.count > 2 {
      return "\(value.prefix(1))···\(value.suffix(1))  (\(value.count) chars)"
    }
    return "•••  (\(value.count) \(value.count == 1 ? "char" : "chars"))"
  }

  private func toggleReveal() {
    if revealedCredential != nil {
      revealedCredential = nil
      revealFailed = false
      return
    }
    guard let id = existing?.id else { return }
    isRevealingCredential = true
    revealFailed = false
    Task { @MainActor in
      defer { isRevealingCredential = false }
      let secret = await model.revealCredential(accountID: id)
      revealedCredential = secret
      revealFailed = (secret == nil)
    }
  }

  private var modelSection: some View {
    Section {
      if draftDefinition.modelsPath != nil {
        Button {
          fetchModels(recordConnectionTest: true)
        } label: {
          HStack {
            Label("Fetch Models", systemImage: "arrow.clockwise")
            Spacer()
            if isDiscoveryRunning { ProgressView().controlSize(.small) }
            if let discoveredModels {
              Text("\(discoveredModels.count)").foregroundStyle(theme.secondaryForegroundColor)
            }
          }
        }
        .disabled(
          isDiscoveryRunning
            || resolvedDraftEndpoint == nil
            || (requiresCredential && !keyAvailableForDiscovery)
        )
        if !showsServerSection, case .connected = connectionTestState {
          connectionTestStatusRow
        }
      }

      modelSelectionRow
      TextField("Or enter a model ID", text: $manualModelID)
        .focused($focusedField, equals: .model)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .onSubmit { selectManualModel() }
        .onChange(of: manualModelID) { _, _ in isDirty = true }
      if !manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Button("Use Model ID") { selectManualModel() }
      }

      if let warning = discoveryWarning {
        Label(warning, systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    } header: {
      Text("Models")
    } footer: {
      Text(
        "Choose a default or enter its exact model ID. Fetch previews models; \(isCreate ? "Save" : "Done") keeps your changes."
      )
      .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var keyAvailableForDiscovery: Bool {
    !trimmedCredential.isEmpty || hasStoredCredential
  }

  private var modelSelection: Binding<ModelID?> {
    Binding(
      get: { selectedModelID },
      set: {
        selectedModelID = $0
        manualModelID = ""
        isDirty = true
      }
    )
  }

  @ViewBuilder
  private var modelSelectionRow: some View {
    let records = modelRecords
    if records.isEmpty {
      Text("Fetch models or enter a model ID below.")
        .font(.caption)
        .foregroundStyle(theme.secondaryForegroundColor)
    } else {
      NavigationLink {
        ConnectionModelPickerView(
          records: records,
          selection: modelSelection,
          removedManualModelIDs: $removedManualModelIDs,
          onRemoveManual: stageManualRemoval
        )
      } label: {
        LabeledContent("Default model") {
          VStack(alignment: .trailing, spacing: 2) {
            Text(selectedModelTitle)
              .foregroundStyle(theme.secondaryForegroundColor)
              .lineLimit(1)
            Text("\(records.count) available")
              .font(.caption2)
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        }
      }
    }
  }

  private var selectedModelTitle: String {
    let typed = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty { return typed }
    if let match = modelRecords.first(where: { $0.model.id == selectedModelID }) {
      return match.model.displayName
    }
    if let selectedModelID, let existing,
      let hidden = model.models(for: existing.id, includeHidden: true).first(where: {
        $0.model.id == selectedModelID
      })
    {
      return hidden.isHidden ? "\(hidden.model.displayName) (Hidden)" : hidden.model.displayName
    }
    return "Choose model"
  }

  private var modelRecords: [AccountModelRecord] {
    let stored = existing.map { model.models(for: $0.id, includeHidden: true) } ?? []
    var records: [ModelID: AccountModelRecord] = [:]
    let catalog = discoveredModels ?? (isCreate ? kind.seedModels : [])
    for record in stored where discoveredModels == nil || record.isManual {
      records[record.model.id] = record
    }
    for value in catalog {
      if var existingRecord = stored.first(where: { $0.model.id == value.id }) {
        existingRecord.model = value.mergingCapabilities(from: existingRecord.model)
        existingRecord.isAvailable = true
        records[value.id] = existingRecord
      } else {
        records[value.id] = AccountModelRecord(accountID: existing?.id ?? "", model: value)
      }
    }
    for value in manualModels {
      if var record = records[value.id] {
        record.isAvailable = true
        record.isHidden = false
        records[value.id] = record
      } else {
        records[value.id] = AccountModelRecord(
          accountID: existing?.id ?? "", model: value, isManual: true)
      }
    }
    return records.values.filter {
      $0.isAvailable && !$0.isHidden && !removedManualModelIDs.contains($0.model.id)
    }.sorted {
      if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
      return $0.model.displayName.localizedCaseInsensitiveCompare($1.model.displayName)
        == .orderedAscending
    }
  }

  private func selectManualModel() {
    let value = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    let id = ModelID(rawValue: value)
    removedManualModelIDs.remove(id)
    if !manualModels.contains(where: { $0.id == id }) {
      manualModels.append(ProviderModel(
        providerID: existing?.providerID ?? kind.defaultProviderID ?? "custom",
        id: id, displayName: value))
    }
    selectedModelID = id
    manualModelID = ""
    isDirty = true
  }

  private func stageManualRemoval(_ id: ModelID) {
    let inDraft = manualModels.contains { $0.id == id }
    let storedManual = existing.map { account in
      model.models(for: account.id, includeHidden: true).contains {
        $0.model.id == id && $0.isManual
      }
    } ?? false
    guard inDraft || storedManual else { return }
    manualModels.removeAll { $0.id == id }
    if storedManual { removedManualModelIDs.insert(id) }
    if selectedModelID == id { selectedModelID = modelRecords.first?.model.id }
    isDirty = true
  }

  private var advancedSection: some View {
    Section {
      DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
        VStack(alignment: .leading, spacing: 10) {
          if !showsServerSection {
            Text("Endpoint Override")
              .font(.caption.weight(.semibold))
              .foregroundStyle(theme.secondaryForegroundColor)
            TextField(endpointPlaceholder, text: $baseURL)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .keyboardType(.URL)
              .onChange(of: baseURL) { _, _ in isDirty = true }
          }

          if kind.extraCredentialFields.contains(.appTitle) {
            Text("OpenRouter App Title")
              .font(.caption.weight(.semibold))
              .foregroundStyle(theme.secondaryForegroundColor)
            TextField("BYOKchat", text: $appTitle)
              .onChange(of: appTitle) { _, _ in isDirty = true }
            Text("HTTP Referer")
              .font(.caption.weight(.semibold))
              .foregroundStyle(theme.secondaryForegroundColor)
            TextField("Optional", text: $httpReferer)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .keyboardType(.URL)
              .onChange(of: httpReferer) { _, _ in isDirty = true }
          }

          Text("Additional Headers")
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.secondaryForegroundColor)
          TextEditor(text: $headersText)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 84)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(
              Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: headersText) { _, _ in isDirty = true }
          Text("Enter one header per line as Name: Value — for example, X-API-Version: 2024-01-01. Both name and value are required; blank lines are ignored.")
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .padding(.vertical, 6)
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  /// Connection name. The field is PRE-FILLED with the suggested name — the
  /// provider display name, numbered on collision ("Anthropic", "Anthropic 2")
  /// — so the user always sees the name that will be saved. Editing is free;
  /// clearing the field back to empty re-enables provider-switch tracking.
  private var nameSection: some View {
    Section {
      TextField(isCustom ? "Server name" : suggestedName, text: $label)
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        .onChange(of: label) { _, newValue in
          if isApplyingSuggestedLabel {
            isApplyingSuggestedLabel = false
            return
          }
          isDirty = true
          if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            didEditName = false
          } else {
            didEditName = (newValue != suggestedName)
          }
        }
    } header: {
      Text("Name")
    } footer: {
      Text(
        isCustom
          ? "Shown in chats and pickers."
          : "Shown in chats and pickers. Defaults to the provider name."
      )
      .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func applySuggestedLabel() {
    let target = suggestedName
    guard label != target else { return }
    isApplyingSuggestedLabel = true
    label = target
  }

  /// The provider-named suggestion with collision handling. Custom servers
  /// require the user to name the connection explicitly.
  private var suggestedName: String {
    if isCreate {
      return model.autoName(for: kind)
    }
    return existing?.label ?? ""
  }

  private var endpointPlaceholder: String {
    if isCustom { return "Endpoint (required)" }
    return kind.defaultEndpoint?.absoluteString ?? "Provider default"
  }

  private var enabledSection: some View {
    Section {
      Toggle("Enabled", isOn: $isEnabled)
        .onChange(of: isEnabled) { _, _ in isDirty = true }
    } footer: {
      Text(
        "Disabled connections are hidden from chat pickers while keeping your saved settings and API key."
      )
      .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  /// Audit metadata for an existing connection.
  private var infoSection: some View {
    Section {
      if let created = currentAccount?.createdAt {
        LabeledContent("Created") {
          Text(created.formatted(date: .abbreviated, time: .shortened))
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
      if let updated = currentAccount?.updatedAt {
        LabeledContent("Updated") {
          Text(updated.formatted(date: .abbreviated, time: .shortened))
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
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

  // MARK: - Actions

  /// Raw form values identify the exact discovery request without storing keys
  /// outside this view. Changes cancel the request and invalidate its rates.
  private struct DiscoveryInput: Equatable {
    let kind: ProviderKind
    let endpoint: String
    let credential: String
    let clearCredential: Bool
    let headers: String
    let appTitle: String
    let referer: String
    let chatPath: String
    let modelsPath: String
    let auth: AuthenticationChoice
    let headerName: String
  }

  private var discoveryInput: DiscoveryInput {
    DiscoveryInput(
      kind: kind, endpoint: baseURL, credential: credential, clearCredential: clearCredential,
      headers: headersText, appTitle: appTitle, referer: httpReferer, chatPath: customChatPath,
      modelsPath: customModelsPath, auth: customAuth, headerName: customHeaderName)
  }

  private var draftMetadata: [String: String] {
    var metadata = existing?.metadata ?? [:]
    if kind.extraCredentialFields.contains(.appTitle) {
      let title = appTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      let referer = httpReferer.trimmingCharacters(in: .whitespacesAndNewlines)
      metadata["appTitle"] = title.isEmpty ? nil : title
      metadata["httpReferer"] = referer.isEmpty ? nil : referer
    }
    return metadata
  }

  private func cancelDiscovery() {
    discoveryTask?.cancel()
    discoveryTask = nil
    discoveryID = nil
    isDiscoveryRunning = false
  }

  private func invalidateDiscovery() {
    cancelDiscovery()
    discoveredModels = nil
    discoveryWarning = nil
    connectionTestState = .idle
  }

  private func fetchModels(recordConnectionTest: Bool = false) {
    guard let endpoint = resolvedDraftEndpoint else {
      let message = "Enter a valid server URL first."
      discoveryWarning = message
      if recordConnectionTest || showsServerSection {
        connectionTestState = .failed(message)
      }
      return
    }
    let headers: [String: String]
    do {
      headers = try parseHeadersStrict(headersText)
    } catch {
      discoveryWarning = error.localizedDescription
      if recordConnectionTest || showsServerSection {
        connectionTestState = .failed(error.localizedDescription)
      }
      return
    }
    let input = discoveryInput
    let requestID = UUID()
    let definition = draftDefinition
    let previewLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? (suggestedName.isEmpty ? "Custom" : suggestedName)
      : label
    let resolved = ResolvedProviderAccount(
      kind: kind, id: existing?.id ?? "", providerID: existing?.providerID ?? definition.id,
      label: previewLabel,
      apiKey: trimmedCredential.isEmpty ? nil : trimmedCredential,
      baseURLOverride: endpoint, additionalHeaders: headers, metadata: draftMetadata,
      chatCompletionsPath: isCustom
        ? customChatPath.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
      modelsPath: isCustom ? definition.modelsPath : nil,
      authChoice: isCustom ? definition.authentication : nil,
      seedModelIDs: existing?.seedModelIDs ?? [])
    let storedCredentialID = (clearCredential || (isCustom && customAuth == .none)) ? nil : existing?.id
    let tracksTestState = recordConnectionTest || showsServerSection
    discoveryTask?.cancel()
    discoveryID = requestID
    isDiscoveryRunning = true
    discoveryWarning = nil
    if tracksTestState {
      connectionTestState = .testing
    }
    discoveryTask = Task { @MainActor in
      defer {
        if discoveryID == requestID {
          isDiscoveryRunning = false
          discoveryTask = nil
        }
      }
      do {
        let models = try await model.previewModels(
          for: resolved, storedCredentialAccountID: storedCredentialID)
        guard !Task.isCancelled, discoveryID == requestID, discoveryInput == input else { return }
        discoveredModels = models
        isDirty = true
        if tracksTestState {
          connectionTestState = .connected(modelCount: models.count)
        }
        if !modelRecords.contains(where: { $0.model.id == selectedModelID }) {
          selectedModelID = modelRecords.first?.model.id
        }
        if models.isEmpty {
          discoveryWarning = "No models returned. Enter a model ID manually to continue."
        }
      } catch {
        guard !Task.isCancelled, discoveryID == requestID, discoveryInput == input else { return }
        if tracksTestState {
          connectionTestState = .failed("Connection failed: \(error.localizedDescription)")
        }
        if !showsServerSection {
          discoveryWarning = "Model discovery failed: \(error.localizedDescription) Enter a model ID manually to continue."
        }
      }
    }
  }

  private func cancel() {
    dismiss()
  }

  private func normalizedCloudBaseURL(_ trimmedBaseURL: String) -> String {
    guard !isCustom && !isLocalServer else { return trimmedBaseURL }
    guard !trimmedBaseURL.isEmpty else { return "" }
    let defaultString = kind.defaultEndpoint?.absoluteString
    let withoutTrailingSlash =
      trimmedBaseURL.hasSuffix("/") ? String(trimmedBaseURL.dropLast()) : trimmedBaseURL
    if trimmedBaseURL == defaultString || withoutTrailingSlash == defaultString {
      return ""
    }
    return trimmedBaseURL
  }

  private func hasUnsavedChanges(
    against existing: ProviderAccount,
    finalLabel: String,
    persistedBaseURL: String,
    parsedHeaders: [String: String],
    metadata: [String: String],
    sanitizedCredential: String,
    shouldClearCredential: Bool,
    resolvedModelID: ModelID?,
    manualIDs: [String],
    effectiveRemoved: Set<ModelID>,
    preview: [ProviderModel]?
  ) -> Bool {
    if finalLabel != existing.label { return true }
    if isEnabled != existing.isEnabled { return true }
    if persistedBaseURL != (existing.baseURLOverride?.absoluteString ?? "") { return true }
    if parsedHeaders != existing.additionalHeaders { return true }
    if metadata != existing.metadata { return true }
    if !sanitizedCredential.isEmpty || (shouldClearCredential && hasStoredCredential) { return true }
    if resolvedModelID != existing.defaultModelID { return true }
    if preview != nil || !manualIDs.isEmpty || !effectiveRemoved.isEmpty { return true }
    if isCustom {
      let existingDef = existing.definition
      let trimmedChat = customChatPath.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedModels = customModelsPath.trimmingCharacters(in: .whitespacesAndNewlines)
      let normalizedModels: String? = trimmedModels.isEmpty ? nil : trimmedModels
      if trimmedChat != existingDef.chatCompletionsPath { return true }
      if normalizedModels != existingDef.modelsPath { return true }
      if draftAuthentication != existingDef.authentication { return true }
    }
    return false
  }

  private func save() {
    let parsedHeaders: [String: String]
    do {
      parsedHeaders = try parseHeadersStrict(headersText)
    } catch {
      isAdvancedExpanded = true
      model.errorMessage = error.localizedDescription
      return
    }

    let metadata = draftMetadata
    let typedModel = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedModelID = typedModel.isEmpty ? selectedModelID : ModelID(rawValue: typedModel)
    let preview = discoveredModels
    let manualIDs = manualModels.map { $0.id.rawValue } + (typedModel.isEmpty ? [] : [typedModel])
    let sanitizedCredential = (isCustom && customAuth == .none) ? "" : trimmedCredential
    let shouldClearCredential =
      (clearCredential || (isCustom && customAuth == .none)) && sanitizedCredential.isEmpty
    let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let persistedBaseURL = normalizedCloudBaseURL(trimmedBaseURL)
    let trimmedCustomChatPath = customChatPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedCustomModelsPath = customModelsPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveAuth = draftAuthentication
    let effectiveRemoved = removedManualModelIDs.subtracting(
      Set(manualIDs.map(ModelID.init(rawValue:)))
    )

    // Capture values before suspension; invalidate the outstanding preview.
    discoveryTask?.cancel()
    discoveryID = nil
    isDiscoveryRunning = false

    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let finalLabel = trimmedLabel.isEmpty ? suggestedName : trimmedLabel
    guard !finalLabel.isEmpty else { return }

    if let existing {
      let latest = currentAccount ?? existing
      if !hasUnsavedChanges(
        against: latest,
        finalLabel: finalLabel,
        persistedBaseURL: persistedBaseURL,
        parsedHeaders: parsedHeaders,
        metadata: metadata,
        sanitizedCredential: sanitizedCredential,
        shouldClearCredential: shouldClearCredential,
        resolvedModelID: resolvedModelID,
        manualIDs: manualIDs,
        effectiveRemoved: effectiveRemoved,
        preview: preview
      ) {
        dismiss()
        return
      }
      let modelSelectionChanged =
        !typedModel.isEmpty
        || resolvedModelID != latest.defaultModelID
        || (resolvedModelID == nil && !effectiveRemoved.isEmpty)
      isSaving = true
      Task { @MainActor in
        defer { isSaving = false }
        guard await model.updateAccount(
          accountID: existing.id,
          label: finalLabel,
          isEnabled: isEnabled,
          newCredential: sanitizedCredential.isEmpty ? nil : sanitizedCredential,
          clearCredential: shouldClearCredential,
          baseURLString: persistedBaseURL,
          headers: parsedHeaders,
          metadata: metadata,
          chatCompletionsPath: isCustom ? trimmedCustomChatPath : nil,
          modelsPath: isCustom && !trimmedCustomModelsPath.isEmpty ? trimmedCustomModelsPath : nil,
          clearModelsPath: isCustom && trimmedCustomModelsPath.isEmpty,
          authChoice: isCustom ? effectiveAuth : nil,
          defaultModelID: modelSelectionChanged ? resolvedModelID : nil,
          clearDefaultModel: modelSelectionChanged && resolvedModelID == nil,
          discoveredModels: preview,
          manualModelIDs: manualIDs,
          removedManualModelIDs: effectiveRemoved
        ) else { return }
        dismiss()
        onFinished?()
      }
      return
    }

    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      let created = await model.createConnection(
        kind: kind,
        label: finalLabel,
        credential: sanitizedCredential,
        baseURL: persistedBaseURL,
        defaultModel: resolvedModelID?.rawValue ?? "",
        headers: parsedHeaders,
        metadata: metadata,
        chatCompletionsPath: isCustom ? trimmedCustomChatPath : nil,
        modelsPath: isCustom && !trimmedCustomModelsPath.isEmpty ? trimmedCustomModelsPath : nil,
        authChoice: isCustom ? effectiveAuth : nil,
        seedModelIDs: [],
        discoveredModels: preview,
        manualModelIDs: manualIDs
      )
      guard created != nil else { return }
      dismiss()
      onFinished?()
    }
  }

  private enum ConnectionTestState: Equatable {
    case idle
    case testing
    case connected(modelCount: Int)
    case failed(String)
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
}

/// Searchable provider list with brand icons. Tap selects and pops back to the
/// connection editor.
struct ConnectionProviderPickerView: View {
  @Binding var selection: ProviderKind

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var searchText = ""

  private var trimmedQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var filteredCloud: [ProviderKind] {
    filtered(ProviderKind.cloudCatalog)
  }

  private var filteredLocalAndCustom: [ProviderKind] {
    filtered(ProviderKind.localAndCustomCatalog)
  }

  private func filtered(_ candidates: [ProviderKind]) -> [ProviderKind] {
    let query = trimmedQuery
    guard !query.isEmpty else { return candidates }
    return candidates.filter { $0.matchesProviderSearch(query) }
  }

  var body: some View {
    List {
      if filteredCloud.isEmpty && filteredLocalAndCustom.isEmpty {
        ContentUnavailableView.search(text: searchText)
          .listRowBackground(Color.clear)
      } else {
        if !filteredCloud.isEmpty {
          Section {
            ForEach(filteredCloud, id: \.self) { candidate in
              providerRow(candidate)
            }
          } header: {
            Text("Cloud Providers")
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        }

        if !filteredLocalAndCustom.isEmpty {
          Section {
            ForEach(filteredLocalAndCustom, id: \.self) { candidate in
              providerRow(candidate)
            }
          } header: {
            Text("Local & Custom")
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Choose Provider")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search providers")
  }

  private func providerRow(_ candidate: ProviderKind) -> some View {
    let isSelected = candidate == selection
    return Button {
      if !isSelected {
        selection = candidate
      }
      dismiss()
    } label: {
      HStack(spacing: 12) {
        ConnectionProviderMark(kind: candidate, size: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text(candidate.pickerTitle)
            .font(.body.weight(.medium))
            .foregroundStyle(theme.primaryForegroundColor)
            .lineLimit(1)
          if let subtitle = candidate.pickerSubtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        if isSelected {
          Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(.tint)
        }
      }
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(theme.surfaceColor)
    .listRowSeparatorTint(theme.borderColor)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// Searchable picker for every provider. Tap selects and pops back to the
/// editor; only the editor's Save/Done persists the selection.
struct ConnectionModelPickerView: View {
  let records: [AccountModelRecord]
  @Binding var selection: ModelID?
  @Binding var removedManualModelIDs: Set<ModelID>
  let onRemoveManual: (ModelID) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var searchText = ""

  private var filtered: [AccountModelRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let visibleRecords = records.filter { !removedManualModelIDs.contains($0.model.id) }
    let base = query.isEmpty
      ? visibleRecords
      : visibleRecords.filter {
        $0.model.displayName.localizedCaseInsensitiveContains(query)
          || $0.model.id.rawValue.localizedCaseInsensitiveContains(query)
      }
    return base.sorted { lhs, rhs in
      if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
      return lhs.model.displayName.localizedCaseInsensitiveCompare(rhs.model.displayName)
        == .orderedAscending
    }
  }

  private func modelDetails(_ record: AccountModelRecord) -> String {
    var parts: [String] = []
    if let context = record.model.contextWindow {
      parts.append("\(context.formatted(.number.notation(.compactName))) ctx")
    }
    if record.model.inputModalities.contains("image") {
      parts.append("Vision")
    }
    if record.model.inputModalities.contains("file") {
      parts.append("Files")
    }
    return parts.joined(separator: " • ")
  }

  var body: some View {
    List {
      if filtered.isEmpty {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          ContentUnavailableView(
            "No Models",
            systemImage: "square.stack.3d.up.slash",
            description: Text("Fetch models or enter a model ID manually.")
          )
          .listRowBackground(Color.clear)
        } else {
          ContentUnavailableView.search(text: searchText)
            .listRowBackground(Color.clear)
        }
      } else {
        ForEach(filtered) { record in
          let details = modelDetails(record)
          Button {
            selection = record.model.id
            dismiss()
          } label: {
            HStack(alignment: .top, spacing: 10) {
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                  if record.isFavorite {
                    Image(systemName: "star.fill")
                      .font(.caption)
                      .foregroundStyle(.yellow)
                  }
                  Text(record.model.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.primaryForegroundColor)
                  if record.model.id == selection {
                    Image(systemName: "checkmark")
                      .foregroundStyle(.tint)
                  }
                }
                Text(record.model.id.rawValue)
                  .font(.caption.monospaced())
                  .foregroundStyle(theme.secondaryForegroundColor)
                  .lineLimit(2)
                if !details.isEmpty {
                  Text(details)
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .lineLimit(1)
                }
              }
              Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .listRowBackground(theme.surfaceColor)
          .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if record.isManual {
              Button("Remove", systemImage: "trash", role: .destructive) {
                onRemoveManual(record.model.id)
              }
            }
          }
          .contextMenu {
            if record.isManual {
              Button("Remove Custom Model", systemImage: "trash", role: .destructive) {
                onRemoveManual(record.model.id)
              }
            }
          }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Choose Model")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search models")
  }
}
