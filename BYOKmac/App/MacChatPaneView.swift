import AppKit
import BYOKchatProviderCore
import MacAppFoundation
import SwiftUI
import UniformTypeIdentifiers
import os

nonisolated enum MacConversationExportSupport {
  static func markdownFilename(for title: String?) -> String {
    let raw = title ?? "BYOKchat-conversation"
    var result = ""
    var previousWasDash = false
    for character in raw {
      if character.isLetter || character.isNumber || character == "_" {
        result.append(character)
        previousWasDash = false
      } else if !previousWasDash {
        result.append("-")
        previousWasDash = true
      }
    }
    let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "BYOKchat-conversation" : trimmed
  }
}

enum MacChatMessageWindowPolicy {
  static let initialVisibleCount = 30
  static let loadMoreBatchSize = 30
  static let searchContextAbove = 15

  /// Returns the tail slice of messages to mount in the transcript `List`,
  /// expanding automatically to include a navigation target with context.
  static func visibleRange(
    totalCount: Int,
    visibleCount: Int,
    targetMessageIndex: Int?
  ) -> Range<Int> {
    guard totalCount > 0 else { return 0..<0 }
    var start = max(0, totalCount - max(1, visibleCount))
    if let targetMessageIndex, targetMessageIndex >= 0, targetMessageIndex < totalCount {
      start = min(start, max(0, targetMessageIndex - searchContextAbove))
    }
    return start..<totalCount
  }
}

enum MacChatSwitchPresentationPolicy {
  /// Returns `true` when the loading skeleton should cover the transcript area.
  ///
  /// Persisted chats that are not yet retained and laid out show the skeleton
  /// immediately on selection and keep it visible until the new transcript has
  /// finished preparing, mounting, and positioning its initial scroll offset.
  /// Switching to New Chat (`nil`) or to an already-retained, laid-out chat
  /// skips the skeleton.
  static func shouldShowLoadingSkeleton(
    requestedConversationID: ConversationID?,
    retainedConversationIDs: Set<ConversationID>,
    revealedConversationIDs: Set<ConversationID>
  ) -> Bool {
    guard let requestedConversationID else { return false }
    return !(retainedConversationIDs.contains(requestedConversationID)
      && revealedConversationIDs.contains(requestedConversationID))
  }
}

struct MacChatPane: View {
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let requestedConversationID: ConversationID?
  let summary: ChatConversation?
  let requestedSummary: ChatConversation?
  let retainedConversations: [MacPreparedConversation]
  let navigationTarget: MacTranscriptNavigationTarget?
  let composerFocusRequestID: Int
  let attachments: [ChatAttachment]
  let sidebarVisible: Bool
  let toggleSidebar: () -> Void
  let chooseTarget: () -> Void
  let manageProviders: () -> Void
  let configureTools: () -> Void
  let openChatSettings: () -> Void
  let openProjects: (ProjectID?) -> Void
  let openAnalytics: () -> Void
  let renameConversation: () -> Void
  let exportMarkdown: () -> Void
  let deleteConversation: () -> Void
  let startNewChat: () -> Void
  let focusComposer: () -> Void
  let appendAttachments: ([ChatAttachment]) -> Void
  let removeAttachment: (String) -> Void
  let send: (String, [ChatAttachment]) -> Void

  @Environment(MacWorkspaceModel.self) private var workspace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var composerHeight: CGFloat = 0
  @State private var showingPromptsPicker = false
  @State private var dismissedOmittedBannerKey: String?
  @State private var revealedConversationIDs: Set<ConversationID> = []

  private var retainedConversationIDs: Set<ConversationID> {
    Set(retainedConversations.compactMap(\.id))
  }

  private var showLoadingSkeleton: Bool {
    MacChatSwitchPresentationPolicy.shouldShowLoadingSkeleton(
      requestedConversationID: requestedConversationID,
      retainedConversationIDs: retainedConversationIDs,
      revealedConversationIDs: revealedConversationIDs
    )
  }

  private var transcriptBottomSpace: CGFloat {
    max(
      MacDesignTokens.Layout.composerReservedScrollSpace,
      composerHeight + MacDesignTokens.Layout.composerBottomMargin + 12
    )
  }

  private var activeConversation: ChatConversation? {
    chats.conversation(conversationID)
  }

  private var headerConversationID: ConversationID? {
    requestedConversationID
  }

  private var headerConversation: ChatConversation? {
    chats.conversation(headerConversationID)
  }

  private var title: String {
    let value = headerConversation?.title ?? requestedSummary?.title ?? ""
    return value.isEmpty ? "New Chat" : value
  }

  private var messageCount: Int? {
    headerConversation?.messages.count ?? requestedSummary?.messageCount
  }

  private var activeProject: ChatProject? {
    if let conversationID {
      return workspace.project(for: conversationID)
    }
    return workspace.project(chats.newChatProjectID)
  }

  private var headerProject: ChatProject? {
    if let headerConversationID {
      return workspace.project(for: headerConversationID)
    }
    return workspace.project(chats.newChatProjectID)
  }

  private var canExportMarkdown: Bool {
    conversationID != nil && (messageCount ?? 0) > 0
  }

  private var configurationIssue: MacChatConfigurationIssue? {
    chats.configurationIssue(for: conversationID)
  }

  private var omittedMessageCount: Int {
    activeConversation?.lastContextOmittedMessageCount ?? 0
  }

  private var omittedBannerKey: String? {
    guard let conversationID, omittedMessageCount > 0 else { return nil }
    return "\(conversationID.rawValue)::\(omittedMessageCount)::\(activeConversation?.messages.count ?? 0)"
  }

  private var showOmittedBanner: Bool {
    guard let omittedBannerKey else { return false }
    return dismissedOmittedBannerKey != omittedBannerKey
  }

  private var enabledToolCount: Int {
    let configuration: MCPChatToolConfiguration
    if let conversationID {
      configuration = mcp.chatConfiguration(for: conversationID)
    } else {
      configuration = mcp.effectiveDraftConfiguration(
        draft: chats.newChatMCPConfiguration,
        projectID: chats.newChatProjectID
      )
    }
    let enabledIDs = Set(configuration.enabledServerIDs)
    return enabledIDs.reduce(0) { total, serverID in
      total + mcp.tools(for: serverID).filter {
        configuration.policy(for: $0.exposedName) != .disabled
      }.count
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      MacChatHeader(
        title: title,
        messageCount: messageCount,
        activeProject: headerProject,
        allProjects: workspace.projects,
        hasPersistedConversation: headerConversationID != nil,
        canExportMarkdown: canExportMarkdown,
        enabledToolCount: enabledToolCount,
        sidebarVisible: sidebarVisible,
        toggleSidebar: toggleSidebar,
        openPrompts: { showingPromptsPicker = true },
        openChatSettings: openChatSettings,
        openTools: configureTools,
        openProject: { openProjects(headerProject?.id) },
        assignProject: { projectID in
          guard let targetConversationID = headerConversationID else { return }
          Task { @MainActor in
            let wasRestricted = projectID.map { workspace.isProjectRestricted($0) } ?? false
            if await workspace.assignConversation(targetConversationID, to: projectID) {
              await mcp.reloadFromStorage()
            } else if let error = workspace.consumeErrorMessage(), !wasRestricted {
              chats.errorMessage = error
            }
          }
        },
        openAnalytics: openAnalytics,
        renameConversation: renameConversation,
        exportMarkdown: exportMarkdown,
        deleteConversation: deleteConversation
      )
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: headerConversationID)
      .zIndex(1)

      if showOmittedBanner {
        MacContextOmittedBanner(
          omittedCount: omittedMessageCount,
          startNewChat: startNewChat,
          dismiss: { dismissedOmittedBannerKey = omittedBannerKey }
        )
        .frame(maxWidth: MacDesignTokens.Layout.transcriptMaximumWidth)
        .padding(.horizontal, MacDesignTokens.Spacing.large)
        .padding(.vertical, 8)
      }

      ZStack(alignment: .bottom) {
        ZStack {
          ForEach(retainedConversations) { retained in
            let isCurrent = retained.id == conversationID
            let isVisible = isCurrent && !showLoadingSkeleton
            MacTranscriptView(
              providers: providers,
              chats: chats,
              mcp: mcp,
              conversationID: retained.id,
              initialConversation: retained.conversation,
              activeProject: isCurrent ? activeProject : nil,
              bottomSpace: transcriptBottomSpace,
              isActive: isCurrent,
              navigationTarget: navigationTarget,
              chooseTarget: chooseTarget,
              manageProviders: manageProviders,
              openChatSettings: openChatSettings,
              configureTools: configureTools,
              openProjects: { openProjects(activeProject?.id) },
              openPrompts: { showingPromptsPicker = true },
              applyPromptPreset: applyPromptPreset,
              onInitialLayoutReady: {
                if let id = retained.id {
                  revealedConversationIDs.insert(id)
                }
              }
            )
            .environment(\.macPreparedAnswers, retained.answers)
            .environment(\.macTranscriptIsActive, isCurrent)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .disabled(!isCurrent)
            .zIndex(isCurrent ? 1 : 0)
          }

          ZStack {
            if showLoadingSkeleton {
              MacTranscriptSkeletonView(bottomSpace: transcriptBottomSpace)
                .transition(
                  reduceMotion
                    ? .identity
                    : .asymmetric(
                      insertion: .identity,
                      removal: .opacity
                    )
                )
            }
          }
          .allowsHitTesting(false)
          .animation(
            reduceMotion ? nil : .easeOut(duration: 0.14),
            value: showLoadingSkeleton
          )
          .zIndex(2)
        }
        .onChange(of: retainedConversations.map(\.id)) { _, ids in
          revealedConversationIDs.formIntersection(Set(ids.compactMap { $0 }))
        }

        VStack(spacing: 10) {
          if let issue = configurationIssue {
            MacConfigurationRepairBanner(
              issue: issue,
              switchModel: chooseTarget,
              openProviders: manageProviders
            )
          }

          MacComposerView(
            providers: providers,
            chats: chats,
            mcp: mcp,
            conversationID: conversationID,
            hasConfigurationIssue: configurationIssue != nil,
            focusRequestID: composerFocusRequestID,
            attachments: attachments,
            chooseTarget: chooseTarget,
            manageProviders: manageProviders,
            configureTools: configureTools,
            appendAttachments: appendAttachments,
            removeAttachment: removeAttachment,
            send: send
          )
        }
        .frame(maxWidth: MacDesignTokens.Layout.composerMaximumWidth)
        .onGeometryChange(for: CGFloat.self) { geometry in
          geometry.size.height
        } action: { height in
          composerHeight = height
        }
        .padding(.horizontal, MacDesignTokens.Spacing.large)
        .padding(.bottom, MacDesignTokens.Layout.composerBottomMargin)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
    }
    .background(MacDesignTokens.Colors.canvas)
    .sheet(isPresented: $showingPromptsPicker) {
      let accessibleActiveProject = activeProject.flatMap {
        workspace.isProjectRestricted($0.id) ? nil : $0
      }
      MacChatPromptsPickerSheet(
        activeProject: accessibleActiveProject,
        allProjects: workspace.accessibleProjects(),
        openProjects: {
          showingPromptsPicker = false
          openProjects(activeProject?.id)
        },
        applyPreset: { preset in
          showingPromptsPicker = false
          applyPromptPreset(preset)
        }
      )
    }
  }

  private func applyPromptPreset(_ preset: ProjectPromptPreset) {
    let value = preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    let current = chats.draft(for: conversationID)
    if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      chats.setDraft(value, conversationID: conversationID)
    } else {
      chats.setDraft(current + "\n\n" + value, conversationID: conversationID)
    }
    focusComposer()
  }
}

private struct MacChatHeader: View {
  let title: String
  let messageCount: Int?
  let activeProject: ChatProject?
  let allProjects: [ChatProject]
  let hasPersistedConversation: Bool
  let canExportMarkdown: Bool
  let enabledToolCount: Int
  let sidebarVisible: Bool
  let toggleSidebar: () -> Void
  let openPrompts: () -> Void
  let openChatSettings: () -> Void
  let openTools: () -> Void
  let openProject: () -> Void
  let assignProject: (ProjectID?) -> Void
  let openAnalytics: () -> Void
  let renameConversation: () -> Void
  let exportMarkdown: () -> Void
  let deleteConversation: () -> Void

  private var otherProjects: [ChatProject] {
    allProjects.filter { $0.id != activeProject?.id }
  }

  var body: some View {
    HStack(spacing: 10) {
      if !sidebarVisible {
        Color.clear
          .frame(width: MacDesignTokens.Layout.titlebarTrafficLightReserve)
          .allowsHitTesting(false)
      }

      Button(action: toggleSidebar) {
        Image(systemName: "sidebar.left")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(MacIconButtonStyle())
      .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
      .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          .lineLimit(1)
          .truncationMode(.tail)

        if let messageCount, messageCount > 0 {
          Text("\(messageCount) \(messageCount == 1 ? "message" : "messages")")
            .font(.system(size: 10.5, weight: .regular))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: 320, alignment: .leading)

      if let activeProject {
        MacChatProjectBadgeButton(project: activeProject, action: openProject)
      }

      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)

      overflowMenu

      MacProHeaderButton()
        .fixedSize()
    }
    .padding(.horizontal, MacDesignTokens.Spacing.compact)
    .frame(height: MacDesignTokens.Layout.titlebarHeight)
    .background {
      ZStack {
        Color(nsColor: .windowBackgroundColor)
        MacDesignTokens.Colors.canvas
        MacDesignTokens.Colors.surface
      }
    }
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(MacDesignTokens.Colors.separator.opacity(0.75))
        .frame(height: 1)
    }
  }

  private var overflowMenu: some View {
    Menu {
      Button("Prompts…", systemImage: "text.bubble", action: openPrompts)
      Button("Chat Settings…", systemImage: "slider.horizontal.3", action: openChatSettings)
      Button(
        enabledToolCount == 0 ? "Tools…" : "Tools (\(enabledToolCount))…",
        systemImage: "wrench.and.screwdriver",
        action: openTools
      )
      if activeProject != nil {
        Button("Project Settings…", systemImage: "folder.badge.gearshape", action: openProject)
      }
      if hasPersistedConversation && (activeProject != nil || !allProjects.isEmpty) {
        Divider()
        if let activeProject {
          Button("Remove from \(activeProject.name)", systemImage: "folder.badge.minus") {
            assignProject(nil)
          }
          if !otherProjects.isEmpty {
            Menu("Move to Project…", systemImage: "folder.badge.plus") {
              ForEach(otherProjects) { project in
                Button(project.name) { assignProject(project.id) }
              }
            }
          }
        } else if !allProjects.isEmpty {
          Menu("Add to Project…", systemImage: "folder.badge.plus") {
            ForEach(allProjects) { project in
              Button(project.name) { assignProject(project.id) }
            }
          }
        }
      }
      Button("Chat Usage & Analytics…", systemImage: "chart.bar.xaxis", action: openAnalytics)
      Divider()
      Button("Rename…", systemImage: "pencil", action: renameConversation)
        .disabled(!hasPersistedConversation)
      Button("Export as Markdown…", systemImage: "square.and.arrow.up", action: exportMarkdown)
        .disabled(!canExportMarkdown)
      Divider()
      Button("Delete…", systemImage: "trash", role: .destructive, action: deleteConversation)
        .disabled(!hasPersistedConversation)
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(
          width: MacDesignTokens.Control.iconButtonSize,
          height: MacDesignTokens.Control.iconButtonSize
        )
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Chat options")
    .accessibilityLabel("Chat options")
  }
}

private struct MacChatProjectBadgeButton: View {
  let project: ChatProject
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    let accent = MacProjectAccentOption(rawValue: project.accentID)?.color ?? .blue
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: project.symbolName)
          .font(.system(size: 9.5, weight: .semibold))
          .foregroundStyle(accent)
          .frame(width: 16, height: 16)
          .background(
            accent.opacity(isHovered ? 0.22 : 0.14),
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
          )
        Text(project.name)
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.leading, 5)
      .padding(.trailing, 9)
      .frame(height: MacDesignTokens.Control.compactButtonHeight)
      .background(
        isHovered ? MacDesignTokens.Colors.surface : MacDesignTokens.Colors.canvas,
        in: Capsule()
      )
      .overlay {
        Capsule()
          .stroke(
            isHovered
              ? accent.opacity(0.45)
              : MacDesignTokens.Colors.separator.opacity(0.85),
            lineWidth: 0.75
          )
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .frame(maxWidth: 180, alignment: .leading)
    .fixedSize(horizontal: true, vertical: true)
    .help("Open \(project.name) in Projects")
    .accessibilityLabel("Project \(project.name)")
  }
}

private struct MacContextOmittedBanner: View {
  let omittedCount: Int
  let startNewChat: () -> Void
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "text.badge.minus")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      Text(
        "\(omittedCount) earlier \(omittedCount == 1 ? "message was" : "messages were") omitted from the latest request to fit the context window."
      )
      .font(.caption)
      .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 8)

      Button("Start New Chat", action: startNewChat)
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))

      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Dismiss")
      .accessibilityLabel("Dismiss context warning")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.orange.opacity(0.38), lineWidth: 0.75)
    }
  }
}

private struct MacConfigurationRepairBanner: View {
  let issue: MacChatConfigurationIssue
  let switchModel: () -> Void
  let openProviders: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "wrench.and.screwdriver.fill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.orange)
        .frame(width: 30, height: 30)
        .background(
          Color.orange.opacity(0.14),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("Chat configuration needs attention")
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        Text(issue.message)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      HStack(spacing: 8) {
        if issue.prefersProviderRepair {
          Button("Switch Model", action: switchModel)
            .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          Button("Fix Connection", action: openProviders)
            .buttonStyle(MacActionButtonStyle(.primary, size: .small))
        } else {
          Button("Open Providers", action: openProviders)
            .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          Button("Switch Model", action: switchModel)
            .buttonStyle(MacActionButtonStyle(.primary, size: .small))
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.orange.opacity(0.42), lineWidth: 0.85)
    }
    .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
  }
}

private struct MacChatPromptsPickerSheet: View {
  let activeProject: ChatProject?
  let allProjects: [ChatProject]
  let openProjects: () -> Void
  let applyPreset: (ProjectPromptPreset) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  private struct PromptGroup: Identifiable {
    let id: ProjectID
    let project: ChatProject
    let presets: [ProjectPromptPreset]
  }

  private var trimmedQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var groups: [PromptGroup] {
    let query = trimmedQuery
    var orderedProjects: [ChatProject] = []
    if let activeProject {
      orderedProjects.append(activeProject)
    }
    for project in allProjects where project.id != activeProject?.id {
      orderedProjects.append(project)
    }
    return orderedProjects.compactMap { project in
      let matching = project.projectPromptPresets.filter { preset in
        guard !query.isEmpty else { return true }
        return preset.name.localizedCaseInsensitiveContains(query)
          || preset.prompt.localizedCaseInsensitiveContains(query)
      }
      guard !matching.isEmpty else { return nil }
      return PromptGroup(id: project.id, project: project, presets: matching)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Prompts")
            .font(.headline)
          Text(
            activeProject != nil
              ? "Insert a reusable prompt into the composer"
              : "Reusable prompts from your projects"
          )
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        Spacer()
        Button("Manage in Projects…", action: openProjects)
          .buttonStyle(MacActionButtonStyle(.secondary))
        Button("Close") { dismiss() }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
      }
      .padding(16)

      Divider()

      if !allProjects.allSatisfy({ $0.projectPromptPresets.isEmpty }) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Search prompts", text: $searchText)
            .textFieldStyle(.plain)
          if !searchText.isEmpty {
            Button {
              searchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(MacDesignTokens.Colors.surface.opacity(0.6))

        Divider()
      }

      if groups.isEmpty {
        ContentUnavailableView {
          Label(
            trimmedQuery.isEmpty ? "No Reusable Prompts" : "No Matching Prompts",
            systemImage: trimmedQuery.isEmpty ? "text.bubble" : "magnifyingglass"
          )
        } description: {
          Text(
            trimmedQuery.isEmpty
              ? "Add reusable prompt presets inside any project to quickly insert them into chats."
              : "Try a different search term."
          )
        } actions: {
          if trimmedQuery.isEmpty {
            Button("Open Projects", action: openProjects)
              .buttonStyle(MacActionButtonStyle(.primary))
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { group in
              VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                  let accent = MacProjectAccentOption(rawValue: group.project.accentID)?.color ?? .blue
                  Image(systemName: group.project.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                  Text(group.project.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  if group.project.id == activeProject?.id {
                    Text("Current Project")
                      .font(.caption2.weight(.medium))
                      .foregroundStyle(MacDesignTokens.Colors.accent)
                      .padding(.horizontal, 6)
                      .padding(.vertical, 2)
                      .background(MacDesignTokens.Colors.accentSoft, in: Capsule())
                  }
                }

                ForEach(group.presets) { preset in
                  MacHoverablePromptCard(
                    title: preset.name,
                    prompt: preset.prompt,
                    titleSize: 13,
                    promptLineLimit: 3,
                    padding: 12
                  ) {
                    applyPreset(preset)
                  }
                }
              }
            }
          }
          .padding(16)
        }
      }
    }
    .frame(width: 540, height: 480)
    .background(MacDesignTokens.Colors.canvas)
  }
}

private struct MacHoverablePromptCard: View {
  let title: String
  let prompt: String
  let titleSize: CGFloat
  let promptLineLimit: Int
  let padding: CGFloat
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    Button(action: action) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: titleSize, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          .lineLimit(1)
        Text(prompt)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .lineLimit(promptLineLimit)
          .multilineTextAlignment(.leading)
      }
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(MacDesignTokens.Colors.surface, in: shape)
      .overlay {
        if isHovered {
          shape.fill(Color.primary.opacity(0.028))
            .allowsHitTesting(false)
        }
      }
      .overlay {
        shape.stroke(
          isHovered
            ? MacDesignTokens.Colors.accent.opacity(0.38)
            : MacDesignTokens.Colors.separator.opacity(0.75),
          lineWidth: 0.7
        )
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
  }
}

/// Header trailing action: opens the paywall for free users, or the Settings
/// Plan tab for Pro users, labeled with their active plan duration.
private struct MacProHeaderButton: View {
  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  @Environment(MacSettingsRouter.self) private var settingsRouter

  private var hasPro: Bool { purchaseManager.hasPro }

  private var planLabel: String? {
    guard let product = purchaseManager.activeProduct else { return nil }
    if product.type == .nonConsumable { return "Pro Lifetime" }
    switch product.subscriptionPeriod?.unit {
    case .month: return "Pro Monthly"
    case .year: return "Pro Yearly"
    default: return "Pro"
    }
  }

  @ViewBuilder
  var body: some View {
    if hasPro {
      planButton
        .buttonStyle(MacSecondaryButtonStyle())
    } else {
      planButton
        .buttonStyle(MacPrimaryButtonStyle())
    }
  }

  private var planButton: some View {
    Button {
      if hasPro {
        settingsRouter.request(.plan)
        openSettings()
      } else {
        openWindow(id: MacWindowID.proPaywall)
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: hasPro ? "checkmark.seal.fill" : "crown.fill")
          .font(.system(size: 11, weight: .semibold))
        Text(hasPro ? (planLabel ?? "Pro") : "Unlock Pro")
          .font(.system(size: 12, weight: .semibold))
      }
      .lineLimit(1)
    }
    .help(hasPro ? "Manage your plan in Settings" : "Unlock BYOK Pro")
    .accessibilityLabel(hasPro ? "Manage plan" : "Unlock BYOK Pro")
    .accessibilityValue(hasPro ? (planLabel ?? "Pro") : "")
  }
}

private struct MacTranscriptView: View {
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let activeProject: ChatProject?
  let bottomSpace: CGFloat
  let isActive: Bool
  let navigationTarget: MacTranscriptNavigationTarget?
  let chooseTarget: () -> Void
  let manageProviders: () -> Void
  let openChatSettings: () -> Void
  let configureTools: () -> Void
  let openProjects: () -> Void
  let openPrompts: () -> Void
  let applyPromptPreset: (ProjectPromptPreset) -> Void
  let onInitialLayoutReady: () -> Void
  @State private var retainedConversation: ChatConversation?
  @State private var retainedBottomSpace: CGFloat
  @State private var lastNavigationToken: UUID?
  @State private var scrollConnection = MacTranscriptScrollConnection()

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(MacWorkspaceModel.self) private var workspace
  @Environment(\.macToastCenter) private var toastCenter
  @State private var isNearBottom = true
  @State private var followsLatest = true
  @State private var isUserDraggingTimeline = false
  @State private var showJumpToLatest = false
  @State private var hasCompletedInitialScroll = false
  @State private var hasRevealedInitialLayout: Bool
  @State private var pendingSourceMessageID: ChatMessageID?
  @State private var pendingScrollTarget: PendingScrollTarget?
  @State private var visibleMessageLimit = MacChatMessageWindowPolicy.initialVisibleCount
  @State private var isLoadingEarlierMessages = false
  @State private var pendingEarlierAnchorID: ChatMessageID?
  @State private var activeRowSheet: ActiveRowSheet?
  @State private var showingRegenerateConfirmation = false

  private enum ActiveRowSheet: Identifiable {
    case details(ChatMessage)
    case edit(ChatMessage)
    case previewAttachment(ChatAttachment, ChatMessage)
    case sources([MacAnswerSource])
    case saveImages(ChatMessage, [MacResponseImageCandidate])

    var id: String {
      switch self {
      case .details(let message): "details-\(message.id.rawValue)"
      case .edit(let message): "edit-\(message.id.rawValue)"
      case .previewAttachment(let attachment, let message): "attachment-\(message.id.rawValue)-\(attachment.id)"
      case .sources(let sources): "sources-\(sources.count)-\(sources.first?.id ?? "")"
      case .saveImages(let message, _): "save-images-\(message.id.rawValue)"
      }
    }
  }

  private struct PendingScrollTarget: Equatable {
    let token = UUID()
    let messageID: ChatMessageID
  }

  private struct GenerationState: Equatable {
    let isActive: Bool
    let isGenerating: Bool
  }

  private enum ScrollTarget {
    static let bottom = "mac-transcript-bottom"
  }

  init(
    providers: MacProviderModel,
    chats: MacChatSessionModel,
    mcp: MacMCPModel,
    conversationID: ConversationID?,
    initialConversation: ChatConversation?,
    activeProject: ChatProject?,
    bottomSpace: CGFloat,
    isActive: Bool,
    navigationTarget: MacTranscriptNavigationTarget?,
    chooseTarget: @escaping () -> Void,
    manageProviders: @escaping () -> Void,
    openChatSettings: @escaping () -> Void,
    configureTools: @escaping () -> Void,
    openProjects: @escaping () -> Void,
    openPrompts: @escaping () -> Void,
    applyPromptPreset: @escaping (ProjectPromptPreset) -> Void,
    onInitialLayoutReady: @escaping () -> Void
  ) {
    _providers = Bindable(wrappedValue: providers)
    _chats = Bindable(wrappedValue: chats)
    _mcp = Bindable(wrappedValue: mcp)
    self.conversationID = conversationID
    self.activeProject = activeProject
    self.bottomSpace = bottomSpace
    self.isActive = isActive
    self.navigationTarget = navigationTarget
    self.chooseTarget = chooseTarget
    self.manageProviders = manageProviders
    self.openChatSettings = openChatSettings
    self.configureTools = configureTools
    self.openProjects = openProjects
    self.openPrompts = openPrompts
    self.applyPromptPreset = applyPromptPreset
    self.onInitialLayoutReady = onInitialLayoutReady
    _retainedConversation = State(initialValue: initialConversation)
    _retainedBottomSpace = State(initialValue: bottomSpace)
    _hasRevealedInitialLayout = State(
      initialValue: conversationID == nil || (initialConversation?.messages.isEmpty ?? true)
    )
  }

  private var effectiveBottomSpace: CGFloat {
    isActive ? bottomSpace : retainedBottomSpace
  }

  private var conversation: ChatConversation? {
    isActive ? chats.conversation(conversationID) : retainedConversation
  }

  private var messages: [ChatMessage] {
    conversation?.messages ?? []
  }

  private var activeTargetMessageID: ChatMessageID? {
    if let pendingSourceMessageID { return pendingSourceMessageID }
    if let pendingScrollTarget { return pendingScrollTarget.messageID }
    if let navigationTarget, navigationTarget.request.conversationID == conversationID {
      return navigationTarget.request.messageID
    }
    return nil
  }

  private var visibleMessageRange: Range<Int> {
    let allMessages = messages
    let targetIndex = activeTargetMessageID.flatMap { targetID in
      allMessages.firstIndex { $0.id == targetID }
    }
    return MacChatMessageWindowPolicy.visibleRange(
      totalCount: allMessages.count,
      visibleCount: visibleMessageLimit,
      targetMessageIndex: targetIndex
    )
  }

  var body: some View {
    let allMessages = messages
    let visibleRange = visibleMessageRange
    let visibleMessages = allMessages[visibleRange]
    let hiddenEarlierCount = visibleRange.lowerBound
    let latestAssistantID = allMessages.last(where: { $0.role == .assistant })?.id
    let accountsByID = Dictionary(
      providers.accounts.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    return ScrollViewReader { proxy in
      ZStack(alignment: .bottom) {
        List {
          transcriptRow(attachScrollAnchor: true) {
            Color.clear
              .frame(height: MacDesignTokens.Spacing.transcriptTop)
          }
          .accessibilityHidden(true)

          if conversationID == nil {
            transcriptRow {
              newConversationEmptyState
            }
          } else if conversation != nil {
            if allMessages.isEmpty {
              transcriptRow {
                existingEmptyConversationState
              }
            } else {
              if hiddenEarlierCount > 0 {
                transcriptRow(bottomSpacing: 20) {
                  loadEarlierMessagesButton(
                    hiddenCount: hiddenEarlierCount,
                    allMessages: allMessages,
                    currentStartIndex: visibleRange.lowerBound,
                    anchorMessageID: visibleMessages.first?.id
                  )
                }
              }

              ForEach(visibleMessages) { message in
                let isLatestAssistant = message.id == latestAssistantID
                transcriptRow(bottomSpacing: 48) {
                  VStack(alignment: .leading, spacing: 8) {
                    MacRichMessageView(
                      providers: providers,
                      chats: chats,
                      mcp: mcp,
                      conversationID: conversationID,
                      message: message,
                      failureContext: failureContextLabel(for: message, accountsByID: accountsByID),
                      isLatestAssistant: isLatestAssistant,
                      onShowDetails: { activeRowSheet = .details($0) },
                      onEditMessage: { activeRowSheet = .edit($0) },
                      onPreviewAttachment: { attachment, owner in
                        activeRowSheet = .previewAttachment(attachment, owner)
                      },
                      onRequestRegenerate: requestRegeneration
                    )

                    if message.role == .assistant,
                      message.status != .pending,
                      message.status != .streaming
                    {
                      MacAssistantMessageActions(
                        chats: chats,
                        conversationID: conversationID,
                        message: message,
                        isLatestAssistant: isLatestAssistant,
                        includeRetry: message.status != .failed,
                        hideEmptyContentActions: message.status == .failed,
                        onShowDetails: { activeRowSheet = .details(message) },
                        onShowSources: { activeRowSheet = .sources($0) },
                        onSaveImages: { activeRowSheet = .saveImages(message, $0) },
                        onRequestRegenerate: requestRegeneration
                      )
                    }
                  }
                }
                .id(message.id.rawValue)
              }
            }

            if let conversationID {
              transcriptRow(bottomSpacing: 48) {
                MacMCPInteractionStack(
                  mcp: mcp,
                  chats: chats,
                  conversationID: conversationID
                )
              }
            }
          } else {
            transcriptRow {
              loadingState
            }
          }

          transcriptRow(attachScrollAnchor: true) {
            Color.clear
              .frame(height: effectiveBottomSpace)
          }
          .accessibilityHidden(true)
          .id(ScrollTarget.bottom)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
        .scrollClipDisabled(false)
        .clipped()
        .opacity(hasRevealedInitialLayout ? 1 : 0)
        .background {
          MacTranscriptScrollObserver(isEnabled: isActive, connection: scrollConnection) { previous, current in
            guard isActive else { return }
            if previous == nil {
              let log = OSLog(subsystem: "pro.byok.BYOKchat", category: "ChatSwitch")
              os_signpost(.event, log: log, name: "Transcript Geometry Ready")
            }
            isNearBottom = current.isNearBottom
            isUserDraggingTimeline = current.isUserScrolling
            showJumpToLatest = MacTranscriptScrollPolicy.shouldShowJumpToLatest(
              isNearBottom: current.isNearBottom,
              hasCompletedInitialScroll: hasCompletedInitialScroll
            )

            if current.isNearBottom {
              followsLatest = true
            } else if current.userDidScroll {
              followsLatest = false
            }

            if let previous,
              previous.contentHeight != current.contentHeight,
              !current.userDidScroll,
              MacTranscriptScrollPolicy.shouldFollowContentGrowth(
                hasCompletedInitialScroll: hasCompletedInitialScroll,
                followsLatest: followsLatest,
                isUserDraggingTimeline: current.isUserScrolling,
                isGenerating: chats.isGenerating(conversationID)
              )
            {
              scrollToBottom(proxy, animated: false)
            }
          }
          .allowsHitTesting(false)
        }
        .onChange(of: effectiveBottomSpace, initial: true) { _, value in
          guard isActive else { return }
          retainedBottomSpace = value
        }
        .onChange(of: conversation, initial: true) { _, value in
          guard isActive else { return }
          retainedConversation = value
        }
        .onChange(of: messages.count) { _, _ in
          guard isActive else { return }
          if scrollToPendingSourceMessageIfAvailable(proxy) { return }
          guard followsLatest, !isUserDraggingTimeline else {
            showJumpToLatest = !isNearBottom
            return
          }
          scrollToBottom(proxy, animated: true)
        }
        .onChange(of: isActive ? mcp.pendingApprovals.count : 0) { _, _ in
          guard isActive, followsLatest, !isUserDraggingTimeline else { return }
          scrollToBottom(proxy, animated: true)
        }
        .onChange(of: isActive ? mcp.pendingElicitations.count : 0) { _, _ in
          guard isActive, followsLatest, !isUserDraggingTimeline else { return }
          scrollToBottom(proxy, animated: true)
        }
        .onChange(of: GenerationState(
          isActive: isActive,
          isGenerating: isActive && chats.isGenerating(conversationID)
        )) { previous, current in
          // Reactivating a streaming chat must preserve its previous reading
          // position, rather than treating activation as a new generation.
          guard previous.isActive, current.isActive else { return }
          if current.isGenerating {
            followsLatest = true
            isUserDraggingTimeline = false
            showJumpToLatest = false
          } else if followsLatest {
            // The live row can change height when its completed representation
            // replaces it. Re-anchor explicitly rather than restoring a
            // persistent scroll position into List's recycled rows.
            scrollToBottom(proxy, animated: false)
          } else if !isNearBottom {
            showJumpToLatest = true
          }
        }
        .onChange(of: navigationTarget, initial: true) { _, target in
          guard let target, target.request.conversationID == conversationID,
            target.token != lastNavigationToken
          else { return }
          lastNavigationToken = target.token
          pendingSourceMessageID = target.request.messageID
          if isActive, hasCompletedInitialScroll {
            _ = scrollToPendingSourceMessageIfAvailable(proxy)
          }
        }
        .task(id: pendingEarlierAnchorID) {
          guard let anchorID = pendingEarlierAnchorID else { return }
          await Task.yield()
          guard !Task.isCancelled else { return }
          proxy.scrollTo(anchorID.rawValue, anchor: .top)
          pendingEarlierAnchorID = nil
        }
        .task(id: pendingScrollTarget) {
          guard let target = pendingScrollTarget else { return }
          await Task.yield()
          guard !Task.isCancelled, isActive else { return }
          let shouldAnimate = hasRevealedInitialLayout && !reduceMotion
          let scroll = {
            proxy.scrollTo(target.messageID.rawValue, anchor: .center)
          }
          if shouldAnimate {
            withAnimation(.easeOut(duration: 0.18), scroll)
          } else {
            scroll()
          }
          if !hasRevealedInitialLayout {
            await Task.yield()
            guard !Task.isCancelled, isActive else { return }
            hasCompletedInitialScroll = true
            hasRevealedInitialLayout = true
            onInitialLayoutReady()
            showJumpToLatest = !isNearBottom
          }
          pendingScrollTarget = nil
        }
        .task(id: isActive) {
          guard isActive else { return }
          isUserDraggingTimeline = false
          await Task.yield()
          guard !Task.isCancelled else { return }
          if !scrollToPendingSourceMessageIfAvailable(proxy), followsLatest {
            scrollToBottom(proxy, animated: false)
          }
          // If navigating to an older message required expanding the visible
          // window, let `pendingScrollTarget` finish scrolling before revealing.
          guard pendingScrollTarget == nil else { return }
          await Task.yield()
          guard !Task.isCancelled else { return }
          hasCompletedInitialScroll = true
          if !hasRevealedInitialLayout {
            hasRevealedInitialLayout = true
          }
          onInitialLayoutReady()
          showJumpToLatest = !isNearBottom
        }

        if isActive, conversationID != nil, !messages.isEmpty, showJumpToLatest {
          Button {
            followsLatest = true
            isUserDraggingTimeline = false
            showJumpToLatest = false
            pendingSourceMessageID = nil
            pendingScrollTarget = nil
            scrollToBottom(proxy, animated: true)
          } label: {
            Image(systemName: "arrow.down")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.secondary)
              .frame(width: 32, height: 32)
              .background(.ultraThinMaterial, in: Circle())
              .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
              .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .padding(.bottom, bottomSpace)
          .help("Scroll to bottom of chat")
          .accessibilityLabel("Scroll to bottom of chat")
        }
      }
      .sheet(item: $activeRowSheet) { sheet in
        rowModalContent(for: sheet)
      }
      .confirmationDialog(
        "Regenerate this response?",
        isPresented: $showingRegenerateConfirmation,
        titleVisibility: .visible
      ) {
        Button("Regenerate") {
          regenerate(confirmingUncertainCompletion: true)
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("The provider may have completed the previous request even though BYOKchat could not confirm it. Regenerating can create another billable response.")
      }
    }
  }

  @ViewBuilder
  private func rowModalContent(for sheet: ActiveRowSheet) -> some View {
    switch sheet {
    case .details(let message):
      MacMessageDetailsView(
        message: message,
        providers: providers,
        conversation: chats.conversation(conversationID),
        toolDisplayName: mcp.toolDisplayName
      )

    case .edit(let message):
      if let conversationID {
        MacEditAndResendView(
          chats: chats,
          conversationID: conversationID,
          original: message.content,
          chooseTarget: chooseTarget,
          manageProviders: manageProviders,
          save: { value in
            await chats.editAndResend(
              conversationID: conversationID,
              messageID: message.id,
              text: value
            )
          }
        )
      }

    case .previewAttachment(let attachment, let owner):
      let isStreamingOwner = owner.status == .pending || owner.status == .streaming
      MacAttachmentPreviewSheet(
        attachment: attachment,
        loadData: { id in
          await chats.attachmentData(id)
        },
        saveToLibrary: (conversationID != nil && !isStreamingOwner)
          ? {
            guard let conversationID else { return nil }
            let ok = await workspace.saveStoredAttachmentToLibrary(
              attachment,
              conversationID: conversationID,
              messageID: owner.id
            )
            if ok { return nil }
            return workspace.consumeErrorMessage() ?? "Could not save attachment to Library."
          }
          : nil
      )

    case .sources(let sources):
      MacAnswerSourcesSheet(sources: sources)

    case .saveImages(let message, let candidates):
      if let conversationID {
        MacResponseImageSaveSheet(
          candidates: candidates,
          conversationID: conversationID,
          messageID: message.id,
          workspace: workspace
        ) { savedCount in
          guard savedCount > 0 else { return }
          toastCenter?.success(
            savedCount == 1
              ? "Saved 1 image to Library"
              : "Saved \(savedCount) images to Library"
          )
        }
      }
    }
  }

  private func requestRegeneration() {
    guard let conversationID else { return }
    if chats.latestAssistantRequiresRegenerationConfirmation(conversationID) {
      showingRegenerateConfirmation = true
    } else {
      regenerate(confirmingUncertainCompletion: false)
    }
  }

  private func regenerate(confirmingUncertainCompletion: Bool) {
    guard let conversationID else { return }
    Task {
      _ = await chats.regenerate(
        conversationID: conversationID,
        confirmingUncertainCompletion: confirmingUncertainCompletion
      )
    }
  }

  private func transcriptRow<Content: View>(
    bottomSpacing: CGFloat = 0,
    attachScrollAnchor: Bool = false,
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .frame(maxWidth: MacDesignTokens.Layout.transcriptMaximumWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, MacDesignTokens.Spacing.large)
      .padding(.bottom, bottomSpacing)
      .background {
        if attachScrollAnchor {
          MacTranscriptScrollAnchor(connection: scrollConnection)
            .allowsHitTesting(false)
        }
      }
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }

  private var loadingState: some View {
    MacTranscriptSkeletonContent()
      .padding(.top, 12)
  }

  @ViewBuilder
  private var existingEmptyConversationState: some View {
    if let conversation, let issue = chats.configurationIssue(for: conversation) {
      VStack(spacing: 14) {
        Image(systemName: "wrench.and.screwdriver")
          .font(.system(size: 28, weight: .medium))
          .foregroundStyle(.orange)
          .accessibilityHidden(true)

        Text("Finish setting up this chat")
          .font(.title2.weight(.semibold))
          .accessibilityAddTraits(.isHeader)

        Text(issue.message)
          .font(.callout)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 460)

        HStack(spacing: 10) {
          Button("Switch Model", action: chooseTarget)
            .buttonStyle(MacActionButtonStyle(.primary))
          Button("Open Providers", action: manageProviders)
            .buttonStyle(MacActionButtonStyle(.secondary))
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 72)
    } else {
      readyHeroView(subline: activeTargetSubline)
    }
  }

  @ViewBuilder
  private var newConversationEmptyState: some View {
    let readiness = chats.newChatSetupReadiness(project: activeProject)
    switch readiness {
    case .ready:
      readyHeroView(subline: activeTargetSubline)
    default:
      guidedSetupHero(for: readiness)
    }
  }

  private var activeTargetSubline: String? {
    guard let target = chats.target(for: conversationID) else { return nil }
    let accountName = providers.account(target.accountID)?.label
      ?? conversation?.providerID.rawValue
      ?? "Provider"
    let modelName = providers.modelRecord(for: target.accountID, modelID: target.modelID)?.model.displayName
      ?? target.modelID.rawValue
    return "Using \(accountName) · \(modelName)"
  }

  private func readyHeroView(subline: String?) -> some View {
    VStack(spacing: 16) {
      if let activeProject {
        let accent = MacProjectAccentOption(rawValue: activeProject.accentID)?.color ?? .blue
        Image(systemName: activeProject.symbolName)
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(accent)
          .frame(width: 52, height: 52)
          .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          .accessibilityHidden(true)

        Text(activeProject.name)
          .font(.title2.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
      } else {
        Image(systemName: "bubble.left.and.bubble.right")
          .font(.system(size: 28, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.accent)
          .accessibilityHidden(true)

        Text("How can I help?")
          .font(.title2.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
      }

      if let subline {
        Text(subline)
          .font(.callout)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .multilineTextAlignment(.center)
      }

      if let activeProject {
        let trimmedInstructions = activeProject.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstructions.isEmpty {
          Text(trimmedInstructions)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 500)
        }

        let accessiblePrompts = workspace.promptPresets(projectID: activeProject.id)
        if !accessiblePrompts.isEmpty {
          VStack(spacing: 8) {
            Text("Project Prompts")
              .font(.caption.weight(.semibold))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)

            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 8)],
              spacing: 8
            ) {
              ForEach(accessiblePrompts.prefix(4)) { preset in
                MacHoverablePromptCard(
                  title: preset.name,
                  prompt: preset.prompt,
                  titleSize: 12.5,
                  promptLineLimit: 2,
                  padding: 10
                ) {
                  applyPromptPreset(preset)
                }
              }
            }
            .frame(maxWidth: 560)

            if accessiblePrompts.count > 4 {
              Button("All Prompts (\(accessiblePrompts.count))…", action: openPrompts)
                .buttonStyle(.link)
                .font(.caption)
            }
          }
          .padding(.top, 4)
        }
      }

      HStack(spacing: 8) {
        Button("Switch Model", systemImage: "cpu", action: chooseTarget)
        Button("Chat Settings", systemImage: "slider.horizontal.3", action: openChatSettings)
        if !mcp.servers.isEmpty {
          Button("Tools", systemImage: "wrench.and.screwdriver", action: configureTools)
        }
      }
      .buttonStyle(MacSecondaryButtonStyle())
      .font(.system(size: 11.5, weight: .medium))
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 64)
  }

  private func guidedSetupHero(for readiness: MacChatSetupReadiness) -> some View {
    let icon: String
    let title: String
    let description: String
    let primaryLabel: String
    let primaryIcon: String
    let primaryAction: () -> Void

    switch readiness {
    case .noConnection:
      icon = "link"
      title = activeProject == nil ? "Connect your AI" : "Set up a connection"
      description = activeProject.map {
        "Add a provider connection before starting a chat in \($0.name)."
      } ?? "Connect a cloud AI provider with your own API key, or point to a local server like Ollama or LM Studio."
      primaryLabel = "Add Provider Connection"
      primaryIcon = "plus.circle.fill"
      primaryAction = manageProviders

    case .missingCredential(let accountLabel):
      icon = "key.slash"
      title = "Finish setting up \(accountLabel)"
      description = "\(accountLabel) needs an API key before it can be used."
      primaryLabel = "Open Providers"
      primaryIcon = "key.fill"
      primaryAction = manageProviders

    case .noModel(let accountLabel):
      icon = "rectangle.stack.badge.plus"
      title = "Choose a model"
      description = "Refresh or add a model for \(accountLabel) before starting a chat."
      primaryLabel = "Open Providers"
      primaryIcon = "rectangle.stack.fill"
      primaryAction = manageProviders

    case .projectAccountUnavailable(let projectName):
      icon = "folder.badge.questionmark"
      title = "Project connection unavailable"
      description = "The provider account selected for \(projectName) is unavailable or disabled. Choose another account in project defaults."
      primaryLabel = "Open Projects"
      primaryIcon = "folder.badge.gearshape"
      primaryAction = openProjects

    case .projectModelUnavailable(let projectName):
      icon = "folder.badge.questionmark"
      title = "Project model unavailable"
      description = "The default model selected for \(projectName) is no longer available. Choose another model in project defaults."
      primaryLabel = "Open Projects"
      primaryIcon = "folder.badge.gearshape"
      primaryAction = openProjects

    case .allAccountsRestricted:
      icon = "lock.shield"
      title = "Connection requires BYOK Pro"
      description = "Your restored connections exceed the Free tier limit. Manage your connections or upgrade to BYOK Pro."
      primaryLabel = "Open Providers"
      primaryIcon = "sparkles"
      primaryAction = manageProviders

    case .ready:
      icon = "sparkles"
      title = "How can I help?"
      description = ""
      primaryLabel = "Open Providers"
      primaryIcon = "sparkles"
      primaryAction = manageProviders
    }

    return VStack(spacing: 18) {
      Image(systemName: icon)
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .frame(width: 56, height: 56)
        .background(
          MacDesignTokens.Colors.accentSoft,
          in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .accessibilityHidden(true)

      VStack(spacing: 6) {
        Text(title)
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)

        Text(description)
          .font(.callout)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 480)
      }

      Button(action: primaryAction) {
        Label(primaryLabel, systemImage: primaryIcon)
          .padding(.horizontal, 6)
      }
      .buttonStyle(MacActionButtonStyle(.primary))

      HStack(alignment: .top, spacing: 12) {
        setupInfoCard(
          icon: "cloud",
          title: "Cloud Providers",
          detail: "OpenAI, Anthropic, Gemini, OpenRouter, DeepSeek, and more with Keychain-secured keys.",
          actionTitle: "Open Providers",
          action: manageProviders
        )
        setupInfoCard(
          icon: "desktopcomputer",
          title: "Local Servers",
          detail: "Run models locally with Ollama or LM Studio on your Mac or LAN — no API key required.",
          actionTitle: "Connect Local Server",
          action: manageProviders
        )
      }
      .frame(maxWidth: 580)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 48)
  }

  private func setupInfoCard(
    icon: String,
    title: String,
    detail: String,
    actionTitle: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 7) {
          Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.accent)
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        }

        Text(detail)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)

        Spacer(minLength: 0)

        Text(actionTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(MacDesignTokens.Colors.accent)
      }
      .padding(14)
      .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
      .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.7)
      }
    }
    .buttonStyle(.plain)
  }

  private func loadEarlierMessagesButton(
    hiddenCount: Int,
    allMessages: [ChatMessage],
    currentStartIndex: Int,
    anchorMessageID: ChatMessageID?
  ) -> some View {
    let batchCount = min(hiddenCount, MacChatMessageWindowPolicy.loadMoreBatchSize)
    return HStack {
      Spacer()
      Button {
        guard !isLoadingEarlierMessages else { return }
        isLoadingEarlierMessages = true
        let targetConversationID = conversationID
        let batchStart = max(0, currentStartIndex - batchCount)
        let textsToPrewarm = allMessages[batchStart..<currentStartIndex]
          .filter { $0.role == .assistant && !$0.content.isEmpty }
          .map(\.content)
        let expandedCount = (allMessages.count - currentStartIndex) + batchCount
        Task { @MainActor in
          _ = try? await MacAnswerContentParseCache.shared.prepareBatch(textsToPrewarm)
          guard !Task.isCancelled, conversationID == targetConversationID else { return }
          pendingEarlierAnchorID = anchorMessageID
          visibleMessageLimit = max(visibleMessageLimit, expandedCount)
          isLoadingEarlierMessages = false
        }
      } label: {
        HStack(spacing: 7) {
          if isLoadingEarlierMessages {
            ProgressView()
              .controlSize(.mini)
          } else {
            Image(systemName: "arrow.up.circle")
              .font(.system(size: 12.5, weight: .semibold))
          }
          Text(
            hiddenCount > batchCount
              ? "Load \(batchCount) earlier messages (\(hiddenCount) hidden)"
              : "Load \(hiddenCount) earlier message\(hiddenCount == 1 ? "" : "s")"
          )
          .font(.system(size: 12.5, weight: .medium))
        }
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(MacDesignTokens.Colors.surface, in: Capsule())
        .overlay(Capsule().stroke(MacDesignTokens.Colors.separator, lineWidth: 0.75))
      }
      .buttonStyle(.plain)
      .disabled(isLoadingEarlierMessages)
      Spacer()
    }
  }

  private func failureContextLabel(
    for message: ChatMessage,
    accountsByID: [ProviderAccountID: ProviderAccount]
  ) -> String? {
    guard message.status == .failed, message.failureOrigin == .remote else { return nil }

    var parts: [String] = []
    if let accountID = message.accountID, let account = accountsByID[accountID] {
      if providers.accounts.filter({ $0.providerID == account.providerID }).count > 1 {
        parts.append(account.label)
      }
      parts.append(
        providers.provider(for: account.providerID)?.displayName ?? account.providerID.rawValue
      )
      if let modelID = message.modelID {
        let modelName = providers.modelRecord(for: account.id, modelID: modelID)?.model.displayName
        parts.append(modelName ?? modelID.rawValue)
      }
    } else {
      if let providerID = message.providerID {
        parts.append(providers.provider(for: providerID)?.displayName ?? providerID.rawValue)
      }
      if let modelID = message.modelID {
        parts.append(modelID.rawValue)
      }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  @discardableResult
  private func scrollToPendingSourceMessageIfAvailable(_ proxy: ScrollViewProxy) -> Bool {
    guard isActive, let messageID = pendingSourceMessageID,
      let targetIndex = messages.firstIndex(where: { $0.id == messageID })
    else { return false }

    let currentRange = MacChatMessageWindowPolicy.visibleRange(
      totalCount: messages.count,
      visibleCount: visibleMessageLimit,
      targetMessageIndex: nil
    )
    let requiredRange = MacChatMessageWindowPolicy.visibleRange(
      totalCount: messages.count,
      visibleCount: visibleMessageLimit,
      targetMessageIndex: targetIndex
    )
    let requiredCount = messages.count - requiredRange.lowerBound
    let needsExpansion = !currentRange.contains(targetIndex)
    if requiredCount > visibleMessageLimit {
      visibleMessageLimit = requiredCount
    }

    pendingSourceMessageID = nil
    followsLatest = false
    isUserDraggingTimeline = false
    showJumpToLatest = true

    if needsExpansion {
      pendingScrollTarget = PendingScrollTarget(messageID: messageID)
      return true
    }

    let scroll = {
      proxy.scrollTo(messageID.rawValue, anchor: .center)
    }
    if hasRevealedInitialLayout && !reduceMotion {
      withAnimation(.easeOut(duration: 0.18), scroll)
    } else {
      scroll()
    }
    return true
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
    guard isActive else { return }
    let scroll = {
      proxy.scrollTo(ScrollTarget.bottom, anchor: .bottom)
    }
    if animated && !reduceMotion {
      withAnimation(.easeOut(duration: 0.18), scroll)
    } else {
      scroll()
    }
  }
}

private struct MacTranscriptSkeletonView: View {
  let bottomSpace: CGFloat

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: MacDesignTokens.Spacing.transcriptTop)

      MacTranscriptSkeletonContent()
        .frame(maxWidth: MacDesignTokens.Layout.transcriptMaximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, MacDesignTokens.Spacing.large)
        .padding(.bottom, bottomSpace + 28)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(MacDesignTokens.Colors.canvas)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading conversation")
  }
}

private struct MacTranscriptSkeletonContent: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isPulsing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 36) {
      userBubbleSkeleton(widths: [240])

      assistantSkeleton(
        lineWidths: [540, 490, 340],
        includesCard: false
      )

      userBubbleSkeleton(widths: [310, 180])

      assistantSkeleton(
        lineWidths: [580, 520, 410],
        includesCard: true
      )
    }
    .opacity(reduceMotion ? 0.72 : (isPulsing ? 0.88 : 0.48))
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
        isPulsing = true
      }
    }
  }

  private func userBubbleSkeleton(widths: [CGFloat]) -> some View {
    HStack {
      Spacer(minLength: 80)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
          skeletonBar(maxWidth: width, height: 11, opacity: 0.085)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(
        Color.primary.opacity(0.045),
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.message, style: .continuous)
      )
    }
  }

  private func assistantSkeleton(lineWidths: [CGFloat], includesCard: Bool) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      ForEach(Array(lineWidths.enumerated()), id: \.offset) { _, width in
        skeletonBar(maxWidth: width, height: 11, opacity: 0.07)
      }

      if includesCard {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.primary.opacity(0.04))
          .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(Color.primary.opacity(0.06), lineWidth: 0.75)
          }
          .frame(maxWidth: 520, minHeight: 74, maxHeight: 74)
          .padding(.top, 4)
      }

      HStack(spacing: 8) {
        Circle()
          .fill(Color.primary.opacity(0.06))
          .frame(width: 14, height: 14)
        Circle()
          .fill(Color.primary.opacity(0.06))
          .frame(width: 14, height: 14)
      }
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func skeletonBar(maxWidth: CGFloat, height: CGFloat, opacity: CGFloat) -> some View {
    Capsule(style: .continuous)
      .fill(Color.primary.opacity(opacity))
      .frame(maxWidth: maxWidth, minHeight: height, maxHeight: height)
  }
}

private struct MacComposerView: View {
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let hasConfigurationIssue: Bool
  let focusRequestID: Int
  let attachments: [ChatAttachment]
  let chooseTarget: () -> Void
  let manageProviders: () -> Void
  let configureTools: () -> Void
  let appendAttachments: ([ChatAttachment]) -> Void
  let removeAttachment: (String) -> Void
  let send: (String, [ChatAttachment]) -> Void

  @Environment(MacWorkspaceModel.self) private var workspace
  @FocusState private var editorFocused: Bool
  @State private var fileDropTargeted = false
  @State private var showingFileImporter = false
  @State private var showingLibraryPicker = false
  @State private var importingAttachmentCount = 0

  private var isImportingAttachments: Bool {
    importingAttachmentCount > 0
  }

  private var target: MacChatTarget? {
    chats.target(for: conversationID)
  }

  private var selectedAccount: ProviderAccount? {
    providers.account(target?.accountID)
  }

  private var selectedModel: ProviderModel? {
    guard let target else { return nil }
    return providers.modelRecord(for: target.accountID, modelID: target.modelID)?.model
  }

  private var isStreaming: Bool {
    chats.isGenerating(conversationID)
  }

  private var draftBinding: Binding<String> {
    Binding(
      get: { chats.draft(for: conversationID) },
      set: { chats.setDraft($0, conversationID: conversationID) }
    )
  }

  private var canSend: Bool {
    (!draftBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !attachments.isEmpty)
      && target != nil
      && !hasConfigurationIssue
      && !isStreaming
      && !isImportingAttachments
  }

  private var projectFiles: [ProjectFile] {
    if let conversationID {
      return workspace.projectFiles(conversationID: conversationID)
    }
    return workspace.projectFiles(projectID: chats.newChatProjectID)
  }

  private var promptPresets: [ProjectPromptPreset] {
    if let conversationID {
      return workspace.promptPresets(conversationID: conversationID)
    }
    return workspace.promptPresets(projectID: chats.newChatProjectID)
  }

  private var enabledToolCount: Int {
    let configuration: MCPChatToolConfiguration
    if let conversationID {
      configuration = mcp.chatConfiguration(for: conversationID)
    } else {
      configuration = mcp.effectiveDraftConfiguration(
        draft: chats.newChatMCPConfiguration,
        projectID: chats.newChatProjectID
      )
    }
    let enabledIDs = Set(configuration.enabledServerIDs)
    return enabledIDs.reduce(0) { total, serverID in
      total + mcp.tools(for: serverID).filter {
        configuration.policy(for: $0.exposedName) != .disabled
      }.count
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !attachments.isEmpty {
        MacAttachmentStrip(
          attachments: attachments,
          presentation: .composer,
          remove: removeAttachment,
          addAttachment: { showingFileImporter = true },
          isImportingAttachments: isImportingAttachments
        )
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 3)
      }

      messageField
        .padding(.horizontal, 14)
        .padding(.top, attachments.isEmpty ? 8 : 2)
        .padding(.bottom, 3)

      bottomControls
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
    .background(
      fileDropTargeted ? MacDesignTokens.Colors.accentSoft : MacDesignTokens.Colors.surface,
      in: composerShape
    )
    .clipShape(composerShape)
    .overlay {
      composerShape
        .stroke(
          fileDropTargeted ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.separator.opacity(0.8),
          lineWidth: 0.75
        )
    }
    .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
    .fileImporter(
      isPresented: $showingFileImporter,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        importURLs(urls)
      case .failure(let error):
        MacAppAnalytics.reportError("attachment_picker_failed", component: "attachments")
        chats.errorMessage = error.localizedDescription
      }
    }
    .sheet(isPresented: $showingLibraryPicker) {
      MacLibraryAttachmentPickerView(
        workspace: workspace,
        excludedIDs: Set(attachments.map(\.id)),
        existingAttachmentByteCount: attachments.reduce(0) { $0 + $1.byteCount },
        attach: appendAttachments
      )
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard !urls.isEmpty, !isStreaming else { return false }
      importURLs(urls)
      return true
    } isTargeted: { targeted in
      fileDropTargeted = targeted
    }
    .dropDestination(for: MacDroppedImage.self) { images, _ in
      guard !images.isEmpty, !isStreaming else { return false }
      importImages(images)
      return true
    } isTargeted: { targeted in
      fileDropTargeted = targeted
    }
    .onChange(of: focusRequestID) { _, _ in
      editorFocused = true
    }
    .onChange(of: conversationID) { _, _ in
      fileDropTargeted = false
    }
  }

  private var composerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 18, style: .continuous)
  }

  private var messageField: some View {
    TextField(
      target == nil ? "Set up a provider to chat…" : "Message…",
      text: draftBinding,
      axis: .vertical
    )
    .textFieldStyle(.plain)
    .font(.system(size: 15))
    .lineLimit(1...5)
    .focused($editorFocused)
    .padding(.horizontal, 3)
    .padding(.vertical, 6)
    .disabled(target == nil || isStreaming)
    .accessibilityLabel("Message")
    .accessibilityHint(
      target == nil
        ? "Set up a provider before composing a message"
        : "Return sends. Shift Return inserts a new line"
    )
    .onKeyPress(keys: [.return], phases: .down) { press in
      if press.modifiers.contains(.shift) { return .ignored }
      guard canSend else { return .ignored }
      submit()
      return .handled
    }
  }

  private var bottomControls: some View {
    HStack(spacing: 8) {
      attachmentMenu
      targetButton

      Spacer(minLength: 10)
      sendButton
    }
    .frame(minHeight: 34)
  }

  private var attachmentMenu: some View {
    Menu {
      Button("Choose Files…", systemImage: "doc.badge.plus") {
        showingFileImporter = true
      }
      Button("Paste Image or File", systemImage: "doc.on.clipboard") {
        importPasteboard()
      }

      Divider()
      Button("From Library…", systemImage: "books.vertical") {
        showingLibraryPicker = true
      }

      if !projectFiles.isEmpty {
        Divider()
        let attachedIDs = Set(attachments.map(\.id))
        Menu("Project Files", systemImage: "folder.badge.plus") {
          ForEach(projectFiles) { file in
            let isAttached = attachedIDs.contains(file.id)
            Button {
              attachProjectFile(file)
            } label: {
              if isAttached {
                Label(file.filename, systemImage: "checkmark")
              } else {
                Text(file.filename)
              }
            }
            .disabled(isAttached)
          }
        }
      }

      if !promptPresets.isEmpty {
        Divider()
        Menu("Prompts", systemImage: "text.bubble") {
          ForEach(promptPresets) { preset in
            Button(preset.name) { applyPromptPreset(preset) }
          }
        }
      }

      Divider()
      Button(
        enabledToolCount == 0 ? "Tools…" : "Tools · \(enabledToolCount)…",
        systemImage: "wrench.and.screwdriver",
        action: configureTools
      )
    } label: {
      Group {
        if isImportingAttachments {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "plus")
            .font(.system(size: 16, weight: .regular))
        }
      }
      .frame(width: 34, height: 34)
      .contentShape(Circle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    // Menu is width-greedy on macOS; without this it absorbs the flexible
    // space in bottomControls and pushes the model pill toward the send button.
    .fixedSize()
    .disabled(isStreaming || target == nil || isImportingAttachments)
    .accessibilityLabel(isImportingAttachments ? "Importing attachments" : "Add or configure")
    .help(
      isImportingAttachments
        ? "Importing attachments…"
        : "Add attachments, project prompts, or configure chat tools"
    )
  }

  private var targetButton: some View {
    Button {
      editorFocused = false
      if target == nil {
        manageProviders()
      } else {
        chooseTarget()
      }
    } label: {
      Text(target == nil ? "Set Up Provider" : targetLabel)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Color.primary.opacity(0.025), in: Capsule())
        .overlay {
          Capsule()
            .stroke(MacDesignTokens.Colors.separator.opacity(0.95), lineWidth: 0.75)
        }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(isStreaming)
    .help(target == nil ? "Set up a provider" : "Change model")
    .accessibilityLabel("Change provider, model, and reasoning")
    .accessibilityValue(targetDetails)
  }

  private var sendButton: some View {
    Button {
      if isStreaming {
        Task { await chats.stop(conversationID) }
      } else {
        submit()
        editorFocused = false
      }
    } label: {
      Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 34, height: 34)
        .background(
          MacDesignTokens.Colors.accent.opacity(isStreaming || canSend ? 0.95 : 0.34),
          in: Circle()
        )
    }
    .buttonStyle(.plain)
    .disabled(!isStreaming && !canSend)
    .accessibilityLabel(isStreaming ? "Stop response" : "Send message")
    .accessibilityHint(
      isStreaming ? "Stops the current model response" : "Sends the current message and attachments"
    )
  }

  private var modelLabel: String {
    guard let target else { return "No model" }
    return selectedModel?.displayName ?? target.modelID.rawValue
  }

  private var accountLabel: String {
    selectedAccount?.label ?? "Provider"
  }

  private var targetDetails: String {
    guard target != nil else { return "No provider configured" }
    return "\(accountLabel) · \(modelLabel)"
  }

  private var targetLabel: String {
    guard let target else { return "No model" }
    let providerID = selectedAccount?.providerID ?? selectedAccount?.kind.defaultProviderID
      ?? ProviderID(rawValue: target.modelID.rawValue)
    return MacTargetLabelFormatter.make(
      providerID: providerID,
      providerName: accountLabel,
      modelName: selectedModel?.displayName ?? target.modelID.rawValue,
      modelID: target.modelID.rawValue,
      supportedParameters: selectedModel?.supportedParameters ?? [],
      reasoning: target.reasoning,
      capabilities: ModelCapabilityResolver.resolve(kind: selectedAccount?.kind ?? .openAICompatible,
        modelID: target.modelID, model: selectedModel)
    )
  }

  private func submit() {
    let text = draftBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (!text.isEmpty || !attachments.isEmpty),
      target != nil,
      !hasConfigurationIssue,
      !isStreaming,
      !isImportingAttachments
    else { return }
    send(text, attachments)
  }

  private func applyPromptPreset(_ preset: ProjectPromptPreset) {
    let value = preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    let current = draftBinding.wrappedValue
    if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      draftBinding.wrappedValue = value
    } else {
      draftBinding.wrappedValue = current + "\n\n" + value
    }
    editorFocused = true
  }

  private func importURLs(_ urls: [URL]) {
    guard !isStreaming else { return }
    importingAttachmentCount += 1
    Task { @MainActor in
      defer { importingAttachmentCount = max(0, importingAttachmentCount - 1) }
      do {
        appendAttachments(try await MacAttachmentImporter.importURLs(urls))
      } catch {
        MacAppAnalytics.reportError("attachment_import_failed", component: "attachments")
        chats.errorMessage = error.localizedDescription
      }
    }
  }

  private func importImages(_ images: [MacDroppedImage]) {
    guard !isStreaming else { return }
    importingAttachmentCount += 1
    Task { @MainActor in
      defer { importingAttachmentCount = max(0, importingAttachmentCount - 1) }
      do {
        appendAttachments(try await MacAttachmentImporter.importDroppedImages(images))
      } catch {
        MacAppAnalytics.reportError("attachment_import_failed", component: "attachments")
        chats.errorMessage = error.localizedDescription
      }
    }
  }

  private func importPasteboard() {
    guard !isStreaming else { return }
    importingAttachmentCount += 1
    Task { @MainActor in
      defer { importingAttachmentCount = max(0, importingAttachmentCount - 1) }
      do {
        appendAttachments(try await MacAttachmentImporter.importPasteboard())
      } catch {
        MacAppAnalytics.reportError("attachment_import_failed", component: "attachments")
        chats.errorMessage = error.localizedDescription
      }
    }
  }

  private func attachProjectFile(_ file: ProjectFile) {
    guard !isStreaming, !attachments.contains(where: { $0.id == file.id }) else { return }
    importingAttachmentCount += 1
    Task { @MainActor in
      defer { importingAttachmentCount = max(0, importingAttachmentCount - 1) }
      if let attachment = await workspace.attachment(for: file) {
        appendAttachments([attachment])
      } else if let error = workspace.consumeErrorMessage() {
        chats.errorMessage = error
      }
    }
  }
}

private struct MacAssistantMessageActions: View {
  @Environment(\.macTranscriptIsActive) private var isTranscriptActive
  @Environment(\.macPreparedAnswers) private var preparedAnswers
  @Bindable var chats: MacChatSessionModel
  let conversationID: ConversationID?
  let message: ChatMessage
  let isLatestAssistant: Bool
  var includeRetry: Bool = true
  var hideEmptyContentActions: Bool = false
  let onShowDetails: () -> Void
  let onShowSources: ([MacAnswerSource]) -> Void
  let onSaveImages: ([MacResponseImageCandidate]) -> Void
  let onRequestRegenerate: () -> Void

  @State private var copied = false
  @State private var resolvedAnswer: MacPreparedAnswer?

  private var contentCacheKey: MacAnswerCacheKey {
    MacAnswerCacheKey(source: message.content)
  }

  private var preparedAnswer: MacPreparedAnswer? {
    let key = contentCacheKey
    if let resolvedAnswer, resolvedAnswer.cacheKey == key { return resolvedAnswer }
    return preparedAnswers[key]
      ?? MacAnswerContentParseCache.shared.cachedAnswer(forKey: key)
  }

  private var canRetry: Bool {
    guard isTranscriptActive, isLatestAssistant, let conversationID else { return false }
    return !chats.isGenerating(conversationID)
  }

  private var showContentActions: Bool {
    !hideEmptyContentActions || !message.content.isEmpty
  }

  private var extractedSources: [MacAnswerSource] {
    guard showContentActions, !message.content.isEmpty else { return [] }
    return preparedAnswer?.sources ?? []
  }

  private var hasSavableImages: Bool {
    guard showContentActions, conversationID != nil, !message.content.isEmpty else { return false }
    return preparedAnswer?.hasSavableImages ?? false
  }

  var body: some View {
    let sources = extractedSources
    HStack(spacing: 2) {
      if showContentActions {
        Button {
          copyToPasteboard(message.content)
          copied = true
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
          }
        } label: {
          actionIcon(copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.plain)
        .disabled(message.content.isEmpty)
        .help(copied ? "Copied" : "Copy response")
        .accessibilityLabel(copied ? "Response copied" : "Copy response")
      }

      if includeRetry {
        Button(action: onRequestRegenerate) {
          actionIcon("arrow.clockwise")
        }
        .buttonStyle(.plain)
        .disabled(!canRetry)
        .help(canRetry ? "Retry response" : "Retry is available on the latest response")
        .accessibilityLabel("Retry response")
      }

      if !sources.isEmpty {
        Button {
          onShowSources(sources)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "globe")
              .font(.system(size: 11.5, weight: .medium))
            Text(sources.count == 1 ? "1 Source" : "\(sources.count) Sources")
              .font(.system(size: 11.5, weight: .medium))
          }
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .frame(height: 26)
          .background(MacDesignTokens.Colors.surface, in: Capsule())
          .overlay {
            Capsule()
              .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.6)
          }
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help("View \(sources.count) cited \(sources.count == 1 ? "source" : "sources")")
        .accessibilityLabel("Sources, \(sources.count)")
      }

      Menu {
        if !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Button("Copy Reasoning", systemImage: "brain") {
            copyToPasteboard(message.reasoning)
          }
        }

        if !sources.isEmpty {
          Button("Sources (\(sources.count))…", systemImage: "globe") {
            onShowSources(sources)
          }
        }

        if hasSavableImages {
          Button("Save Images…", systemImage: "photo.on.rectangle.angled") {
            let candidates = MacResponseImageScanner.imageCandidates(in: message.content)
            if !candidates.isEmpty {
              onSaveImages(candidates)
            }
          }
        }

        if showContentActions, !message.content.isEmpty {
          ShareLink(item: message.content) {
            Label("Share", systemImage: "square.and.arrow.up")
          }
        }

        if !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !sources.isEmpty
          || hasSavableImages
          || (showContentActions && !message.content.isEmpty)
        {
          Divider()
        }

        Button("Message Details", systemImage: "info.circle") {
          onShowDetails()
        }
      } label: {
        actionIcon("ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("More actions")
      .accessibilityLabel("More actions")
    }
    // Pulls the leading glyph back over its centered frame's inset so the
    // first icon's visual edge lines up with the message text above.
    .padding(.leading, -7)
    .task(id: contentCacheKey) {
      guard isTranscriptActive, showContentActions, !message.content.isEmpty else { return }
      if let cached = preparedAnswer {
        resolvedAnswer = cached
        return
      }
      let source = message.content
      let key = contentCacheKey
      if let prepared = try? await MacAnswerContentParseCache.shared.answer(for: source),
        !Task.isCancelled,
        key == contentCacheKey
      {
        resolvedAnswer = prepared
      }
    }
  }

  private func actionIcon(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(.secondary)
      .frame(width: 30, height: 30)
      .contentShape(Rectangle())
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}

private struct MacTranscriptActivityKey: EnvironmentKey {
  static let defaultValue = true
}

private struct MacPreparedAnswersKey: EnvironmentKey {
  static let defaultValue: [MacAnswerCacheKey: MacPreparedAnswer] = [:]
}

extension EnvironmentValues {
  var macTranscriptIsActive: Bool {
    get { self[MacTranscriptActivityKey.self] }
    set { self[MacTranscriptActivityKey.self] = newValue }
  }

  var macPreparedAnswers: [MacAnswerCacheKey: MacPreparedAnswer] {
    get { self[MacPreparedAnswersKey.self] }
    set { self[MacPreparedAnswersKey.self] = newValue }
  }
}

