import BYOKchatProviderCore
import Foundation
import SwiftUI

struct MacTargetPickerView: View {
  @Bindable var providers: MacProviderModel
  let initialTarget: MacChatTarget?
  let onCommit: (MacChatTarget) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var accountID: ProviderAccountID?
  @State private var modelID: ModelID?
  @State private var reasoningEnabled = false
  @State private var effort: ReasoningEffort = .high
  @State private var searchText = ""
  @State private var isSaving = false
  @State private var showingProviders = false

  init(
    providers: MacProviderModel,
    initialTarget: MacChatTarget?,
    onCommit: @escaping (MacChatTarget) async -> Bool
  ) {
    self.providers = providers
    self.initialTarget = initialTarget
    self.onCommit = onCommit
    let seed = initialTarget ?? providers.preferredTarget()
    _accountID = State(initialValue: seed?.accountID)
    _modelID = State(initialValue: seed?.modelID)
    _reasoningEnabled = State(initialValue: seed?.reasoning?.enabled == true)
    _effort = State(initialValue: seed?.reasoning?.effort ?? .high)
  }

  private var readyAccounts: [ProviderAccount] {
    providers.accounts.filter { providers.isReady($0) }
  }

  private var records: [AccountModelRecord] {
    guard let accountID else { return [] }
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let values = providers.models(for: accountID)
    guard !query.isEmpty else { return values }
    return values.filter {
      $0.model.displayName.localizedCaseInsensitiveContains(query)
        || $0.model.id.rawValue.localizedCaseInsensitiveContains(query)
    }
  }

  private var supportsReasoning: Bool {
    guard let accountID, let modelID else { return false }
    return providers.supportsReasoning(accountID: accountID, modelID: modelID)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Provider & Model")
          .font(.title3.weight(.semibold))
        Spacer()
        Button("Manage Providers…") { showingProviders = true }
        Button("Cancel") { dismiss() }
        Button("Done") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(accountID == nil || modelID == nil || isSaving)
      }
      .padding(16)

      Divider()

      HSplitView {
        List(selection: Binding(
          get: { accountID },
          set: { value in
            guard let value else { return }
            selectAccount(value)
          }
        )) {
          ForEach(readyAccounts) { account in
            VStack(alignment: .leading, spacing: 2) {
              Text(account.label)
                .fontWeight(.medium)
              Text(account.kind == .openAICompatible ? "OpenAI-compatible" : account.kind.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .tag(account.id)
          }
        }
        .frame(minWidth: 180, idealWidth: 210, maxWidth: 240)

        VStack(spacing: 0) {
          HStack {
            Image(systemName: "magnifyingglass")
              .foregroundStyle(.secondary)
            TextField("Search models", text: $searchText)
              .textFieldStyle(.plain)
          }
          .padding(.horizontal, 12)
          .frame(height: 38)
          .background(Color.primary.opacity(0.04))

          Divider()

          if records.isEmpty {
            ContentUnavailableView(
              "No Models",
              systemImage: "cube",
              description: Text("Refresh or add models from Manage Providers.")
            )
          } else {
            List(selection: $modelID) {
              ForEach(records) { record in
                HStack(spacing: 10) {
                  VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                      Text(record.model.displayName)
                        .fontWeight(.medium)
                      if record.isFavorite {
                        Image(systemName: "star.fill")
                          .font(.caption2)
                          .foregroundStyle(.secondary)
                      }
                    }
                    Text(record.model.id.rawValue)
                      .font(.caption.monospaced())
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                  Spacer()
                }
                .opacity(record.isAvailable ? 1 : 0.45)
                .tag(record.model.id)
              }
            }
          }

          if supportsReasoning {
            Divider()
            HStack(spacing: 14) {
              Toggle("Reasoning", isOn: $reasoningEnabled)
                .toggleStyle(.switch)
              if reasoningEnabled {
                Picker("Effort", selection: $effort) {
                  ForEach(ReasoningEffort.allCases, id: \.rawValue) { value in
                    Text(reasoningTitle(value)).tag(value)
                  }
                }
                .labelsHidden()
                .frame(width: 120)
              }
              Spacer()
            }
            .padding(12)
          }
        }
        .frame(minWidth: 390)
      }
    }
    .frame(width: 680, height: 500)
    .sheet(isPresented: $showingProviders, onDismiss: repairSelection) {
      MacProviderManagementView(model: providers)
    }
    .onChange(of: modelID) { _, newValue in
      guard let accountID, let newValue else { return }
      if !providers.supportsReasoning(accountID: accountID, modelID: newValue) {
        reasoningEnabled = false
      }
    }
  }

  private func repairSelection() {
    guard let accountID,
      let account = providers.account(accountID),
      providers.isReady(account),
      let modelID,
      providers.models(for: accountID).contains(where: { $0.model.id == modelID && $0.isAvailable })
    else {
      let seed = providers.preferredTarget()
      self.accountID = seed?.accountID
      self.modelID = seed?.modelID
      reasoningEnabled = seed?.reasoning?.enabled == true
      effort = seed?.reasoning?.effort ?? .high
      return
    }
  }

  private func selectAccount(_ value: ProviderAccountID) {
    guard let account = providers.account(value) else { return }
    accountID = value
    modelID = account.defaultModelID
      ?? providers.models(for: value).first(where: { $0.isAvailable })?.model.id
    if let reasoning = account.kind.reasoningDefault,
      let modelID,
      providers.supportsReasoning(accountID: value, modelID: modelID)
    {
      reasoningEnabled = true
      effort = reasoning.effort ?? .high
    } else {
      reasoningEnabled = false
    }
  }

  private func save() {
    guard !isSaving, let accountID, let modelID else { return }
    isSaving = true
    let target = MacChatTarget(
      accountID: accountID,
      modelID: modelID,
      reasoning: supportsReasoning && reasoningEnabled
        ? ReasoningOptions(enabled: true, effort: effort)
        : nil
    )
    Task { @MainActor in
      if await onCommit(target) {
        dismiss()
      } else {
        isSaving = false
      }
    }
  }

  private func reasoningTitle(_ value: ReasoningEffort) -> String {
    switch value {
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .max: "Max"
    }
  }
}

enum MacConnectionEditorRoute: Identifiable {
  case create(ProviderKind)
  case edit(ProviderAccountID)

  var id: String {
    switch self {
    case .create(let kind): "create-\(kind.rawValue)"
    case .edit(let id): "edit-\(id.rawValue)"
    }
  }
}

struct MacConnectionEditorView: View {
  @Bindable var model: MacProviderModel
  let route: MacConnectionEditorRoute
  let onFinished: (ProviderAccountID?) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var label: String
  @State private var credential = ""
  @State private var baseURL: String
  @State private var chatPath: String
  @State private var modelsPath: String
  @State private var authMode: String
  @State private var customHeaderName: String
  @State private var headersText: String
  @State private var defaultModel: String
  @State private var seedModelsText: String
  @State private var appTitle: String
  @State private var httpReferer: String
  @State private var isSaving = false
  @State private var isRevealing = false
  @State private var showingAdvanced = false

  private var existing: ProviderAccount? {
    switch route {
    case .create: nil
    case .edit(let id): model.account(id)
    }
  }

  private var kind: ProviderKind {
    switch route {
    case .create(let kind): kind
    case .edit: existing?.kind ?? .openAICompatible
    }
  }

  init(
    model: MacProviderModel,
    route: MacConnectionEditorRoute,
    onFinished: @escaping (ProviderAccountID?) -> Void
  ) {
    self.model = model
    self.route = route
    self.onFinished = onFinished

    let account: ProviderAccount?
    switch route {
    case .create:
      account = nil
    case .edit(let id):
      account = model.account(id)
    }
    let kind: ProviderKind
    switch route {
    case .create(let value): kind = value
    case .edit: kind = account?.kind ?? .openAICompatible
    }

    _label = State(initialValue: account?.label ?? model.autoName(for: kind))
    _baseURL = State(initialValue: account?.baseURLOverride?.absoluteString ?? (kind == .openAICompatible ? "" : kind.defaultEndpoint?.absoluteString ?? ""))
    _chatPath = State(initialValue: account?.chatCompletionsPath ?? "/chat/completions")
    _modelsPath = State(initialValue: account?.modelsPath ?? "/models")
    let authentication = account?.authChoice ?? kind.authSpec.fixedAuthentication ?? .bearer
    switch authentication {
    case .bearer:
      _authMode = State(initialValue: "bearer")
      _customHeaderName = State(initialValue: "X-API-Key")
    case .header(let name):
      _authMode = State(initialValue: "header")
      _customHeaderName = State(initialValue: name)
    case .none:
      _authMode = State(initialValue: "none")
      _customHeaderName = State(initialValue: "X-API-Key")
    }
    _headersText = State(initialValue: serializeHeaders(account?.additionalHeaders ?? [:]))
    _defaultModel = State(initialValue: account?.defaultModelID?.rawValue ?? "")
    _seedModelsText = State(initialValue: (account?.seedModelIDs ?? []).joined(separator: "\n"))
    _appTitle = State(initialValue: account?.metadata["appTitle"] ?? "")
    _httpReferer = State(initialValue: account?.metadata["httpReferer"] ?? "")
    _showingAdvanced = State(initialValue: kind == .openAICompatible || account != nil)
  }

  private var isCreate: Bool {
    if case .create = route { return true }
    return false
  }

  private var requiresCredential: Bool {
    effectiveAuthentication != .none
  }

  private var effectiveAuthentication: ProviderAuthentication {
    if kind != .openAICompatible {
      return kind.authSpec.fixedAuthentication ?? .bearer
    }
    switch authMode {
    case "none": return .none
    case "header": return .header(name: customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines))
    default: return .bearer
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: providerSymbol(kind))
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.accent)
          .frame(width: 34, height: 34)
          .background(MacDesignTokens.Colors.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        VStack(alignment: .leading, spacing: 2) {
          Text(isCreate ? "Connect \(providerDisplayName(kind))" : "Edit Connection")
            .font(.title3.weight(.semibold))
          Text(isCreate ? "Configure the connection BYOKchat will use." : providerDisplayName(kind))
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(isCreate ? "Connect" : "Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave || isSaving)
      }
      .padding(16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          editorCard("Connection", systemImage: "link") {
            VStack(alignment: .leading, spacing: 10) {
              LabeledContent("Provider", value: providerDisplayName(kind))
              TextField("Connection Name", text: $label)
            }
          }

          editorCard("Authentication", systemImage: "key") {
            VStack(alignment: .leading, spacing: 10) {
              if kind == .openAICompatible {
                Picker("Authentication", selection: $authMode) {
                  Text("Bearer Token").tag("bearer")
                  Text("Custom Header").tag("header")
                  Text("None").tag("none")
                }
                if authMode == "header" {
                  TextField("Header Name", text: $customHeaderName)
                }
              }

              if requiresCredential {
                SecureField(
                  isCreate ? "API Key / Token" : "New API Key / Token (leave blank to keep current)",
                  text: $credential
                )
                if !isCreate, let accountID = existing?.id, model.hasCredential(accountID) {
                  HStack {
                    Label("Credential stored in Keychain", systemImage: "lock.fill")
                      .font(.caption)
                      .foregroundStyle(MacDesignTokens.Colors.textMuted)
                    Spacer()
                    Button(isRevealing ? "Revealing…" : "Reveal") { revealCredential() }
                      .disabled(isRevealing)
                  }
                } else {
                  Text("Credentials are stored in Keychain.")
                    .font(.caption)
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                }
              } else {
                Text("This connection does not require a credential.")
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
            }
          }

          if kind == .openAICompatible {
            editorCard("Endpoint", systemImage: "network") {
              VStack(alignment: .leading, spacing: 10) {
                TextField("Base URL", text: $baseURL)
                TextField("Chat Completions Path", text: $chatPath)
                TextField("Models Path (blank disables discovery)", text: $modelsPath)
                if isCreate {
                  TextField("Default Model ID (optional)", text: $defaultModel)
                }
                Text("HTTP and HTTPS endpoints are accepted, including private LAN and self-hosted servers.")
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
            }

            editorCard("Seed Models", systemImage: "cube") {
              VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $seedModelsText)
                  .font(.body.monospaced())
                  .frame(minHeight: 80)
                Text("Optional model IDs, one per line. Discovery can also be refreshed after saving.")
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
            }
          } else {
            DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
              VStack(spacing: 12) {
                editorCard("Endpoint Override", systemImage: "network") {
                  VStack(alignment: .leading, spacing: 8) {
                    TextField("Base URL Override", text: $baseURL)
                    Text("Leave unchanged to use the provider default endpoint.")
                      .font(.caption)
                      .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  }
                }

                if isCreate {
                  editorCard("Default Model", systemImage: "cube") {
                    TextField("Default Model ID (optional)", text: $defaultModel)
                  }
                }
              }
              .padding(.top, 10)
            }
            .font(.headline)
          }

          editorCard("Custom Headers", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 8) {
              TextEditor(text: $headersText)
                .font(.body.monospaced())
                .frame(minHeight: 80)
              Text("One header per line: Name: Value")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
          }

          if kind == .openRouter {
            editorCard("OpenRouter", systemImage: "arrow.triangle.branch") {
              VStack(alignment: .leading, spacing: 10) {
                TextField("App Title", text: $appTitle)
                TextField("HTTP Referer", text: $httpReferer)
              }
            }
          }
        }
        .padding(16)
      }
    }
    .frame(width: 620, height: kind == .openAICompatible ? 720 : 620)
    .background(MacDesignTokens.Colors.canvas)
  }

  private var canSave: Bool {
    guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    if kind == .openAICompatible {
      guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
        let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
      else { return false }
      if authMode == "header" && customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return false
      }
    }
    if isCreate && requiresCredential && credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return false
    }
    return true
  }

  private func save() {
    guard canSave, !isSaving else { return }
    let headers: [String: String]
    do {
      headers = try parseHeaders(headersText)
    } catch {
      model.errorMessage = error.localizedDescription
      return
    }

    var metadata: [String: String] = existing?.metadata ?? [:]
    if kind == .openRouter {
      metadata.removeValue(forKey: "appTitle")
      metadata.removeValue(forKey: "httpReferer")
      let title = appTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      let referer = httpReferer.trimmingCharacters(in: .whitespacesAndNewlines)
      if !title.isEmpty { metadata["appTitle"] = title }
      if !referer.isEmpty { metadata["httpReferer"] = referer }
    }

    let seedModels = parseSeedModels(seedModelsText)
    isSaving = true

    Task { @MainActor in
      switch route {
      case .create:
        let id = await model.createConnection(
          kind: kind,
          label: label,
          credential: credential,
          baseURL: kind == .openAICompatible ? baseURL : normalizedBuiltInOverride,
          defaultModel: defaultModel,
          headers: headers,
          metadata: metadata,
          chatCompletionsPath: kind == .openAICompatible ? chatPath : nil,
          modelsPath: kind == .openAICompatible ? modelsPath : nil,
          authChoice: kind == .openAICompatible ? effectiveAuthentication : nil,
          seedModelIDs: kind == .openAICompatible && !seedModels.isEmpty ? seedModels : nil
        )
        if let id {
          onFinished(id)
          dismiss()
        } else {
          isSaving = false
        }

      case .edit(let accountID):
        let succeeded = await model.updateConnection(
          accountID: accountID,
          label: label,
          newCredential: credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : credential,
          baseURL: kind == .openAICompatible ? baseURL : normalizedBuiltInOverride,
          headers: headers,
          metadata: metadata,
          chatCompletionsPath: kind == .openAICompatible ? chatPath : nil,
          modelsPath: kind == .openAICompatible ? modelsPath : nil,
          authChoice: kind == .openAICompatible ? effectiveAuthentication : nil,
          seedModelIDs: kind == .openAICompatible && !seedModels.isEmpty ? seedModels : nil
        )
        if succeeded {
          onFinished(accountID)
          dismiss()
        } else {
          isSaving = false
        }
      }
    }
  }

  private var normalizedBuiltInOverride: String {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let defaultURL = kind.defaultEndpoint?.absoluteString else { return trimmed }
    return trimmed == defaultURL ? "" : trimmed
  }

  private func revealCredential() {
    guard let accountID = existing?.id else { return }
    isRevealing = true
    Task { @MainActor in
      if let value = await model.revealCredential(accountID: accountID) {
        credential = value
      }
      isRevealing = false
    }
  }

  private func editorCard<Content: View>(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      Label(title, systemImage: systemImage)
        .font(.headline)
      content()
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

private enum MacProviderEditorError: LocalizedError {
  case invalidHeader(String)

  var errorDescription: String? {
    switch self {
    case .invalidHeader(let line): "Invalid header line: \(line)"
    }
  }
}

private func parseHeaders(_ text: String) throws -> [String: String] {
  var result: [String: String] = [:]
  for rawLine in text.split(whereSeparator: \.isNewline) {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { continue }
    guard let separator = line.firstIndex(of: ":") else {
      throw MacProviderEditorError.invalidHeader(line)
    }
    let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
    let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !value.isEmpty else {
      throw MacProviderEditorError.invalidHeader(line)
    }
    result[name] = value
  }
  return result
}

private func serializeHeaders(_ headers: [String: String]) -> String {
  headers.keys.sorted().map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n")
}

private func parseSeedModels(_ text: String) -> [String] {
  var seen: Set<String> = []
  var values: [String] = []
  for component in text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ","))) {
    let value = component.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, seen.insert(value).inserted else { continue }
    values.append(value)
  }
  return values
}

func providerSymbol(_ kind: ProviderKind) -> String {
  switch kind {
  case .anthropic: "a.circle.fill"
  case .openai: "circle.hexagongrid.fill"
  case .gemini: "sparkles"
  case .deepSeek: "wave.3.right.circle.fill"
  case .openRouter: "arrow.triangle.branch"
  case .nvidia: "memorychip.fill"
  case .openAICompatible: "server.rack"
  }
}

private func providerDisplayName(_ kind: ProviderKind) -> String {
  kind == .openAICompatible ? "OpenAI-compatible" : kind.displayName
}
