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
  @State private var customBaseURL = ""
  @State private var customAuth: AuthenticationChoice = .bearer
  @State private var customHeaderName = "X-API-Key"
  @State private var customChatPath = "/chat/completions"
  @State private var customModelsPath = "/models"
  @State private var showNewProviderSection = false

  // Shared field state
  @State private var label = ""
  @State private var credential = ""
  @State private var baseURL = ""
  @State private var headersText = ""
  @State private var appTitle = ""
  @State private var httpReferer = ""
  @State private var selectedModelID: ModelID?
  @State private var manualModelID = ""
  @State private var discoveredModels: [ProviderModel] = []
  @State private var isDiscoveryRunning = false
  @State private var discoveryWarning: String?
  @State private var showDelete = false
  @State private var isSaving = false
  @State private var replaceCredential = false
  @State private var isDirty = false

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
    } else if let initialKind, initialKind != .openAICompatible {
      _baseURL = State(initialValue: initialKind.defaultEndpoint?.absoluteString ?? "")
    }
  }

  private var isCreate: Bool { existing == nil }

  private var kind: ProviderKind { existing?.kind ?? selectedKind }

  private var isCustom: Bool { kind == .openAICompatible }

  /// In edit mode the kind's derived definition supplies defaults; in create
  /// mode it is built from the typed custom-provider fields.
  private var draftDefinition: ProviderDefinition {
    if let existing { return existing.definition }
    let endpoint = URL(string: customBaseURL.trimmingCharacters(in: .whitespaces))
    let auth: ProviderAuthentication =
      switch customAuth {
      case .bearer: .bearer
      case .header: .header(name: customHeaderName.trimmingCharacters(in: .whitespaces))
      case .none: .none
      }
    let chatPath = customChatPath.trimmingCharacters(in: .whitespaces)
    let modelsPath = customModelsPath.trimmingCharacters(in: .whitespaces)
    return kind.definition(
      providerID: kind.defaultProviderID ?? "custom",
      displayName: customName,
      baseURLOverride: endpoint,
      chatPath: chatPath,
      modelsPath: modelsPath,
      authentication: auth,
      seedModelIDs: []
    )
    .withKind(kind)
  }

  private var requiresCredential: Bool {
    draftDefinition.authentication != .none
  }

  private var hasStoredCredential: Bool {
    existing.map { model.credentialAccountIDs.contains($0.id) } ?? false
  }

  private var canShowKeyField: Bool {
    requiresCredential && (!isCreate && !hasStoredCredential || replaceCredential || isCreate)
  }

  private var canSave: Bool {
    if isCustom && isCreate {
      guard !customName.trimmingCharacters(in: .whitespaces).isEmpty,
        URL(string: customBaseURL.trimmingCharacters(in: .whitespaces)) != nil
      else { return false }
      if customAuth == .header, customHeaderName.trimmingCharacters(in: .whitespaces).isEmpty {
        return false
      }
    }
    if requiresCredential && isCreate, credential.trimmingCharacters(in: .whitespaces).isEmpty {
      return false
    }
    if label.trimmingCharacters(in: .whitespaces).isEmpty, model.autoName(for: kind).isEmpty {
      return false
    }
    return selectedModelID != nil
      || !manualModelID.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    Form {
      if isCreate {
        createProviderSection
        credentialSection
        if isCustom {
          customWireSection
        }
        modelSection
        advancedSection
      } else {
        lockedProviderHeader
        credentialSection
        modelSection
        advancedSection
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
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { cancel() }
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
    }
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
        ForEach(ProviderKind.catalog, id: \.self) { candidate in
          Text(candidate.displayName).tag(candidate)
        }
        Text("OpenAI-compatible…").tag(ProviderKind.openAICompatible)
      }
      .onChange(of: selectedKind) { _, newValue in
        if newValue != .openAICompatible {
          baseURL = newValue.defaultEndpoint?.absoluteString ?? ""
          showNewProviderSection = false
        } else {
          baseURL = ""
        }
        isDirty = true
      }
    } header: {
      Text("Provider")
    } footer: {
      Text("One connection per API key. Add the same provider twice to use two keys.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var customWireSection: some View {
    Section {
      TextField("Display name", text: $customName)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: customName) { _, _ in isDirty = true }
      TextField("https://example.com/v1", text: $customBaseURL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .onChange(of: customBaseURL) { _, _ in isDirty = true }
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
    } header: {
      Text("OpenAI-Compatible Server")
    } footer: {
      Text("HTTPS is required for internet hosts; HTTP only for private or loopback addresses.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var credentialSection: some View {
    Section {
      if isCreate {
        if requiresCredential {
          SecureField("Paste your API key", text: $credential)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: credential) { _, _ in isDirty = true }
        } else {
          Label("No API key required", systemImage: "checkmark.shield")
        }
      } else if requiresCredential {
        if hasStoredCredential && !replaceCredential {
          HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
              .foregroundStyle(theme.secondaryForegroundColor)
            VStack(alignment: .leading, spacing: 3) {
              Text("API Key").font(.system(size: 15, weight: .medium))
              Text("Saved securely in Keychain")
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
            }
            Spacer()
            Button("Replace") { replaceCredential = true }
              .font(.system(size: 14, weight: .semibold))
          }
        } else {
          SecureField(hasStoredCredential ? "New API key" : "API key", text: $credential)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: credential) { _, _ in isDirty = true }
        }
      } else {
        Label("This provider does not require an API key.", systemImage: "checkmark.shield")
      }
    } header: {
      Text("API Key")
    } footer: {
      if requiresCredential {
        Text(
          "Stored in Keychain and sent only to \(providerTitle) when BYOKchat makes a request."
        )
        .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var modelSection: some View {
    Section {
      if kind != .nvidia && (isCreate ? customModelsPathIsValid : true) {
        Button {
          fetchModels()
        } label: {
          HStack {
            Label("Fetch Models", systemImage: "arrow.clockwise")
            Spacer()
            if isDiscoveryRunning { ProgressView().controlSize(.small) }
            if !discoveredModels.isEmpty {
              Text("\(discoveredModels.count)").foregroundStyle(theme.secondaryForegroundColor)
            }
          }
        }
        .disabled(isDiscoveryRunning || (requiresCredential && !keyAvailableForDiscovery))
      }

      modelSelectionRow

      if let warning = discoveryWarning {
        Label(warning, systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    } header: {
      Text("Models")
    } footer: {
      Text("New chats start with the default model you pick here.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var customModelsPathIsValid: Bool {
    !customModelsPath.trimmingCharacters(in: .whitespaces).isEmpty || isCustom == false
  }

  private var keyAvailableForDiscovery: Bool {
    isCreate ? !credential.trimmingCharacters(in: .whitespaces).isEmpty : true
  }

  @ViewBuilder
  private var modelSelectionRow: some View {
    let records = modelRecords
    if records.isEmpty {
      TextField("Model ID", text: $manualModelID)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: manualModelID) { _, _ in isDirty = true }
      Text("Fetch models or enter a model ID manually.")
        .font(.caption)
        .foregroundStyle(theme.secondaryForegroundColor)
    } else {
      Picker("Default model", selection: $selectedModelID) {
        ForEach(records) { record in
          Text(record.model.displayName).tag(Optional(record.model.id))
        }
        if let current = selectedModelID, !records.contains(where: { $0.model.id == current }) {
          Text(current.rawValue).tag(Optional(current))
        }
      }
    }
  }

  private var modelRecords: [AccountModelRecord] {
    var records: [AccountModelRecord] = []
    if let existing {
      records = model.models(for: existing.id).filter(\.isAvailable)
    }
    let discovered = discoveredModels.map {
      AccountModelRecord(
        accountID: existing?.id ?? "",
        model: $0, isManual: false, isAvailable: true)
    }
    let known = Set(records.map(\.model.id))
    records.append(contentsOf: discovered.filter { !known.contains($0.model.id) })
    let manual = manualModelID.trimmingCharacters(in: .whitespaces)
    if !manual.isEmpty {
      let manualID = ModelID(rawValue: manual)
      if !records.contains(where: { $0.model.id == manualID }) {
        records.append(
          AccountModelRecord(
            accountID: existing?.id ?? "",
            model: ProviderModel(
              providerID: existing?.providerID ?? kind.defaultProviderID ?? "",
              id: manualID, displayName: manual),
            isManual: true, isAvailable: true))
      }
    }
    return records
  }

  private var advancedSection: some View {
    Section {
      DisclosureGroup("Advanced") {
        VStack(alignment: .leading, spacing: 10) {
          Text("Endpoint Override")
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.secondaryForegroundColor)
          TextField(
            endpointPlaceholder,
            text: $baseURL
          )
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .onChange(of: baseURL) { _, _ in isDirty = true }

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

          Text("Name")
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.secondaryForegroundColor)
          TextField(autoNamePlaceholder, text: $label)
            .onChange(of: label) { _, _ in isDirty = true }
        }
        .padding(.vertical, 6)
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var endpointPlaceholder: String {
    if isCustom { return "Endpoint (required)" }
    return kind.defaultEndpoint?.absoluteString ?? "Provider default"
  }

  private var autoNamePlaceholder: String {
    isCreate ? model.autoName(for: kind) : existing?.label ?? ""
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

  private var deleteSection: some View {
    Section {
      Button("Delete Connection", systemImage: "trash", role: .destructive) {
        showDelete = true
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  // MARK: - Actions

  private func fetchModels() {
    isDiscoveryRunning = true
    discoveryWarning = nil
    Task { @MainActor in
      defer { isDiscoveryRunning = false }
      if let existing {
        guard await model.refreshModelsResult(accountID: existing.id) else {
          discoveryWarning = model.errorMessage ?? "Model discovery failed."
          model.errorMessage = nil
          return
        }
      } else {
        guard let endpoint = URL(string: baseURL.trimmingCharacters(in: .whitespaces)) else {
          discoveryWarning = "Enter a valid endpoint to fetch models."
          return
        }
        let definition = draftDefinition
        let resolved = ResolvedProviderAccount(
          kind: kind,
          id: "",
          providerID: definition.id,
          label: label.isEmpty ? model.autoName(for: kind) : label,
          apiKey: credential.isEmpty ? nil : credential,
          baseURLOverride: endpoint,
          additionalHeaders: (try? parseHeadersStrict(headersText)) ?? [:],
          metadata: [:],
          chatCompletionsPath: isCustom ? customChatPath : nil,
          modelsPath: isCustom ? customModelsPath : nil,
          authChoice: isCustom ? draftDefinition.authentication : nil,
          seedModelIDs: []
        )
        do {
          discoveredModels = try await model.previewModels(for: resolved)
        } catch {
          discoveryWarning =
            "Model discovery failed. Enter a model ID manually to continue."
        }
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

    var metadata: [String: String] = existing?.metadata ?? [:]
    if kind.extraCredentialFields.contains(.appTitle) {
      let title = appTitle.trimmingCharacters(in: .whitespaces)
      let referer = httpReferer.trimmingCharacters(in: .whitespaces)
      if title.isEmpty { metadata.removeValue(forKey: "appTitle") } else {
        metadata["appTitle"] = title
      }
      if referer.isEmpty { metadata.removeValue(forKey: "httpReferer") } else {
        metadata["httpReferer"] = referer
      }
    }

    let resolvedModelID: ModelID? = selectedModelID ?? {
      let manual = manualModelID.trimmingCharacters(in: .whitespaces)
      return manual.isEmpty ? nil : ModelID(rawValue: manual)
    }()

    let finalLabel =
      label.trimmingCharacters(in: .whitespaces).isEmpty
      ? model.autoName(for: kind) : label

    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      if let existing {
        guard let resolvedModelID else { return }
        guard await model.updateAccount(
          accountID: existing.id,
          label: finalLabel,
          newCredential: credential.isEmpty ? nil : credential,
          baseURLString: baseURL,
          headers: parsedHeaders,
          metadata: metadata
        ) else { return }
        if existing.defaultModelID != resolvedModelID {
          await model.setDefaultModel(resolvedModelID, accountID: existing.id)
        }
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
            ? customChatPath.trimmingCharacters(in: .whitespaces) : nil,
          modelsPath: isCustom ? customModelsPath.trimmingCharacters(in: .whitespaces) : nil,
          authChoice: isCustom ? draftDefinition.authentication : nil,
          seedModelIDs: []
        )
        guard created != nil else { return }
      }
      dismiss()
      onFinished?()
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
}
