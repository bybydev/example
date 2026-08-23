import AppFoundation
import BYOKchatProviderCore
import SwiftUI

extension NewChatView {
  @ViewBuilder
  var emptyStateContent: some View {
    switch readiness {
    case .ready:
      if let project {
        projectReadyContent(project)
      } else {
        readyChatContent
      }
    case .noConnection, .missingCredential, .noModel:
      setupContent
    }
  }

  var readyChatContent: some View {
    VStack(spacing: 18) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(theme.accentColor)
        .accessibilityHidden(true)
      Text("How can I help?")
        .font(.system(size: 30, weight: .semibold))
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
  }

  func projectReadyContent(_ project: ChatProject) -> some View {
    VStack(spacing: 14) {
      ProjectIconView(project: project, size: 44)
      Text(project.name)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(project.projectColor)
      Text("What are we working on?")
        .font(.system(size: 28, weight: .semibold))
        .multilineTextAlignment(.center)
      Text(projectContextSummary)
        .font(.system(size: 15))
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.secondaryForegroundColor)
      targetChip

      if !project.projectPromptPresets.isEmpty {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
          ForEach(Array(project.projectPromptPresets.prefix(4))) { preset in
            Button { applyPromptPreset(preset) } label: {
              HStack(spacing: 9) {
                Image(systemName: "text.bubble")
                  .foregroundStyle(theme.accentColor)
                Text(preset.name)
                  .lineLimit(2)
                Spacer(minLength: 0)
              }
              .font(.system(size: 14, weight: .medium))
              .multilineTextAlignment(.leading)
              .padding(.horizontal, 14)
              .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
              .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
              .overlay {
                RoundedRectangle(cornerRadius: 14)
                  .stroke(Color.primary.opacity(0.08), lineWidth: 1)
              }
            }
            .buttonStyle(.plain)
          }
        }
        .frame(maxWidth: 480)
      }
    }
    .frame(maxWidth: .infinity)
  }

  var setupContent: some View {
    VStack(spacing: 16) {
      Image(systemName: setupIcon)
        .font(.system(size: 32, weight: .medium))
        .foregroundStyle(theme.accentColor)
        .accessibilityHidden(true)
      Text(setupTitle)
        .font(.system(size: 28, weight: .semibold))
        .multilineTextAlignment(.center)
      Text(setupDescription)
        .font(.system(size: 15))
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.secondaryForegroundColor)
        .frame(maxWidth: 440)

      Button { primarySetupAction() } label: {
        Label(primarySetupTitle, systemImage: primarySetupIcon)
          .font(.system(size: 16, weight: .semibold))
          .frame(maxWidth: 320)
          .padding(.vertical, 12)
      }
      .buttonStyle(.borderedProminent)
      .tint(theme.accentColor)

      Text("Connections keep your provider, API key, and default model together in one place.")
        .font(.caption)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
        .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity)
  }

  var targetChip: some View {
    Button { showTargetPicker = true } label: {
      HStack(spacing: 7) {
        Image(systemName: "sparkles")
        Text(targetSummary)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
      }
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(theme.secondaryForegroundColor)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(.thinMaterial, in: Capsule())
    }
    .buttonStyle(.plain)
  }

  func starterActionButton(_ action: StarterAction) -> some View {
    Button { applyStarterAction(action) } label: {
      HStack(spacing: 9) {
        Image(systemName: action.systemImage)
          .foregroundStyle(theme.accentColor)
        Text(action.title)
          .lineLimit(2)
        Spacer(minLength: 0)
      }
      .font(.system(size: 14, weight: .medium))
      .multilineTextAlignment(.leading)
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
  }

  var setupIcon: String {
    switch readiness {
    case .noConnection: "link"
    case .missingCredential: "key.slash"
    case .noModel: "rectangle.stack.badge.plus"
    case .ready: "bubble.left.and.bubble.right"
    }
  }

  var setupTitle: String {
    switch readiness {
    case .noConnection:
      return project == nil ? "Connect your AI" : "Set up a connection"
    case .missingCredential:
      return "Finish setting up \(defaultProvider?.displayName ?? defaultAccount?.label ?? "connection")"
    case .noModel:
      return "Choose a model"
    case .ready:
      return "How can I help?"
    }
  }

  var setupDescription: String {
    switch readiness {
    case .noConnection:
      if let project {
        return "Add a connection before starting a chat in \(project.name)."
      }
      return "Connect an AI provider with your own API key to start chatting."
    case .missingCredential:
      return "\(defaultAccount?.label ?? "This connection") needs an API key before it can be used."
    case .noModel:
      if let project, project.modelID != nil {
        return "The model selected for \(project.name) is no longer available. Choose another project model."
      }
      return "Choose a default model for \(defaultAccount?.label ?? "this connection") before starting a chat."
    case .ready:
      return ""
    }
  }

  var primarySetupTitle: String {
    switch readiness {
    case .noConnection: "Set Up Connection"
    case .missingCredential, .noModel: "Open Connections"
    case .ready: "Start Chatting"
    }
  }

  var primarySetupIcon: String {
    switch readiness {
    case .noConnection: "plus.circle.fill"
    case .missingCredential: "key.fill"
    case .noModel: "rectangle.stack.fill"
    case .ready: "arrow.up.circle.fill"
    }
  }

  func primarySetupAction() {
    switch readiness {
    case .noConnection, .missingCredential, .noModel:
      if (project?.accountID != nil && defaultAccount == nil)
        || (project?.modelID != nil && defaultModelID == nil)
      {
        showProjectEditor = true
      } else {
        showConnections = true
      }
    case .ready:
      break
    }
  }

  func openCurrentTarget() {
    switch readiness {
    case .ready:
      showTargetPicker = true
    case .noConnection, .missingCredential, .noModel:
      if (project?.accountID != nil && defaultAccount == nil)
        || (project?.modelID != nil && defaultModelID == nil)
      {
        showProjectEditor = true
      } else {
        showConnections = true
      }
    }
  }

  func isConnectionReady(_ account: ProviderAccount) -> Bool {
    if providerRequiresCredential(account.providerID),
      !providers.credentialAccountIDs.contains(account.id)
    {
      return false
    }
    let models = providers.models(for: account.id).filter(\.isAvailable)
    if let modelID = account.defaultModelID,
      models.contains(where: { $0.model.id == modelID })
    {
      return true
    }
    return !models.isEmpty
  }

  func providerRequiresCredential(_ providerID: ProviderID) -> Bool {
    guard let provider = providers.provider(for: providerID) else { return true }
    switch provider.authentication {
    case .none: return false
    case .bearer, .header: return true
    }
  }

  func applyStarterAction(_ action: StarterAction) {
    switch action.kind {
    case .draft(let value):
      draft = value
    case .photo:
      showPhotoPicker = true
    case .file:
      showFileImporter = true
    }
  }

  var projectContextSummary: String {
    guard let project else { return "" }
    var parts = ["Uses project defaults and instructions"]
    if !project.projectFiles.isEmpty {
      parts.append(
        "\(project.projectFiles.count) reference file\(project.projectFiles.count == 1 ? "" : "s")"
      )
    }
    if let configuration = project.mcpConfiguration, !configuration.enabledServerIDs.isEmpty {
      parts.append("project tools")
    }
    return parts.joined(separator: " · ")
  }

  func applyPromptPreset(_ preset: ProjectPromptPreset) {
    let value = preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      draft = value
    } else {
      draft += "\n\n" + value
    }
  }

  func startConversation() {
    let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = pendingAttachments
    guard !normalized.isEmpty || !attachments.isEmpty else { return }
    guard !isCreating else { return }
    guard canStartConversation, defaultAccount != nil, defaultModelID != nil else { return }

    isCreating = true
    Task { @MainActor in
      defer { isCreating = false }
      guard let id = await chats.createConversation(projectID: projectID) else { return }
      await projects.reloadFromStorage()
      await mcp.reloadFromStorage()

      if let targetOverride,
        let account = providers.accounts.first(where: { $0.id == targetOverride.accountID }),
        let created = chats.conversation(id)
      {
        var options = created.options
        options.reasoning = targetOverride.reasoning
        guard await chats.updateTarget(
          conversationID: id,
          account: account,
          modelID: targetOverride.modelID,
          systemPrompt: created.systemPrompt,
          options: options
        ) else { return }
      }

      draft = ""
      pendingAttachments = []
      photoPickerItems = []
      chats.send(conversationID: id, text: normalized, attachments: attachments)
      selectConversation(id)
    }
  }

}
