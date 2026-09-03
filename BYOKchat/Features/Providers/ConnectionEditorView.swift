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
  @State private var isRevealingCredential = false
  @State private var revealedCredential: String?
  @State private var showModelPicker = false
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
    // Name: the field is pre-filled, so it is normally non-empty. Custom
    // providers must have a typed server name to suggest from.
    if label.trimmingCharacters(in: .whitespaces).isEmpty,
      suggestedName.isEmpty
    {
      return false
    }
    return selectedModelID != nil
      || !manualModelID.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    Form {
      if isCreate {
        createProviderSection
        nameSection
        credentialSection
        if isCustom {
          customWireSection
        }
        modelSection
        advancedSection
      } else {
        lockedProviderHeader
        nameSection
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
    .sheet(isPresented: $showModelPicker) {
      ConnectionModelPickerView(
        records: pickerRecords,
        selection: $selectedModelID
      )
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
      // Custom server name typed while the name still tracks.
      guard isCreate, !didEditName, kind == .openAICompatible else { return }
      label = suggestedName
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
        // Reset name tracking so the suggestion re-fills for the new
        // provider (no user text to preserve — the field was tracking).
        if !didEditName { label = "" }
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
          credentialField
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
              revealedCredential = nil
            }
            .font(.system(size: 14, weight: .semibold))
          }
        } else {
          credentialField
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

  @ViewBuilder
  private var credentialField: some View {
    // Reveal-while-typing: eye toggles between SecureField and TextField for
    // the credential being entered (create or replace).
    if isCredentialVisible {
      TextField("API key", text: $credential)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: credential) { _, _ in isDirty = true }
    } else {
      SecureField(hasStoredCredential ? "New API key" : "Paste your API key", text: $credential)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: credential) { _, _ in isDirty = true }
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
    } else if isPushModelPicker {
      // Large catalogs (OpenRouter): push to a searchable picker; tapping a
      // model selects it and pops back.
      NavigationLink {
        ConnectionModelPickerView(records: pickerRecords, selection: $selectedModelID)
      } label: {
        LabeledContent("Default model") {
          VStack(alignment: .trailing, spacing: 2) {
            Text(selectedModelTitle)
              .foregroundStyle(theme.secondaryForegroundColor)
              .lineLimit(1)
            Text("\(records.count) available")
              .font(.caption2)
              .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
          }
        }
      }
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

  /// Push navigation for kinds whose catalogs are too large for a menu —
  /// OpenRouter aggregates every upstream provider's models.
  private var isPushModelPicker: Bool {
    kind == .openRouter
  }

  private var selectedModelTitle: String {
    let records = modelRecords
    if let selectedModelID,
      let match = records.first(where: { $0.model.id == selectedModelID })
    {
      return match.model.displayName
    }
    return "Choose model"
  }

  /// The records the picker page browses (discovered + stored + manual).
  private var pickerRecords: [AccountModelRecord] {
    modelRecords
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
        }
        .padding(.vertical, 6)
      }
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
        autoSelectFirstModelIfNeeded()
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
          label: label.isEmpty ? model.autoName(for: kind, customBase: customName) : label,
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
          autoSelectFirstModelIfNeeded()
        } catch {
          discoveryWarning =
            "Model discovery failed. Enter a model ID manually to continue."
        }
      }
    }
  }

  /// After a successful fetch, preselect the first available model unless
  /// the user already picked one (or typed a manual ID).
  private func autoSelectFirstModelIfNeeded() {
    guard selectedModelID == nil,
      manualModelID.trimmingCharacters(in: .whitespaces).isEmpty
    else { return }
    selectedModelID = modelRecords.first?.model.id
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

    // Single name path: the field is pre-filled with the suggestion, so
    // whatever is here (or a fallback recompute if somehow cleared) saves.
    let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
    let finalLabel = trimmedLabel.isEmpty
      ? model.autoName(for: kind, customBase: customName)
      : trimmedLabel
    guard !finalLabel.isEmpty else { return }

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

/// Full-page, searchable model picker used for large catalogs (OpenRouter)
/// and reachable from the inline menu path via the same component. Tap a row
/// to select and dismiss; favorites sort first.
struct ConnectionModelPickerView: View {
  let records: [AccountModelRecord]
  @Binding var selection: ModelID?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var searchText = ""

  private var filtered: [AccountModelRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = query.isEmpty
      ? records
      : records.filter {
        $0.model.displayName.localizedCaseInsensitiveContains(query)
          || $0.model.id.rawValue.localizedCaseInsensitiveContains(query)
      }
    return base.sorted { lhs, rhs in
      if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
      return lhs.model.displayName.localizedCaseInsensitiveCompare(rhs.model.displayName)
        == .orderedAscending
    }
  }

  var body: some View {
    List {
      if filtered.isEmpty {
        ContentUnavailableView.search(text: searchText)
          .listRowBackground(Color.clear)
      } else {
        ForEach(filtered) { record in
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
                HStack(spacing: 8) {
                  if let context = record.model.contextWindow {
                    Text("\(context.formatted(.number.notation(.compactName))) ctx")
                  }
                  if record.model.inputModalities.contains("image") {
                    Label("Vision", systemImage: "photo")
                  }
                  if record.model.inputModalities.contains("file") {
                    Label("Files", systemImage: "doc")
                  }
                }
                .font(.caption2)
                .foregroundStyle(theme.secondaryForegroundColor)
              }
              Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .listRowBackground(theme.surfaceColor)
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
