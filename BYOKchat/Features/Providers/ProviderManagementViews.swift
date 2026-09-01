import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

/// Custom provider definition editor shared by connection setup and custom
/// provider maintenance. `ConnectionsView` is the single user-facing provider
/// management surface.
struct CustomProviderEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @Bindable var model: ProviderManagementModel
  let existing: ProviderDefinition?
  let onSaved: ((ProviderID) -> Void)?

  @State private var providerID: String
  @State private var name: String
  @State private var baseURL: String
  @State private var chatPath: String
  @State private var modelsPath: String
  @State private var authentication: AuthenticationChoice
  @State private var headerName: String
  @State private var seedModels: String

  init(
    model: ProviderManagementModel,
    existing: ProviderDefinition? = nil,
    onSaved: ((ProviderID) -> Void)? = nil
  ) {
    self.model = model
    self.existing = existing
    self.onSaved = onSaved
    _providerID = State(initialValue: existing?.id.rawValue ?? "custom.")
    _name = State(initialValue: existing?.displayName ?? "")
    _baseURL = State(initialValue: existing?.defaultBaseURL.absoluteString ?? "")
    _chatPath = State(initialValue: existing?.chatCompletionsPath ?? "/chat/completions")
    _modelsPath = State(initialValue: existing?.modelsPath ?? "/models")
    _authentication = State(initialValue: Self.authenticationChoice(existing?.authentication))
    if let existingAuthentication = existing?.authentication,
      case .header(let header) = existingAuthentication
    {
      _headerName = State(initialValue: header)
    } else {
      _headerName = State(initialValue: "X-API-Key")
    }
    _seedModels = State(
      initialValue: existing?.seedModels.map(\.id.rawValue).joined(separator: "\n") ?? ""
    )
  }

  var body: some View {
    Form {
      Section("Identity") {
        TextField("Provider ID", text: $providerID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .disabled(existing != nil)
        TextField("Display name", text: $name)
      }
      .listRowBackground(theme.surfaceColor)

      Section {
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
      } header: {
        Text("Endpoint")
      } footer: {
        Text("HTTPS is required for internet hosts. HTTP is accepted only when the host resolves to a private or loopback network address.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

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
      .listRowBackground(theme.surfaceColor)

      Section {
        TextEditor(text: $seedModels)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 100)
      } header: {
        Text("Seed Models")
      } footer: {
        Text("One model ID per line. Seed models remain usable when the provider does not expose model discovery.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle(existing == nil ? "Custom Provider" : "Edit Provider")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(model.isBusy || !canSave)
      }
    }
  }

  private var canSave: Bool {
    !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (authentication != .header
        || !headerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private func save() {
    let auth: ProviderAuthentication =
      switch authentication {
      case .bearer: .bearer
      case .header: .header(name: headerName.trimmingCharacters(in: .whitespacesAndNewlines))
      case .none: .none
      }
    let seeds = seedModels
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let normalizedID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowsLocalHTTP = URL(string: normalizedBaseURL)?.scheme?.lowercased() == "http"

    Task { @MainActor in
      let success = await model.createCustomProvider(
        id: normalizedID,
        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        baseURL: normalizedBaseURL,
        chatPath: chatPath.trimmingCharacters(in: .whitespacesAndNewlines),
        modelsPath: modelsPath.trimmingCharacters(in: .whitespacesAndNewlines),
        authentication: auth,
        seedModels: seeds,
        allowsLocalHTTP: allowsLocalHTTP
      )
      guard success else { return }
      onSaved?(ProviderID(rawValue: normalizedID))
      dismiss()
    }
  }

  private static func authenticationChoice(_ value: ProviderAuthentication?) -> AuthenticationChoice {
    guard let value else { return .bearer }
    switch value {
    case .bearer: return .bearer
    case .header: return .header
    case .none: return .none
    }
  }
}

struct CustomProviderManagementView: View {
  @Bindable var model: ProviderManagementModel
  let providerID: ProviderID

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var showEdit = false
  @State private var showDelete = false

  private var definition: ProviderDefinition? {
    model.provider(for: providerID)
  }

  private var accounts: [ProviderAccount] {
    model.accounts(for: providerID)
  }

  var body: some View {
    Group {
      if let definition {
        List {
          Section("Provider") {
            LabeledContent("Name", value: definition.displayName)
            LabeledContent("ID", value: definition.id.rawValue)
            LabeledContent("Endpoint", value: definition.defaultBaseURL.absoluteString)
            LabeledContent("Chat path", value: definition.chatCompletionsPath)
            LabeledContent("Models", value: definition.modelsPath ?? "Manual / seed models")
            LabeledContent("Authentication", value: authenticationName(definition.authentication))
          }
          .listRowBackground(theme.surfaceColor)

          Section("Usage") {
            LabeledContent("Connections", value: "\(accounts.count)")
            if definition.allowsLocalHTTP {
              Label("Private-network HTTP allowed", systemImage: "network")
                .foregroundStyle(theme.secondaryForegroundColor)
            }
          }
          .listRowBackground(theme.surfaceColor)

          Section {
            Button("Edit Provider", systemImage: "pencil") {
              showEdit = true
            }
          }
          .listRowBackground(theme.surfaceColor)

          Section {
            Button("Delete Custom Provider", systemImage: "trash", role: .destructive) {
              showDelete = true
            }
            .disabled(!accounts.isEmpty)
          } footer: {
            Text(accounts.isEmpty
              ? "Deleting the provider removes its definition from this device."
              : "Delete the \(accounts.count) connection\(accounts.count == 1 ? "" : "s") using this provider first.")
              .foregroundStyle(theme.secondaryForegroundColor)
          }
          .listRowBackground(theme.surfaceColor)
        }
        .scrollContentBackground(.hidden)
      } else {
        ContentUnavailableView("Provider Missing", systemImage: "server.rack")
      }
    }
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle(definition?.displayName ?? "Custom Provider")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showEdit) {
      if let definition {
        NavigationStack {
          CustomProviderEditorView(model: model, existing: definition)
        }
      }
    }
    .confirmationDialog("Delete this custom provider?", isPresented: $showDelete) {
      Button("Delete Provider", role: .destructive) {
        Task { @MainActor in
          await model.deleteCustomProvider(providerID)
          if model.provider(for: providerID) == nil {
            dismiss()
          }
        }
      }
      Button("Cancel", role: .cancel) {}
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
