import BYOKchatProviderCore
import SwiftUI

private enum ProjectAccentOption: String, CaseIterable, Identifiable {
  case blue, indigo, purple, pink, orange, teal, green

  var id: String { rawValue }

  var title: String {
    rawValue.capitalized
  }

  var color: Color {
    switch self {
    case .blue: .blue
    case .indigo: .indigo
    case .purple: .purple
    case .pink: .pink
    case .orange: .orange
    case .teal: .teal
    case .green: .green
    }
  }
}

extension ChatProject {
  var projectColor: Color {
    ProjectAccentOption(rawValue: accentID)?.color ?? .blue
  }
}

struct ProjectIconView: View {
  let project: ChatProject
  var size: CGFloat = 28

  var body: some View {
    Image(systemName: project.symbolName)
      .font(.system(size: size * 0.45, weight: .semibold))
      .foregroundStyle(project.projectColor)
      .frame(width: size, height: size)
      .background(project.projectColor.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3))
      .accessibilityHidden(true)
  }
}

struct ProjectEditorView: View {
  let existing: ChatProject?
  @Bindable var projects: ProjectManagementModel
  @Bindable var providers: ProviderManagementModel

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var symbolName: String
  @State private var accentID: String
  @State private var accountID: ProviderAccountID?
  @State private var modelID: ModelID?
  @State private var instructions: String
  @State private var isSaving = false

  private let symbols = [
    "folder.fill",
    "briefcase.fill",
    "hammer.fill",
    "terminal.fill",
    "doc.text.fill",
    "lightbulb.fill",
    "paintbrush.fill",
    "shippingbox.fill",
  ]

  init(
    project: ChatProject? = nil,
    projects: ProjectManagementModel,
    providers: ProviderManagementModel
  ) {
    self.existing = project
    self.projects = projects
    self.providers = providers
    _name = State(initialValue: project?.name ?? "")
    _symbolName = State(initialValue: project?.symbolName ?? "folder.fill")
    _accentID = State(initialValue: project?.accentID ?? "blue")
    _accountID = State(initialValue: project?.accountID)
    _modelID = State(initialValue: project?.modelID)
    _instructions = State(initialValue: project?.instructions ?? "")
  }

  private var enabledAccounts: [ProviderAccount] {
    providers.accounts.filter(\.isEnabled)
  }

  private var selectedAccount: ProviderAccount? {
    guard let accountID else { return nil }
    return enabledAccounts.first { $0.id == accountID }
  }

  private var availableModels: [AccountModelRecord] {
    guard let accountID else { return [] }
    return providers.models(for: accountID).filter(\.isAvailable)
  }

  private var canSave: Bool {
    !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (accountID == nil || selectedAccount != nil)
      && (accountID == nil || modelID == nil || availableModels.contains(where: { $0.model.id == modelID }))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Project") {
          TextField("Name", text: $name)

          Picker("Icon", selection: $symbolName) {
            ForEach(symbols, id: \.self) { symbol in
              Label(symbolTitle(symbol), systemImage: symbol)
                .tag(symbol)
            }
          }

          Picker("Color", selection: $accentID) {
            ForEach(ProjectAccentOption.allCases) { option in
              Label {
                Text(option.title)
              } icon: {
                Image(systemName: "circle.fill")
                  .foregroundStyle(option.color)
              }
              .tag(option.rawValue)
            }
          }
        }

        Section {
          Picker("Provider account", selection: $accountID) {
            Text("App Default").tag(nil as ProviderAccountID?)
            ForEach(enabledAccounts) { account in
              Text(account.label).tag(Optional(account.id))
            }
          }

          if accountID != nil {
            Picker("Model", selection: $modelID) {
              Text("Account Default").tag(nil as ModelID?)
              ForEach(availableModels) { record in
                Text(record.model.displayName).tag(Optional(record.model.id))
              }
            }
          }
        } header: {
          Text("New Chat Defaults")
        } footer: {
          Text("Project defaults apply when a new chat is created in this project. Existing chats keep their current provider and model.")
        }

        Section {
          TextEditor(text: $instructions)
            .frame(minHeight: 150)
        } header: {
          Text("Instructions")
        } footer: {
          Text("Used as the system prompt for new chats in this project. Leave blank to use the app default system prompt.")
        }
      }
      .navigationTitle(existing == nil ? "New Project" : "Edit Project")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(!canSave)
        }
      }
      .onChange(of: accountID) { _, newValue in
        guard let newValue else {
          modelID = nil
          return
        }
        let models = providers.models(for: newValue).filter(\.isAvailable)
        if let modelID, !models.contains(where: { $0.model.id == modelID }) {
          self.modelID = nil
        }
      }
      .overlay {
        if isSaving {
          ProgressView()
            .padding(12)
            .background(.regularMaterial, in: Capsule())
        }
      }
    }
  }

  private func save() {
    guard canSave else { return }
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      let succeeded: Bool
      if let existing {
        succeeded = await projects.updateProject(
          id: existing.id,
          name: name,
          symbolName: symbolName,
          accentID: accentID,
          accountID: accountID,
          modelID: modelID,
          instructions: instructions
        )
      } else {
        succeeded = await projects.createProject(
          name: name,
          symbolName: symbolName,
          accentID: accentID,
          accountID: accountID,
          modelID: modelID,
          instructions: instructions
        ) != nil
      }
      if succeeded { dismiss() }
    }
  }

  private func symbolTitle(_ symbol: String) -> String {
    switch symbol {
    case "folder.fill": "Folder"
    case "briefcase.fill": "Work"
    case "hammer.fill": "Build"
    case "terminal.fill": "Code"
    case "doc.text.fill": "Writing"
    case "lightbulb.fill": "Ideas"
    case "paintbrush.fill": "Creative"
    case "shippingbox.fill": "Product"
    default: "Project"
    }
  }
}
