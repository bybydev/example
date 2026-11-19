import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// One editor for every provider account, create and edit. Fields are
/// conditioned on the account's (or prospective) `ProviderKind`: built-in
/// kinds hide wire configuration, `.openAICompatible` accounts show auth and
/// paths once at create. Nothing is persisted in create mode until Save.
struct ConnectionEditorView: View {
  /// What a presenting surface wants fixed or focused.
  enum FocusRequest: Equatable {
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

  // Create-mode state
  @State private var selectedKind: ProviderKind
  @State private var customName = ""
  @State private var customAuth: AuthenticationChoice = .bearer
  @State private var customHeaderName = "X-API-Key"
  @State private var customChatPath = "/chat/completions"
  @State private var customModelsPath = "/models"

  // Shared field state
  @State private var label = ""
  @State private var credential = ""
  @State private var baseURL = ""
  @State private var headersText = ""
  @State private var appTitle = ""
  @State private var httpReferer = ""
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
  /// False until the user edits the name field; while false, the name
  /// pre-fills/updates with the provider-named suggestion.
  @State private var didEditName = false

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
      _baseURL = State(initialValue: existing.baseURLOverride?.absoluteString ?? "")
      _headersText = State(initialValue: serializeHeaders(existing.additionalHeaders))
      _selectedModelID = State(initialValue: existing.defaultModelID)
      _appTitle = State(initialValue: existing.metadata["appTitle"] ?? "")
      _httpReferer = State(initialValue: existing.metadata["httpReferer"] ?? "")
    } else {
      let initial = initialKind ?? .anthropic
      _baseURL = State(
        initialValue: initial.isLocalServer ? "" : (initial.defaultEndpoint?.absoluteString ?? ""))
      _selectedModelID = State(initialValue: initial.seedModels.first?.id)
    }
  }

  private var isCreate: Bool { existing == nil }

  private var kind: ProviderKind { existing?.kind ?? selectedKind }

  private var isCustom: Bool { kind == .openAICompatible }

  private var isLocalServer: Bool { kind.isLocalServer }

  private var showsServerSection: Bool { isLocalServer || isCustom }

  /// In edit mode the kind's derived definition supplies defaults; in create
  /// mode it is built from the typed custom-provider fields.
  private var draftDefinition: ProviderDefinition {
    if let existing { return existing.definition }
    let endpoint = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    let auth: ProviderAuthentication =
      switch customAuth {
      case .bearer: .bearer
      case .header: .header(name: customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines))
      case .none: .none
      }
    let chatPath = customChatPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelsPath = customModelsPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return kind.definition(
      providerID: kind.defaultProviderID ?? "custom",
      displayName: customName,
      baseURLOverride: endpoint,
      chatPath: chatPath,
      modelsPath: modelsPath.isEmpty ? nil : modelsPath,
      authentication: auth,
      seedModelIDs: []
    )
    .withKind(kind)
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
      return isLocalServer && isCreate ? nil : kind.defaultEndpoint
    }
    guard let parsed = URL(string: trimmed) else { return nil }
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
    if isCustom && isCreate {
      guard !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        resolvedDraftEndpoint != nil
      else { return false }
      if customAuth == .header, customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return false
      }
    } else if isCustom {
      guard resolvedDraftEndpoint != nil else { return false }
    }
    if isLocalServer {
      guard resolvedDraftEndpoint != nil else { return false }
    }
    if requiresCredential && isCreate, credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return false
    }
    // Name: the field is pre-filled, so it is normally non-empty. Custom
    // providers must have a typed server name to suggest from.
    if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      suggestedName.isEmpty
    {
      return false
    }
    if !manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
    guard let selectedModelID else {
      // Allow removing the final manual model from an existing connection.
      return existing != nil && !removedManualModelIDs.isEmpty && modelRecords.isEmpty
    }
    return modelRecords.contains { $0.model.id == selectedModelID }
  }

  var body: some View {
    Form {
      if isCreate {
        createProviderSection
        nameSection
        if isLocalServer {
          localServerSection
        }
        credentialSection
        if isCustom {
          customWireSection
        }
        modelSection
        advancedSection
      } else {
        lockedProviderHeader
        nameSection
        if isLocalServer {
          localServerSection
        } else if isCustom {
          customEditServerSection
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
        Task { @MainActor in
          await model.deleteAccount(existing?.id ?? "")
          dismiss()
          onFinished?()
        }
      }
      Button("Cancel", role: .cancel) {}
    }
    .onAppear {
      if !isDirty, baseURL.isEmpty, let existing {
        baseURL = existing.baseURLOverride?.absoluteString ?? ""
      }
      // Pre-fill the name with the suggestion. The field holds the real
      // value from here on; the onChange handlers re-track only if the user
      // clears it back to empty.
      if isCreate, !didEditName {
        let suggestion = suggestedName
        if !suggestion.isEmpty {
          label = suggestion
        }
      }
    }
    .onChange(of: selectedKind) { _, _ in
      // Provider changed while the name still tracks the suggestion.
      guard isCreate, !didEditName else { return }
      label = suggestedName
    }
    .onChange(of: customName) { _, _ in
      guard isCreate, !didEditName, kind == .openAICompatible else { return }
      label = suggestedName
    }
    .onChange(of: discoveryInput) { _, _ in invalidateDiscovery() }
    .onDisappear { cancelDiscovery() }
    .disabled(isSaving)
  }

  // MARK: - Sections

  private var lockedProviderHeader: some View {
    Section {
      HStack(spacing: 12) {
        ConnectionProviderMark(definition: existing?.definition, size: 38)
        VStack(alignment: .leading, spacing: 2) {
          Text(providerTitle).font(.system(size: 15, weight: .medium))
          Text("Provider is fixed for this connection")
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var providerTitle: String {
    if isCustom { return existing?.label ?? "OpenAI-compatible" }
    return kind.displayName
  }

  private var createProviderSection: some View {
    Section {
      Picker("Provider", selection: $selectedKind) {
        Section("Cloud Providers") {
          ForEach(ProviderKind.cloudCatalog, id: \.self) { candidate in
            Text(candidate.displayName).tag(candidate)
          }
        }
        Section("Local & Custom") {
          ForEach(ProviderKind.localAndCustomCatalog, id: \.self) { candidate in
            Text(candidate == .openAICompatible ? "Custom (OpenAI-Compatible)" : candidate.displayName)
              .tag(candidate)
          }
        }
      }
      .onChange(of: selectedKind) { _, newValue in
        invalidateDiscovery()
        baseURL = newValue.isLocalServer ? "" : (newValue.defaultEndpoint?.absoluteString ?? "")
        credential = ""
        clearCredential = false
        headersText = ""
        appTitle = ""
        httpReferer = ""
        manualModelID = ""
        manualModels = []
        selectedModelID = newValue.seedModels.first?.id
        if !didEditName { label = suggestedName }
        isDirty = true
      }
    } header: {
      Text("Provider")
    } footer: {
      Text("One connection per server or API key. Add the same provider twice to use multiple configurations.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
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

  private var customEditServerSection: some View {
    Section {
      TextField("https://example.com/v1", text: $baseURL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .onChange(of: baseURL) { _, _ in isDirty = true }
      if showsPhysicalDeviceLoopbackWarning {
        loopbackWarningLabel
      }
      if draftDefinition.modelsPath != nil {
        testConnectionButton
        connectionTestStatusRow
      }
    } header: {
      Text("Server")
    } footer: {
      Text("HTTPS is required for internet hosts; HTTP is allowed for local and LAN addresses.")
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
      TextField("Display name", text: $customName)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: customName) { _, _ in isDirty = true }
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
      if customAuth == .header {
        TextField("Header name", text: $customHeaderName)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }
      TextField("Chat path", text: $customChatPath)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      TextField("Models path (optional)", text: $customModelsPath)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
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
              Text(revealedCredential == nil ? "Saved securely in Keychain" : maskedSummary)
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
                .lineLimit(1)
            }
            Spacer()
            // Eye: reveal/hide the stored key without replacing it.
            Button {
              toggleReveal()
            } label: {
              Image(systemName: revealedCredential == nil ? "eye" : "eye.slash")
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(isRevealingCredential)
            .accessibilityLabel(revealedCredential == nil ? "Reveal API key" : "Hide API key")

            Button("Replace") {
              replaceCredential = true
              clearCredential = false
              revealedCredential = nil
            }
            .font(.system(size: 14, weight: .semibold))

            if !requiresCredential {
              Button("Remove", role: .destructive) {
                clearCredential = true
                replaceCredential = false
                credential = ""
                revealedCredential = nil
                isDirty = true
              }
              .font(.system(size: 14, weight: .semibold))
            }
          }
        } else {
          credentialField
          if clearCredential {
            Text("Saved API key will be removed when you tap Done.")
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        }
      } else {
        Label("This provider does not require an API key.", systemImage: "checkmark.shield")
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

  @ViewBuilder
  private var credentialField: some View {
    let placeholder =
      !requiresCredential
      ? (hasStoredCredential && replaceCredential ? "New API key (optional)" : "Optional API key")
      : (hasStoredCredential ? "New API key" : "Paste your API key")
    // Reveal-while-typing: eye toggles between SecureField and TextField for
    // the credential being entered (create or replace).
    if isCredentialVisible {
      TextField(placeholder, text: $credential)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: credential) { _, newValue in
          if !newValue.isEmpty { clearCredential = false }
          isDirty = true
        }
    } else {
      SecureField(placeholder, text: $credential)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: credential) { _, newValue in
          if !newValue.isEmpty { clearCredential = false }
          isDirty = true
        }
    }
  }

  private var isCredentialVisible: Bool {
    if isCreate || replaceCredential { return revealedCredential != nil }
    return false
  }

  private var maskedSummary: String {
    guard let value = revealedCredential, value.count > 8 else { return "Key revealed" }
    return "\(value.prefix(4))···\(value.suffix(4))  (\(value.count) chars)"
  }

  private func toggleReveal() {
    if revealedCredential != nil {
      revealedCredential = nil
      return
    }
    guard let id = existing?.id else { return }
    isRevealingCredential = true
    Task { @MainActor in
      defer { isRevealingCredential = false }
      revealedCredential = await model.revealCredential(accountID: id)
    }
  }

  private var modelSection: some View {
    Section {
      if draftDefinition.modelsPath != nil {
        Button {
          fetchModels()
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
      }

      modelSelectionRow
      TextField("Or enter a model ID", text: $manualModelID)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
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
      Text("Choose a default or enter its exact model ID. Fetch previews models; Save or Done keeps your changes.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var keyAvailableForDiscovery: Bool {
    !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasStoredCredential
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
    return modelRecords.first { $0.model.id == selectedModelID }?.model.displayName
      ?? "Choose model"
  }

  private var modelRecords: [AccountModelRecord] {
    let stored = existing.map { model.models(for: $0.id, includeHidden: true) } ?? []
    var records: [ModelID: AccountModelRecord] = [:]
    let catalog = discoveredModels ?? (isCreate ? kind.seedModels : [])
    for record in stored where discoveredModels == nil || record.isManual {
      records[record.model.id] = record
    }
    for value in catalog {
      var record = stored.first { $0.model.id == value.id }
        ?? AccountModelRecord(accountID: existing?.id ?? "", model: value)
      record.model = value
      record.isAvailable = true
      records[value.id] = record
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
      DisclosureGroup("Advanced") {
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
        }
        .padding(.vertical, 6)
      }
    } footer: {
      Text("Enter one header per line as Name: Value — for example, X-API-Version: 2024-01-01. Both name and value are required; blank lines are ignored.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  /// Connection name. The field is PRE-FILLED with the suggested name — the
  /// provider display name, numbered on collision ("Anthropic", "Anthropic 2")
  /// — so the user always sees the name that will be saved. Editing is free;
  /// programmatic tracking continues until they do (flag set by the user's
  /// own edits via the text-change binding below). What's in the field is
  /// what's saved: no empty-means-resolve second path.
  private var nameSection: some View {
    Section {
      TextField(suggestedName, text: $label)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: label) { oldValue, newValue in
          isDirty = true
          // Only a human keystroke marks the name as user-owned; the
          // tracking writes below go through the same onChange, so compare
          // against the current suggestion to distinguish them.
          if newValue != suggestedName || (oldValue == suggestedName && newValue.isEmpty) {
            didEditName = true
          }
        }
    } header: {
      Text("Name")
    } footer: {
      Text("Shown in chats and pickers. Defaults to the provider name.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  /// The provider-named suggestion with collision handling. For custom
  /// providers the typed server name is the base.
  private var suggestedName: String {
    if isCreate {
      return model.autoName(for: kind, customBase: customName)
    }
    return existing?.label ?? ""
  }

  private var endpointPlaceholder: String {
    if isCustom { return "Endpoint (required)" }
    return kind.defaultEndpoint?.absoluteString ?? "Provider default"
  }

  private var enabledSection: some View {
    Section {
      Toggle(
        "Enabled",
        isOn: Binding(
          get: { existing?.isEnabled ?? false },
          set: { enabled in
            guard let id = existing?.id else { return }
            Task { @MainActor in
              _ = await model.setAccountEnabled(enabled, accountID: id)
            }
          }
        )
      )
    }
    .listRowBackground(theme.surfaceColor)
  }

  /// Audit metadata for an existing connection.
  private var infoSection: some View {
    Section {
      if let created = existing?.createdAt {
        LabeledContent("Created") {
          Text(created.formatted(date: .abbreviated, time: .shortened))
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
      if let updated = existing?.updatedAt {
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
      apiKey: credential.isEmpty ? nil : credential,
      baseURLOverride: endpoint, additionalHeaders: headers, metadata: draftMetadata,
      chatCompletionsPath: existing?.chatCompletionsPath
        ?? (isCustom ? customChatPath.trimmingCharacters(in: .whitespacesAndNewlines) : nil),
      modelsPath: existing?.modelsPath
        ?? (isCustom ? draftDefinition.modelsPath : nil),
      authChoice: isCustom ? definition.authentication : nil,
      seedModelIDs: existing?.seedModelIDs ?? [])
    let storedCredentialID = clearCredential ? nil : existing?.id
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
        discoveryWarning = "Model discovery failed: \(error.localizedDescription) Enter a model ID manually to continue."
      }
    }
  }

  private func cancel() {
    if !isCreate && isDirty {
      // Unsaved edits: dismiss without confirmation ceremony but keep state.
      dismiss()
      return
    }
    dismiss()
    onFinished?()
  }

  private func save() {
    let parsedHeaders: [String: String]
    do {
      parsedHeaders = try parseHeadersStrict(headersText)
    } catch {
      model.errorMessage = error.localizedDescription
      return
    }

    let metadata = draftMetadata
    let typedModel = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedModelID = typedModel.isEmpty ? selectedModelID : ModelID(rawValue: typedModel)
    let preview = discoveredModels
    let manualIDs = manualModels.map { $0.id.rawValue } + (typedModel.isEmpty ? [] : [typedModel])
    // Capture values before suspension; invalidate the outstanding preview.
    discoveryTask?.cancel()
    discoveryID = nil
    isDiscoveryRunning = false

    // Single name path: the field is pre-filled with the suggestion, so
    // whatever is here (or a fallback recompute if somehow cleared) saves.
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let finalLabel = trimmedLabel.isEmpty
      ? model.autoName(for: kind, customBase: customName)
      : trimmedLabel
    guard !finalLabel.isEmpty else { return }

    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      if let existing {
        guard resolvedModelID != nil || !removedManualModelIDs.isEmpty else { return }
        guard await model.updateAccount(
          accountID: existing.id,
          label: finalLabel,
          newCredential: credential.isEmpty ? nil : credential,
          clearCredential: clearCredential && credential.isEmpty,
          baseURLString: baseURL,
          headers: parsedHeaders,
          metadata: metadata,
          defaultModelID: resolvedModelID,
          clearDefaultModel: resolvedModelID == nil,
          discoveredModels: preview,
          manualModelIDs: manualIDs,
          removedManualModelIDs: removedManualModelIDs
        ) else { return }
      } else {
        let created = await model.createConnection(
          kind: kind,
          label: finalLabel,
          credential: credential,
          baseURL: baseURL,
          defaultModel: resolvedModelID?.rawValue ?? "",
          headers: parsedHeaders,
          metadata: metadata,
          chatCompletionsPath: isCustom
            ? customChatPath.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
          modelsPath: isCustom ? draftDefinition.modelsPath : nil,
          authChoice: isCustom ? draftDefinition.authentication : nil,
          seedModelIDs: [],
          discoveredModels: preview,
          manualModelIDs: manualIDs
        )
        guard created != nil else { return }
      }
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
        ContentUnavailableView.search(text: searchText)
          .listRowBackground(Color.clear)
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
