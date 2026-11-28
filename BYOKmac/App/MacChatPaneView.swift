import AppKit
import BYOKchatProviderCore
import MacAppFoundation
import Observation
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

nonisolated enum MacMessageExportSupport {
  static func filename(for message: ChatMessage, conversationTitle: String?) -> String {
    let suffix = message.role == .assistant ? "response" : "message"
    let trimmedTitle = conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmedTitle.isEmpty || trimmedTitle == "New Chat" {
      return message.role == .assistant ? "assistant-response.md" : "message.md"
    }
    let stem = MacConversationExportSupport.markdownFilename(for: trimmedTitle)
    return "\(stem)-\(suffix).md"
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
  var inChatFindRequestID: Int = 0
  var inChatFindNextRequestID: Int = 0
  var inChatFindPreviousRequestID: Int = 0
  let attachments: [ChatAttachment]
  let isSending: Bool
  let isImportingAttachments: Bool
  let sidebarVisible: Bool
  let toggleSidebar: () -> Void
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
  let runAttachmentImport: (@escaping @MainActor () async -> [ChatAttachment]?) -> Void
  let removeAttachment: (String) -> Void
  let send: (String, [ChatAttachment]) -> Void

  @Environment(MacWorkspaceModel.self) private var workspace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var composerHeight: CGFloat = 0
  @State private var modalState = MacChatPaneModalState()
  @State private var showingTargetPopover = false
  @State private var dismissedOmittedBannerKey: String?
  @State private var revealedConversationIDs: Set<ConversationID> = []
  @State private var showingInChatFind = false
  @State private var inChatFindQuery = ""
  @State private var activeFindMatchIndex = 0
  @State private var inChatFindFocusToken = 0
  @State private var findScrollTarget: MacTranscriptFindScrollTarget?

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

  private func advanceInChatFind(delta: Int, index: MacTranscriptFindIndex) {
    guard !index.matches.isEmpty else { return }
    let count = index.matches.count
    let next = (activeFindMatchIndex + delta % count + count) % count
    activeFindMatchIndex = next
    findScrollTarget = MacTranscriptFindScrollTarget(messageID: index.matches[next].messageID)
  }

  private func closeInChatFind() {
    showingInChatFind = false
    inChatFindQuery = ""
    activeFindMatchIndex = 0
    findScrollTarget = nil
    focusComposer()
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
    return mcp.activeToolCount(for: configuration)
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
        openPrompts: { modalState.showingPromptsPicker = true },
        openChatSettings: openChatSettings,
        openTools: configureTools,
        openProject: { openProjects(headerProject?.id) },
        assignProject: { projectID in
          guard let targetConversationID = headerConversationID else { return }
          Task { @MainActor in
            if await workspace.assignConversation(targetConversationID, to: projectID) {
              await mcp.reloadFromStorage()
            } else if let error = workspace.consumeErrorMessage() {
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

      let currentMessages = chats.conversation(conversationID)?.messages ?? []
      let findIndex = showingInChatFind
        ? MacTranscriptFindSupport.search(query: inChatFindQuery, in: currentMessages)
        : .empty
      let clampedFindIndex: Int? = findIndex.matches.isEmpty
        ? nil
        : min(max(activeFindMatchIndex, 0), findIndex.matches.count - 1)
      let activeFindMatch = clampedFindIndex.map { findIndex.matches[$0] }
      let findContext = MacTranscriptFindContext(
        query: findIndex.query,
        activeMessageID: activeFindMatch?.messageID,
        activeOccurrenceInMessage: activeFindMatch?.occurrenceInMessage
      )

      ZStack(alignment: .bottom) {
        ZStack(alignment: .topTrailing) {
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
              findScrollTarget: isCurrent ? findScrollTarget : nil,
              chooseTarget: { showingTargetPopover = true },
              manageProviders: manageProviders,
              openChatSettings: openChatSettings,
              configureTools: configureTools,
              openProjects: { openProjects(activeProject?.id) },
              openPrompts: { modalState.showingPromptsPicker = true },
              applyPromptPreset: applyPromptPreset,
              onInitialLayoutReady: {
                if let id = retained.id {
                  revealedConversationIDs.insert(id)
                }
              }
            )
            .environment(\.macPreparedAnswers, retained.answers)
            .environment(\.macTranscriptIsActive, isCurrent)
            .environment(\.macTranscriptFind, isCurrent ? findContext : .empty)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .disabled(!isCurrent)
            .zIndex(isCurrent ? 1 : 0)
          }

          if showingInChatFind {
            MacTranscriptFindBar(
              query: $inChatFindQuery,
              focusToken: inChatFindFocusToken,
              matchIndex: clampedFindIndex,
              totalMatches: findIndex.totalMatches,
              onNext: { advanceInChatFind(delta: 1, index: findIndex) },
              onPrevious: { advanceInChatFind(delta: -1, index: findIndex) },
              onClose: { closeInChatFind() }
            )
            .padding(.top, 12)
            .padding(.trailing, 18)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(3)
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
        .onChange(of: inChatFindRequestID) { _, _ in
          showingInChatFind = true
          inChatFindFocusToken &+= 1
        }
        .onChange(of: inChatFindNextRequestID) { _, _ in
          guard showingInChatFind else { return }
          advanceInChatFind(delta: 1, index: findIndex)
        }
        .onChange(of: inChatFindPreviousRequestID) { _, _ in
          guard showingInChatFind else { return }
          advanceInChatFind(delta: -1, index: findIndex)
        }
        .onChange(of: inChatFindQuery) { _, _ in
          activeFindMatchIndex = 0
          let updated = MacTranscriptFindSupport.search(
            query: inChatFindQuery,
            in: chats.conversation(conversationID)?.messages ?? []
          )
          if let first = updated.matches.first {
            findScrollTarget = MacTranscriptFindScrollTarget(messageID: first.messageID)
          }
        }
        .onChange(of: conversationID) { _, _ in
          if showingInChatFind {
            activeFindMatchIndex = 0
            findScrollTarget = nil
          }
        }

        VStack(spacing: 10) {
          if let issue = configurationIssue {
            MacConfigurationRepairBanner(
              issue: issue,
              switchModel: { showingTargetPopover = true },
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
            isSending: isSending,
            isImportingAttachments: isImportingAttachments,
            showingTargetPopover: $showingTargetPopover,
            manageProviders: manageProviders,
            configureTools: configureTools,
            runAttachmentImport: runAttachmentImport,
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
    .background {
      MacChatPromptsSheetHost(
        modalState: modalState,
        workspace: workspace,
        activeProject: activeProject,
        openProjects: openProjects,
        applyPromptPreset: applyPromptPreset
      )
    }
  }

  private func applyPromptPreset(_ preset: ProjectPromptPreset) {
    let current = chats.draft(for: conversationID)
    guard let merged = MacComposerSupport.mergedPromptText(
      current: current,
      presetPrompt: preset.prompt
    ) else { return }
    chats.setDraft(merged, conversationID: conversationID)
    focusComposer()
  }
}

@MainActor
@Observable
private final class MacChatPaneModalState {
  var showingPromptsPicker = false
}

@MainActor
private struct MacChatPromptsSheetHost: View {
  @Bindable var modalState: MacChatPaneModalState
  let workspace: MacWorkspaceModel
  let activeProject: ChatProject?
  let openProjects: (ProjectID?) -> Void
  let applyPromptPreset: (ProjectPromptPreset) -> Void

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .sheet(isPresented: $modalState.showingPromptsPicker) {
        MacChatPromptsPickerSheet(
          activeProject: activeProject,
          allProjects: workspace.projects,
          openProjects: {
            modalState.showingPromptsPicker = false
            openProjects(activeProject?.id)
          },
          applyPreset: { preset in
            modalState.showingPromptsPicker = false
            applyPromptPreset(preset)
          }
        )
      }
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

  @State private var showingOverflowPopover = false
  @State private var showingProjectPicker = false

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

      MacCappedWidthLayout(maxWidth: 260) {
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
      }
      .help(title)

      if let activeProject {
        MacChatProjectBadgeButton(project: activeProject, action: openProject)
      }

      overflowMenu

      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)

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
    Button {
      showingOverflowPopover.toggle()
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(
          showingOverflowPopover
            ? MacDesignTokens.Colors.textPrimary
            : MacDesignTokens.Colors.textMuted
        )
    }
    .buttonStyle(MacIconButtonStyle())
    .popover(isPresented: $showingOverflowPopover, arrowEdge: .bottom) {
      overflowPopoverContent
        .presentationBackground(MacDesignTokens.Colors.surface)
    }
    .onChange(of: showingOverflowPopover) { _, isPresented in
      if !isPresented {
        showingProjectPicker = false
      }
    }
    .help("Chat options")
    .accessibilityLabel("Chat options")
  }

  private var overflowPopoverContent: some View {
    MacThemedActionPopoverContainer(minWidth: 224, maxWidth: 264) {
      if showingProjectPicker {
        projectPickerPopoverContent
      } else {
        mainOverflowPopoverContent
      }
    }
  }

  @ViewBuilder
  private var mainOverflowPopoverContent: some View {
    MacThemedPopoverActionRow(title: "Prompts", systemImage: "text.bubble") {
      runPopoverAction(openPrompts)
    }
    MacThemedPopoverActionRow(title: "Chat Settings", systemImage: "slider.horizontal.3") {
      runPopoverAction(openChatSettings)
    }
    MacThemedPopoverActionRow(
      title: enabledToolCount == 0 ? "Tools" : "Tools (\(enabledToolCount))",
      systemImage: "wrench.and.screwdriver"
    ) {
      runPopoverAction(openTools)
    }
    if activeProject != nil {
      MacThemedPopoverActionRow(title: "Project Settings", systemImage: "folder.badge.gearshape") {
        runPopoverAction(openProject)
      }
    }
    MacThemedPopoverActionRow(title: "Chat Usage & Analytics", systemImage: "chart.bar.xaxis") {
      runPopoverAction(openAnalytics)
    }

    if hasPersistedConversation && (activeProject != nil || !allProjects.isEmpty) {
      MacThemedPopoverDivider()

      if let activeProject {
        MacThemedPopoverActionRow(
          title: "Remove from \(activeProject.name)",
          systemImage: "folder.badge.minus"
        ) {
          runPopoverAction { assignProject(nil) }
        }
        if !otherProjects.isEmpty {
          MacThemedPopoverActionRow(
            title: "Move to Project",
            systemImage: "folder.badge.plus",
            showsDisclosureChevron: true
          ) {
            showingProjectPicker = true
          }
        }
      } else if !allProjects.isEmpty {
        MacThemedPopoverActionRow(
          title: "Add to Project",
          systemImage: "folder.badge.plus",
          showsDisclosureChevron: true
        ) {
          showingProjectPicker = true
        }
      }
    }

    MacThemedPopoverDivider()

    MacThemedPopoverActionRow(title: "Rename", systemImage: "pencil") {
      runPopoverAction(renameConversation)
    }
    .disabled(!hasPersistedConversation)

    MacThemedPopoverActionRow(title: "Export as Markdown", systemImage: "square.and.arrow.up") {
      runPopoverAction(exportMarkdown)
    }
    .disabled(!canExportMarkdown)

    MacThemedPopoverDivider()

    MacThemedPopoverActionRow(
      title: "Delete",
      systemImage: "trash",
      isDestructive: true
    ) {
      runPopoverAction(deleteConversation)
    }
    .disabled(!hasPersistedConversation)
  }

  @ViewBuilder
  private var projectPickerPopoverContent: some View {
    let destinations = activeProject == nil ? allProjects : otherProjects
    let rows = VStack(alignment: .leading, spacing: 2) {
      ForEach(destinations) { project in
        let accent = MacProjectAccentOption(rawValue: project.accentID)?.color ?? .blue
        MacThemedPopoverActionRow(
          title: project.name,
          systemImage: project.symbolName,
          iconTint: accent
        ) {
          runPopoverAction { assignProject(project.id) }
        }
      }
    }

    MacThemedPopoverActionRow(
      title: activeProject == nil ? "Add to Project" : "Move to Project",
      systemImage: "chevron.left"
    ) {
      showingProjectPicker = false
    }

    MacThemedPopoverDivider()

    if destinations.count > 7 {
      ScrollView {
        rows
      }
      .frame(height: 220)
    } else {
      rows
    }
  }

  private func runPopoverAction(_ action: () -> Void) {
    showingOverflowPopover = false
    action()
  }
}

private struct MacChatProjectBadgeButton: View {
  let project: ChatProject
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    let accent = MacProjectAccentOption(rawValue: project.accentID)?.color ?? .blue
    MacCappedWidthLayout(maxWidth: 160) {
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
      .help("Open \(project.name) in Projects")
      .accessibilityLabel("Project \(project.name)")
    }
  }
}

/// Constrains a child to `maxWidth` while hugging its intrinsic width when narrower.
private struct MacCappedWidthLayout: Layout {
  let maxWidth: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    guard let child = subviews.first else { return .zero }
    let cappedWidth = min(proposal.width ?? maxWidth, maxWidth)
    return child.sizeThatFits(
      ProposedViewSize(width: cappedWidth, height: proposal.height)
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    guard let child = subviews.first else { return }
    child.place(
      at: bounds.origin,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
    )
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
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.standardHeight
    )
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

private struct MacTranscriptFindScrollTarget: Equatable {
  let token = UUID()
  let messageID: ChatMessageID
}

private struct MacTranscriptFindBar: View {
  @Binding var query: String
  let focusToken: Int
  let matchIndex: Int?
  let totalMatches: Int
  let onNext: () -> Void
  let onPrevious: () -> Void
  let onClose: () -> Void

  @Environment(\.macAppTheme) private var theme
  @FocusState private var isFocused: Bool

  private var statusText: String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    guard totalMatches > 0, let matchIndex else { return "No matches" }
    return "\(matchIndex + 1) of \(totalMatches)"
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(theme.textMuted)

      TextField("Find in conversation", text: $query)
        .textFieldStyle(.plain)
        .font(.system(size: 12.5))
        .foregroundStyle(theme.textPrimary)
        .frame(width: 170)
        .focused($isFocused)
        .onSubmit {
          if NSEvent.modifierFlags.contains(.shift) {
            onPrevious()
          } else {
            onNext()
          }
        }
        .onExitCommand(perform: onClose)

      if !statusText.isEmpty {
        Text(statusText)
          .font(.system(size: 11, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(totalMatches == 0 ? theme.destructive : theme.textMuted)
          .lineLimit(1)
      }

      Divider()
        .frame(height: 14)

      Button("Previous Match", systemImage: "chevron.up", action: onPrevious)
        .labelStyle(.iconOnly)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(theme.textMuted)
        .buttonStyle(MacIconButtonStyle())
        .disabled(totalMatches == 0)
        .help("Previous match (⇧⌘G)")

      Button("Next Match", systemImage: "chevron.down", action: onNext)
        .labelStyle(.iconOnly)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(theme.textMuted)
        .buttonStyle(MacIconButtonStyle())
        .disabled(totalMatches == 0)
        .help("Next match (⌘G)")

      Button("Close Find", systemImage: "xmark", action: onClose)
        .labelStyle(.iconOnly)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(theme.textMuted)
        .buttonStyle(MacIconButtonStyle())
        .help("Close find bar (Esc)")
    }
    .padding(.leading, 10)
    .padding(.trailing, 6)
    .padding(.vertical, 5)
    .background(theme.surface, in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
        .stroke(theme.separator, lineWidth: 0.85)
    }
    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    .onAppear {
      isFocused = true
    }
    .onChange(of: focusToken) { _, _ in
      isFocused = true
    }
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
  let findScrollTarget: MacTranscriptFindScrollTarget?
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
  @State private var scrollState = MacTranscriptScrollState()
  @State private var transcriptContentWidth: CGFloat = 0
  @State private var hasCompletedInitialScroll = false
  @State private var hasRevealedInitialLayout: Bool
  @State private var pendingSourceMessageID: ChatMessageID?
  @State private var pendingScrollTarget: PendingScrollTarget?
  @State private var visibleMessageLimit = MacChatMessageWindowPolicy.initialVisibleCount
  @State private var isLoadingEarlierMessages = false
  @State private var pendingEarlierAnchorID: ChatMessageID?
  @State private var modalState = MacTranscriptModalState()

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
    findScrollTarget: MacTranscriptFindScrollTarget? = nil,
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
    self.findScrollTarget = findScrollTarget
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

  private func hasActiveMCPInteractions(for conversationID: ConversationID) -> Bool {
    !mcp.pendingApprovals(for: conversationID).isEmpty
      || !mcp.pendingElicitations(for: conversationID).isEmpty
      || !chats.activeToolCalls(for: conversationID).isEmpty
  }

  private var activeTargetMessageID: ChatMessageID? {
    if let pendingSourceMessageID { return pendingSourceMessageID }
    if let pendingScrollTarget { return pendingScrollTarget.messageID }
    if let findScrollTarget { return findScrollTarget.messageID }
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
                transcriptRow(bottomSpacing: message.role == .user ? 22 : 48) {
                  MacTranscriptMessageRow(
                    providers: providers,
                    chats: chats,
                    mcp: mcp,
                    conversationID: conversationID,
                    message: message,
                    failureContext: failureContextLabel(for: message, accountsByID: accountsByID),
                    isLatestAssistant: isLatestAssistant,
                    onShowDetails: { modalState.activeRowSheet = .details($0) },
                    onEditMessage: { modalState.activeRowSheet = .edit($0) },
                    onPreviewAttachment: { attachment, owner in
                      modalState.activeRowSheet = .previewAttachment(attachment, owner)
                    },
                    onSaveImages: { modalState.activeRowSheet = .saveImages(message, $0) },
                    onRequestRegenerate: requestRegeneration
                  )
                }
                .id(message.id.rawValue)
              }
            }

            if let conversationID, hasActiveMCPInteractions(for: conversationID) {
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
            scrollState.isNearBottom = current.isNearBottom
            scrollState.isUserDraggingTimeline = current.isUserScrolling
            let shouldShow = MacTranscriptScrollPolicy.shouldShowJumpToLatest(
              isNearBottom: current.isNearBottom,
              hasCompletedInitialScroll: hasCompletedInitialScroll
            )
            if scrollState.showJumpToLatest != shouldShow {
              scrollState.showJumpToLatest = shouldShow
            }

            if current.isNearBottom {
              scrollState.followsLatest = true
            } else if current.userDidScroll {
              scrollState.followsLatest = false
            }

            if let previous,
              previous.contentHeight != current.contentHeight,
              !current.userDidScroll,
              MacTranscriptScrollPolicy.shouldFollowContentGrowth(
                hasCompletedInitialScroll: hasCompletedInitialScroll,
                followsLatest: scrollState.followsLatest,
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
          guard scrollState.followsLatest, !scrollState.isUserDraggingTimeline else {
            scrollState.showJumpToLatest = !scrollState.isNearBottom
            return
          }
          scrollToBottom(proxy, animated: true)
        }
        .onChange(of: isActive ? mcp.pendingApprovals.count : 0) { _, _ in
          guard isActive, scrollState.followsLatest, !scrollState.isUserDraggingTimeline else { return }
          scrollToBottom(proxy, animated: true)
        }
        .onChange(of: isActive ? mcp.pendingElicitations.count : 0) { _, _ in
          guard isActive, scrollState.followsLatest, !scrollState.isUserDraggingTimeline else { return }
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
            scrollState.followsLatest = true
            scrollState.isUserDraggingTimeline = false
            scrollState.showJumpToLatest = false
          } else if scrollState.followsLatest {
            // The live row can change height when its completed representation
            // replaces it. Re-anchor explicitly rather than restoring a
            // persistent scroll position into List's recycled rows.
            scrollToBottom(proxy, animated: false)
          } else if !scrollState.isNearBottom {
            scrollState.showJumpToLatest = true
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
        .onChange(of: findScrollTarget) { _, target in
          guard isActive, let target else { return }
          scrollState.followsLatest = false
          pendingScrollTarget = PendingScrollTarget(messageID: target.messageID)
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
            scrollState.showJumpToLatest = !scrollState.isNearBottom
          }
          pendingScrollTarget = nil
        }
        .task(id: isActive) {
          guard isActive else { return }
          scrollState.isUserDraggingTimeline = false
          await Task.yield()
          guard !Task.isCancelled else { return }
          if !scrollToPendingSourceMessageIfAvailable(proxy), scrollState.followsLatest {
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
          scrollState.showJumpToLatest = !scrollState.isNearBottom
        }

        if isActive, conversationID != nil, !messages.isEmpty {
          MacTranscriptJumpToLatestButton(
            scrollState: scrollState,
            bottomSpace: bottomSpace
          ) {
            scrollState.followsLatest = true
            scrollState.isUserDraggingTimeline = false
            scrollState.showJumpToLatest = false
            pendingSourceMessageID = nil
            pendingScrollTarget = nil
            scrollToBottom(proxy, animated: true)
          }
        }
      }
      .environment(\.macTranscriptContentWidth, transcriptContentWidth)
      .onGeometryChange(for: CGFloat.self) { proxy in
        let available = max(proxy.size.width - MacDesignTokens.Spacing.large * 2, 0)
        let clamped = min(available, MacDesignTokens.Layout.transcriptMaximumWidth)
        return (clamped / 2).rounded() * 2
      } action: { newWidth in
        if newWidth > 1, abs(newWidth - transcriptContentWidth) > 1 {
          transcriptContentWidth = newWidth
        }
      }
      .background {
        MacTranscriptModalHost(
          modalState: modalState,
          providers: providers,
          chats: chats,
          mcp: mcp,
          workspace: workspace,
          toastCenter: toastCenter,
          conversationID: conversationID,
          chooseTarget: chooseTarget,
          manageProviders: manageProviders,
          onConfirmRegenerate: {
            regenerate(confirmingUncertainCompletion: true)
          }
        )
      }
    }
  }

  private func requestRegeneration() {
    guard let conversationID else { return }
    if chats.latestAssistantRequiresRegenerationConfirmation(conversationID) {
      modalState.showingRegenerateConfirmation = true
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
    scrollState.followsLatest = false
    scrollState.isUserDraggingTimeline = false
    scrollState.showJumpToLatest = true

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

private enum MacTranscriptRowSheet: Identifiable {
  case details(ChatMessage)
  case edit(ChatMessage)
  case previewAttachment(ChatAttachment, ChatMessage)
  case saveImages(ChatMessage, [MacResponseImageCandidate])

  var id: String {
    switch self {
    case .details(let message): "details-\(message.id.rawValue)"
    case .edit(let message): "edit-\(message.id.rawValue)"
    case .previewAttachment(let attachment, let message): "attachment-\(message.id.rawValue)-\(attachment.id)"
    case .saveImages(let message, _): "save-images-\(message.id.rawValue)"
    }
  }
}

@MainActor
@Observable
private final class MacTranscriptModalState {
  var activeRowSheet: MacTranscriptRowSheet?
  var showingRegenerateConfirmation = false
}

@MainActor
private struct MacTranscriptModalHost: View {
  @Bindable var modalState: MacTranscriptModalState
  let providers: MacProviderModel
  let chats: MacChatSessionModel
  let mcp: MacMCPModel
  let workspace: MacWorkspaceModel
  let toastCenter: MacToastCenter?
  let conversationID: ConversationID?
  let chooseTarget: () -> Void
  let manageProviders: () -> Void
  let onConfirmRegenerate: () -> Void

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .sheet(item: $modalState.activeRowSheet) { sheet in
        rowModalContent(for: sheet)
      }
      .confirmationDialog(
        "Regenerate this response?",
        isPresented: $modalState.showingRegenerateConfirmation,
        titleVisibility: .visible
      ) {
        Button("Regenerate") {
          onConfirmRegenerate()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("The provider may have completed the previous request even though BYOKchat could not confirm it. Regenerating can create another billable response.")
      }
  }

  @ViewBuilder
  private func rowModalContent(for sheet: MacTranscriptRowSheet) -> some View {
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
}

private struct MacTranscriptSkeletonView: View {
  let bottomSpace: CGFloat

  var body: some View {
    Color.clear
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
      .background(MacDesignTokens.Colors.canvas)
      .overlay(alignment: .bottom) {
        MacTranscriptSkeletonContent()
          .frame(maxWidth: MacDesignTokens.Layout.transcriptMaximumWidth, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.horizontal, MacDesignTokens.Spacing.large)
          .padding(.top, MacDesignTokens.Spacing.transcriptTop)
          .padding(.bottom, bottomSpace + 28)
      }
      .clipped()
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

nonisolated enum MacComposerSupport: Sendable {
  enum ReturnKeyAction: Equatable, Sendable {
    case send
    case insertNewline
    case passThroughToEditor
    case swallow
  }

  static func returnKeyAction(
    modifiers: EventModifiers,
    hasMarkedText: Bool,
    canSend: Bool
  ) -> ReturnKeyAction {
    if hasMarkedText {
      return .passThroughToEditor
    }
    if modifiers.contains(.shift) || modifiers.contains(.option) {
      return .insertNewline
    }
    if modifiers.contains(.control) {
      return .passThroughToEditor
    }
    if modifiers.contains(.command) || modifiers.isEmpty {
      return canSend ? .send : .swallow
    }
    return .passThroughToEditor
  }

  /// Checks whether any pending composer attachment is incompatible with the
  /// currently selected provider/model. Uses `isTextLike` for metadata-only
  /// pending files (whose bytes live on disk) and allows unsupported image
  /// MIME types that will be auto-transcoded to JPEG on send.
  static func attachmentCompatibilityWarning(
    attachments: [ChatAttachment],
    providerKind: ProviderKind,
    capabilities: ResolvedModelCapabilities
  ) -> String? {
    guard !attachments.isEmpty else { return nil }

    for attachment in attachments {
      if attachment.byteCount > MacAttachmentImporter.maximumFileBytes {
        return "\(attachment.filename) exceeds the 20 MB attachment limit."
      }

      let mime = attachment.mimeType.lowercased()
      let capability: ModelCapability = if attachment.isImage {
        .imageInput
      } else if mime.hasPrefix("audio/") {
        .audioInput
      } else if attachment.isTextLike {
        .textInput
      } else {
        .fileInput
      }

      if capabilities[capability] == .unsupported {
        return "\(attachment.filename) is not supported by the selected model. Choose another model or remove it."
      }

      if providerKind == .anthropic {
        if attachment.isImage, attachment.byteCount > 5 * 1_024 * 1_024 {
          return "\(attachment.filename) exceeds Anthropic's 5 MB image limit."
        }
        if !attachment.isImage, !attachment.isTextLike, mime != "application/pdf" {
          return "Anthropic supports text files, images, and PDFs. Remove \(attachment.filename) or switch models."
        }
      }
    }

    return nil
  }

  static func attachmentBudgetSummary(count: Int, totalBytes: Int) -> String {
    let size = ByteCountFormatter.string(fromByteCount: Int64(max(0, totalBytes)), countStyle: .file)
    return "\(count) / \(MacAttachmentImporter.maximumCount) · \(size)"
  }

  static func mergedPromptText(current: String, presetPrompt: String) -> String? {
    let value = presetPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return value
    }
    return current + "\n\n" + value
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
  let isSending: Bool
  let isImportingAttachments: Bool
  @Binding var showingTargetPopover: Bool
  let manageProviders: () -> Void
  let configureTools: () -> Void
  let runAttachmentImport: (@escaping @MainActor () async -> [ChatAttachment]?) -> Void
  let removeAttachment: (String) -> Void
  let send: (String, [ChatAttachment]) -> Void

  private enum AttachmentPopoverPage {
    case main
    case projectFiles
    case prompts
  }

  @Environment(MacWorkspaceModel.self) private var workspace
  @FocusState private var editorFocused: Bool
  @State private var urlDropTargeted = false
  @State private var imageDropTargeted = false
  @State private var showingAttachmentPopover = false
  @State private var attachmentPopoverPage: AttachmentPopoverPage = .main
  @State private var showingFileImporter = false
  @State private var showingLibraryPicker = false
  @State private var previewingAttachment: ChatAttachment?
  @State private var suppressComposerRefocusOnPopoverDismiss = false

  private var fileDropTargeted: Bool {
    urlDropTargeted || imageDropTargeted
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

  private var isAttachmentEditingDisabled: Bool {
    isStreaming || isSending || target == nil
  }

  private var isAtAttachmentLimit: Bool {
    attachments.count >= MacAttachmentImporter.maximumCount
  }

  private var remainingAttachmentSlots: Int {
    max(0, MacAttachmentImporter.maximumCount - attachments.count)
  }

  private var totalAttachmentBytes: Int {
    attachments.reduce(0) { $0 + $1.byteCount }
  }

  private var attachmentCompatibilityWarning: String? {
    guard let target, let account = selectedAccount, !attachments.isEmpty else { return nil }
    let capabilities = providers.capabilities(accountID: target.accountID, modelID: target.modelID)
    return MacComposerSupport.attachmentCompatibilityWarning(
      attachments: attachments,
      providerKind: account.kind,
      capabilities: capabilities
    )
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
      && attachmentCompatibilityWarning == nil
      && !isStreaming
      && !isSending
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
    return mcp.activeToolCount(for: configuration)
  }

  private var borderColor: Color {
    if fileDropTargeted {
      return MacDesignTokens.Colors.accent
    }
    if editorFocused {
      return MacDesignTokens.Colors.accent.opacity(0.55)
    }
    return MacDesignTokens.Colors.separator.opacity(0.8)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let warning = attachmentCompatibilityWarning {
        attachmentWarningBar(warning)
      }

      if !attachments.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text("Attachments")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Spacer(minLength: 8)
            Text(
              MacComposerSupport.attachmentBudgetSummary(
                count: attachments.count,
                totalBytes: totalAttachmentBytes
              )
            )
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(
              isAtAttachmentLimit ? Color.orange : MacDesignTokens.Colors.textMuted
            )
          }
          .padding(.horizontal, 14)

          MacAttachmentStrip(
            attachments: attachments,
            presentation: .composer,
            remove: removeAttachment,
            addAttachment: { showingFileImporter = true },
            isImportingAttachments: isImportingAttachments,
            isEditingDisabled: isAttachmentEditingDisabled,
            onOpenAttachment: { previewingAttachment = $0 }
          )
          .padding(.horizontal, 12)
        }
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
        .stroke(borderColor, lineWidth: fileDropTargeted ? 1.5 : (editorFocused ? 1 : 0.75))
    }
    .overlay {
      if fileDropTargeted {
        composerDropOverlay
      }
    }
    .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: editorFocused)
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: fileDropTargeted)
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
        existingAttachmentByteCount: totalAttachmentBytes,
        attach: { additions in
          runAttachmentImport { additions }
        }
      )
    }
    .sheet(item: $previewingAttachment) { attachment in
      MacAttachmentPreviewSheet(
        attachment: attachment,
        loadData: { id in
          await chats.attachmentData(id)
        },
        preferLoadData: true
      )
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard !urls.isEmpty, !isAttachmentEditingDisabled else { return false }
      importURLs(urls)
      return true
    } isTargeted: { targeted in
      urlDropTargeted = targeted && !isAttachmentEditingDisabled
    }
    .dropDestination(for: MacDroppedImage.self) { images, _ in
      guard !images.isEmpty, !isAttachmentEditingDisabled else { return false }
      importImages(images)
      return true
    } isTargeted: { targeted in
      imageDropTargeted = targeted && !isAttachmentEditingDisabled
    }
    .onChange(of: focusRequestID) { _, _ in
      editorFocused = true
    }
    .onChange(of: conversationID) { _, _ in
      urlDropTargeted = false
      imageDropTargeted = false
      if showingTargetPopover {
        suppressComposerRefocusOnPopoverDismiss = true
        showingTargetPopover = false
      }
    }
  }

  private var composerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 18, style: .continuous)
  }

  private var composerDropOverlay: some View {
    ZStack {
      composerShape
        .fill(MacDesignTokens.Colors.accentSoft.opacity(0.85))
      composerShape
        .strokeBorder(
          MacDesignTokens.Colors.accent,
          style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
        )
      Label(
        isAtAttachmentLimit
          ? "Attachment limit reached (\(MacAttachmentImporter.maximumCount)/\(MacAttachmentImporter.maximumCount))"
          : "Drop files or images to attach",
        systemImage: isAtAttachmentLimit ? "exclamationmark.circle" : "arrow.down.doc"
      )
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(isAtAttachmentLimit ? Color.orange : MacDesignTokens.Colors.accent)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(MacDesignTokens.Colors.surface.opacity(0.92), in: Capsule())
    }
    .allowsHitTesting(false)
  }

  private func attachmentWarningBar(_ message: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      Text(message)
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 6)

      Button("Switch Model") {
        editorFocused = false
        showingTargetPopover = true
      }
      .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
      .disabled(isStreaming || isSending)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.orange.opacity(0.10))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.orange.opacity(0.28))
        .frame(height: 0.75)
    }
  }

  private var messageField: some View {
    TextField(
      target == nil
        ? "Set up a provider to chat…"
        : (isStreaming ? "Draft a follow-up message…" : "Message…"),
      text: draftBinding,
      axis: .vertical
    )
    .textFieldStyle(.plain)
    .font(.system(size: 15))
    .lineLimit(1...8)
    .focused($editorFocused)
    .padding(.horizontal, 3)
    .padding(.vertical, 6)
    .disabled(target == nil)
    .accessibilityLabel("Message")
    .accessibilityHint(
      target == nil
        ? "Set up a provider before composing a message"
        : "Return sends. Shift Return or Option Return inserts a new line"
    )
    .onKeyPress(keys: [.return], phases: .down) { press in
      let textView = NSApp.keyWindow?.firstResponder as? NSTextView
      let hasMarkedText = textView?.hasMarkedText() == true
      switch MacComposerSupport.returnKeyAction(
        modifiers: press.modifiers,
        hasMarkedText: hasMarkedText,
        canSend: canSend
      ) {
      case .send:
        submit()
        return .handled
      case .insertNewline:
        if let textView {
          textView.insertNewlineIgnoringFieldEditor(nil)
        } else {
          draftBinding.wrappedValue.append("\n")
        }
        return .handled
      case .passThroughToEditor:
        return .ignored
      case .swallow:
        return .handled
      }
    }
    .onKeyPress(characters: CharacterSet(charactersIn: "vV"), phases: .down) { press in
      guard press.modifiers == .command,
        !isAttachmentEditingDisabled,
        !isImportingAttachments,
        MacAttachmentImporter.pasteboardPrefersAttachmentOnPaste()
      else {
        return .ignored
      }
      importPasteboard()
      return .handled
    }
  }

  private var bottomControls: some View {
    HStack(spacing: 8) {
      attachmentMenu
      targetButton

      if enabledToolCount > 0 {
        toolsPillButton
      }

      Spacer(minLength: 10)
      sendButton
    }
    .frame(minHeight: 34)
  }

  private var attachmentMenu: some View {
    Button {
      editorFocused = false
      showingAttachmentPopover.toggle()
    } label: {
      MacComposerPlusButtonLabel(
        isImporting: isImportingAttachments,
        isDisabled: isAttachmentEditingDisabled || isImportingAttachments
      )
    }
    .buttonStyle(.plain)
    .popover(isPresented: $showingAttachmentPopover, arrowEdge: .top) {
      attachmentPopoverContent
        .presentationBackground(MacDesignTokens.Colors.surface)
    }
    .onChange(of: showingAttachmentPopover) { _, isPresented in
      if !isPresented {
        attachmentPopoverPage = .main
      }
    }
    .disabled(isAttachmentEditingDisabled || isImportingAttachments)
    .accessibilityLabel(isImportingAttachments ? "Importing attachments" : "Add or configure")
    .help(
      isImportingAttachments
        ? "Importing attachments…"
        : "Add attachments, project prompts, or configure chat tools"
    )
  }

  private var attachmentPopoverContent: some View {
    MacThemedActionPopoverContainer(minWidth: 224, maxWidth: 268) {
      switch attachmentPopoverPage {
      case .main:
        mainAttachmentPopoverContent
      case .projectFiles:
        projectFilesPopoverContent
      case .prompts:
        promptsPopoverContent
      }
    }
  }

  @ViewBuilder
  private var mainAttachmentPopoverContent: some View {
    if isAtAttachmentLimit {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.circle")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.orange)
          .frame(width: 16, alignment: .center)
        Text("Attachment limit reached (\(MacAttachmentImporter.maximumCount)/\(MacAttachmentImporter.maximumCount))")
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .lineLimit(1)
      }
      .padding(.horizontal, 8)
      .frame(height: 26, alignment: .leading)

      MacThemedPopoverDivider()
    }

    MacThemedPopoverActionRow(title: "Choose Files", systemImage: "doc.badge.plus") {
      runAttachmentPopoverAction { showingFileImporter = true }
    }
    .disabled(isAtAttachmentLimit)

    MacThemedPopoverActionRow(title: "Paste Image or File", systemImage: "doc.on.clipboard") {
      runAttachmentPopoverAction(importPasteboard)
    }
    .disabled(isAtAttachmentLimit)

    MacThemedPopoverDivider()

    MacThemedPopoverActionRow(title: "From Library", systemImage: "books.vertical") {
      runAttachmentPopoverAction { showingLibraryPicker = true }
    }
    .disabled(isAtAttachmentLimit)

    if !projectFiles.isEmpty {
      MacThemedPopoverActionRow(
        title: "Project Files",
        systemImage: "folder.badge.plus",
        showsDisclosureChevron: true
      ) {
        attachmentPopoverPage = .projectFiles
      }
    }

    if !promptPresets.isEmpty {
      MacThemedPopoverDivider()

      MacThemedPopoverActionRow(
        title: "Prompts",
        systemImage: "text.bubble",
        showsDisclosureChevron: true
      ) {
        attachmentPopoverPage = .prompts
      }
    }

    MacThemedPopoverDivider()

    MacThemedPopoverActionRow(
      title: enabledToolCount == 0 ? "Tools" : "Tools · \(enabledToolCount)",
      systemImage: "wrench.and.screwdriver"
    ) {
      runAttachmentPopoverAction(configureTools)
    }
  }

  @ViewBuilder
  private var projectFilesPopoverContent: some View {
    let attachedIDs = Set(attachments.map(\.id))
    let rows = VStack(alignment: .leading, spacing: 2) {
      ForEach(projectFiles) { file in
        let isAttached = attachedIDs.contains(file.id)
        MacThemedPopoverActionRow(
          title: file.filename,
          systemImage: isAttached ? "checkmark" : "doc",
          iconTint: isAttached ? MacDesignTokens.Colors.accent : nil
        ) {
          runAttachmentPopoverAction { attachProjectFile(file) }
        }
        .disabled(isAttached || isAtAttachmentLimit)
      }
    }

    MacThemedPopoverActionRow(title: "Project Files", systemImage: "chevron.left") {
      attachmentPopoverPage = .main
    }

    MacThemedPopoverDivider()

    if projectFiles.count > 7 {
      ScrollView {
        rows
      }
      .frame(height: 220)
    } else {
      rows
    }
  }

  @ViewBuilder
  private var promptsPopoverContent: some View {
    let rows = VStack(alignment: .leading, spacing: 2) {
      ForEach(promptPresets) { preset in
        MacThemedPopoverActionRow(title: preset.name, systemImage: "text.bubble") {
          runAttachmentPopoverAction { applyPromptPreset(preset) }
        }
      }
    }

    MacThemedPopoverActionRow(title: "Prompts", systemImage: "chevron.left") {
      attachmentPopoverPage = .main
    }

    MacThemedPopoverDivider()

    if promptPresets.count > 7 {
      ScrollView {
        rows
      }
      .frame(height: 220)
    } else {
      rows
    }
  }

  private func runAttachmentPopoverAction(_ action: () -> Void) {
    showingAttachmentPopover = false
    action()
  }

  private var targetButton: some View {
    MacComposerTargetPillButton(
      title: target == nil ? "Set Up Provider" : targetLabel,
      showsChevron: target != nil,
      isDisabled: isStreaming || isSending
    ) {
      editorFocused = false
      if target == nil {
        manageProviders()
      } else {
        showingTargetPopover.toggle()
      }
    }
    .popover(isPresented: $showingTargetPopover, arrowEdge: .top) {
      MacComposerModelPopover(
        providers: providers,
        initialTarget: target,
        maxOutputTokens: chats.effectiveOptions(for: conversationID).maxOutputTokens,
        manageProviders: {
          suppressComposerRefocusOnPopoverDismiss = true
          showingTargetPopover = false
          manageProviders()
        },
        onCommit: { newTarget in
          await chats.applyTarget(newTarget, conversationID: conversationID)
        }
      )
    }
    .onChange(of: showingTargetPopover) { wasPresented, isPresented in
      if wasPresented && !isPresented {
        if suppressComposerRefocusOnPopoverDismiss {
          suppressComposerRefocusOnPopoverDismiss = false
        } else {
          editorFocused = true
        }
      }
    }
    .help(target == nil ? "Set up a provider" : "Change model or reasoning (\(targetDetails))")
    .accessibilityLabel("Change provider, model, and reasoning")
    .accessibilityValue(targetDetails)
  }

  private var toolsPillButton: some View {
    MacComposerToolsPillButton(
      count: enabledToolCount,
      isDisabled: isStreaming || isSending,
      action: configureTools
    )
    .help("\(enabledToolCount) active MCP \(enabledToolCount == 1 ? "tool" : "tools") — click to configure")
    .accessibilityLabel("Configure tools, \(enabledToolCount) active")
  }

  private var sendButton: some View {
    MacComposerSendButton(
      isStreaming: isStreaming,
      isSending: isSending,
      canSend: canSend
    ) {
      if isStreaming {
        Task { await chats.stop(conversationID) }
      } else {
        submit()
      }
    }
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
      attachmentCompatibilityWarning == nil,
      !isStreaming,
      !isSending,
      !isImportingAttachments
    else { return }
    send(text, attachments)
  }

  private func applyPromptPreset(_ preset: ProjectPromptPreset) {
    guard let merged = MacComposerSupport.mergedPromptText(
      current: draftBinding.wrappedValue,
      presetPrompt: preset.prompt
    ) else { return }
    draftBinding.wrappedValue = merged
    editorFocused = true
  }

  private func importURLs(_ urls: [URL]) {
    guard !isAttachmentEditingDisabled else { return }
    guard urls.count <= remainingAttachmentSlots else {
      chats.errorMessage = "A message can include at most \(MacAttachmentImporter.maximumCount) attachments."
      return
    }
    runAttachmentImport {
      do {
        return try await MacAttachmentImporter.importURLs(urls)
      } catch {
        MacAppAnalytics.reportError("attachment_import_failed", component: "attachments")
        chats.errorMessage = error.localizedDescription
        return nil
      }
    }
  }

  private func importImages(_ images: [MacDroppedImage]) {
    guard !isAttachmentEditingDisabled else { return }
    guard images.count <= remainingAttachmentSlots else {
      chats.errorMessage = "A message can include at most \(MacAttachmentImporter.maximumCount) attachments."
      return
    }
    runAttachmentImport {
      do {
        return try await MacAttachmentImporter.importDroppedImages(images)
      } catch {
        MacAppAnalytics.reportError("attachment_import_failed", component: "attachments")
        chats.errorMessage = error.localizedDescription
        return nil
      }
    }
  }

  private func importPasteboard() {
    guard !isAttachmentEditingDisabled else { return }
    guard !isAtAttachmentLimit else {
      chats.errorMessage = "A message can include at most \(MacAttachmentImporter.maximumCount) attachments."
      return
    }
    runAttachmentImport {
      do {
        return try await MacAttachmentImporter.importPasteboard()
      } catch {
        MacAppAnalytics.reportError("attachment_import_failed", component: "attachments")
        chats.errorMessage = error.localizedDescription
        return nil
      }
    }
  }

  private func attachProjectFile(_ file: ProjectFile) {
    guard !isAttachmentEditingDisabled, !attachments.contains(where: { $0.id == file.id }) else { return }
    guard !isAtAttachmentLimit else {
      chats.errorMessage = "A message can include at most \(MacAttachmentImporter.maximumCount) attachments."
      return
    }
    runAttachmentImport {
      if let attachment = await workspace.attachment(for: file) {
        return [attachment]
      }
      if let error = workspace.consumeErrorMessage() {
        chats.errorMessage = error
      }
      return nil
    }
  }
}

private struct MacComposerPlusButtonLabel: View {
  let isImporting: Bool
  let isDisabled: Bool

  @State private var isHovered = false

  var body: some View {
    Group {
      if isImporting {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: "plus")
          .font(.system(size: 16, weight: .regular))
          .foregroundStyle(
            isHovered && !isDisabled
              ? MacDesignTokens.Colors.textPrimary
              : MacDesignTokens.Colors.textMuted
          )
      }
    }
    .frame(width: 34, height: 34)
    .background(
      Color.primary.opacity(isHovered && !isDisabled ? MacDesignTokens.Control.hoverOpacity : 0),
      in: Circle()
    )
    .contentShape(Circle())
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
  }
}

private struct MacComposerTargetPillButton: View {
  let title: String
  let showsChevron: Bool
  let isDisabled: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text(title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        if showsChevron {
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(
        Color.primary.opacity(isHovered && !isDisabled ? 0.065 : 0.025),
        in: Capsule()
      )
      .overlay {
        Capsule()
          .stroke(
            isHovered && !isDisabled
              ? MacDesignTokens.Colors.accent.opacity(0.45)
              : MacDesignTokens.Colors.separator.opacity(0.95),
            lineWidth: 0.75
          )
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .opacity(isDisabled ? MacDesignTokens.Control.disabledOpacity : 1)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
  }
}

private struct MacComposerToolsPillButton: View {
  let count: Int
  let isDisabled: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: "wrench.and.screwdriver")
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.accent)
        Text("\(count)")
          .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      }
      .padding(.horizontal, 9)
      .frame(height: 26)
      .background(
        MacDesignTokens.Colors.accentSoft.opacity(isHovered && !isDisabled ? 0.95 : 0.65),
        in: Capsule()
      )
      .overlay {
        Capsule()
          .stroke(
            MacDesignTokens.Colors.accent.opacity(isHovered && !isDisabled ? 0.55 : 0.30),
            lineWidth: 0.75
          )
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .opacity(isDisabled ? MacDesignTokens.Control.disabledOpacity : 1)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
  }
}

private struct MacComposerSendButton: View {
  let isStreaming: Bool
  let isSending: Bool
  let canSend: Bool
  let action: () -> Void

  @State private var isHovered = false

  private var isInteractive: Bool {
    isStreaming || (canSend && !isSending)
  }

  private var fillOpacity: Double {
    if isSending { return 0.72 }
    guard isInteractive else { return 0.34 }
    return isHovered ? 0.86 : 0.96
  }

  var body: some View {
    Button(action: action) {
      Group {
        if isSending && !isStreaming {
          ProgressView()
            .controlSize(.small)
            .tint(.white)
        } else {
          Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
        }
      }
      .frame(width: 34, height: 34)
      .background(
        MacDesignTokens.Colors.accent.opacity(fillOpacity),
        in: Circle()
      )
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!isInteractive)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .help(
      isStreaming
        ? "Stop response (⌘.)"
        : (isSending ? "Sending…" : "Send message (Return)")
    )
    .accessibilityLabel(
      isStreaming ? "Stop response" : (isSending ? "Sending message" : "Send message")
    )
    .accessibilityHint(
      isStreaming ? "Stops the current model response" : "Sends the current message and attachments"
    )
  }
}

private struct MacTranscriptMessageRow: View {
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let message: ChatMessage
  let failureContext: String?
  let isLatestAssistant: Bool
  let onShowDetails: (ChatMessage) -> Void
  let onEditMessage: (ChatMessage) -> Void
  let onPreviewAttachment: (ChatAttachment, ChatMessage) -> Void
  let onSaveImages: ([MacResponseImageCandidate]) -> Void
  let onRequestRegenerate: () -> Void

  @Environment(\.macTranscriptFind) private var findContext
  @Environment(\.macAppTheme) private var theme
  @State private var isUnifiedSelectionMode = false

  private var isActiveFindMessage: Bool {
    findContext.isActive && findContext.activeMessageID == message.id
  }

  var body: some View {
    Group {
      if message.role == .user {
        MacUserMessageRowContainer(
          providers: providers,
          chats: chats,
          mcp: mcp,
          conversationID: conversationID,
          message: message,
          failureContext: failureContext,
          isLatestAssistant: isLatestAssistant,
          onShowDetails: onShowDetails,
          onEditMessage: onEditMessage,
          onPreviewAttachment: onPreviewAttachment,
          onRequestRegenerate: onRequestRegenerate
        )
      } else {
        VStack(alignment: .leading, spacing: 8) {
          MacRichMessageView(
            providers: providers,
            chats: chats,
            mcp: mcp,
            conversationID: conversationID,
            message: message,
            failureContext: failureContext,
            isLatestAssistant: isLatestAssistant,
            isUnifiedSelectionMode: isUnifiedSelectionMode,
            onExitUnifiedSelection: { isUnifiedSelectionMode = false },
            onShowDetails: onShowDetails,
            onEditMessage: onEditMessage,
            onPreviewAttachment: onPreviewAttachment,
            onRequestRegenerate: onRequestRegenerate
          )

          if message.status != .pending, message.status != .streaming {
            MacAssistantMessageActions(
              chats: chats,
              conversationID: conversationID,
              message: message,
              isLatestAssistant: isLatestAssistant,
              includeRetry: true,
              hideEmptyContentActions: message.status == .failed,
              isUnifiedSelectionMode: isUnifiedSelectionMode,
              onToggleUnifiedSelection: { isUnifiedSelectionMode.toggle() },
              onShowDetails: { onShowDetails(message) },
              onSaveImages: onSaveImages,
              onRequestRegenerate: onRequestRegenerate
            )
          }
        }
      }
    }
    .padding(.leading, isActiveFindMessage ? 10 : 0)
    .overlay(alignment: .leading) {
      if isActiveFindMessage {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(theme.accent)
          .frame(width: 3)
          .padding(.vertical, 2)
      }
    }
    .onChange(of: message.id) { _, _ in
      isUnifiedSelectionMode = false
    }
  }
}

@Observable
@MainActor
private final class MacRowHoverState {
  var isHovered = false
}

/// Isolates hover state to user messages so moving the cursor over messages
/// during scroll never re-evaluates message bodies.
private struct MacUserMessageRowContainer: View {
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let message: ChatMessage
  let failureContext: String?
  let isLatestAssistant: Bool
  let onShowDetails: (ChatMessage) -> Void
  let onEditMessage: (ChatMessage) -> Void
  let onPreviewAttachment: (ChatAttachment, ChatMessage) -> Void
  let onRequestRegenerate: () -> Void

  @State private var hoverState = MacRowHoverState()

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      MacRichMessageView(
        providers: providers,
        chats: chats,
        mcp: mcp,
        conversationID: conversationID,
        message: message,
        failureContext: failureContext,
        isLatestAssistant: isLatestAssistant,
        onShowDetails: onShowDetails,
        onEditMessage: onEditMessage,
        onPreviewAttachment: onPreviewAttachment,
        onRequestRegenerate: onRequestRegenerate
      )

      MacUserMessageActions(
        chats: chats,
        conversationID: conversationID,
        message: message,
        hoverState: hoverState,
        onEditMessage: { onEditMessage(message) },
        onShowDetails: { onShowDetails(message) }
      )
    }
    .onHover { hoverState.isHovered = $0 }
  }
}

@Observable
@MainActor
private final class MacTranscriptScrollState {
  @ObservationIgnored var isNearBottom = true
  @ObservationIgnored var followsLatest = true
  @ObservationIgnored var isUserDraggingTimeline = false
  var showJumpToLatest = false
}

private struct MacTranscriptJumpToLatestButton: View {
  let scrollState: MacTranscriptScrollState
  let bottomSpace: CGFloat
  let action: () -> Void

  var body: some View {
    if scrollState.showJumpToLatest {
      Button(action: action) {
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
}

private struct MacUserMessageActions: View {
  @Environment(\.macTranscriptIsActive) private var isTranscriptActive
  @Environment(\.macToastCenter) private var toastCenter
  @Environment(MacWorkspaceModel.self) private var workspace
  @Bindable var chats: MacChatSessionModel
  let conversationID: ConversationID?
  let message: ChatMessage
  let hoverState: MacRowHoverState
  let onEditMessage: () -> Void
  let onShowDetails: () -> Void

  @State private var copied = false
  @State private var copyResetTask: Task<Void, Never>?
  @State private var showingMorePopover = false

  private var hasCopyableContent: Bool {
    !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var canEdit: Bool {
    guard isTranscriptActive, let conversationID, hasCopyableContent else { return false }
    return !chats.isGenerating(conversationID)
  }

  private var attachments: [ChatAttachment] {
    message.attachments ?? []
  }

  private var isVisible: Bool {
    hoverState.isHovered || showingMorePopover || copied
  }

  var body: some View {
    HStack(spacing: 2) {
      Spacer(minLength: 0)

      if hasCopyableContent {
        Button {
          copyText(message.content)
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(copied ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted)
        }
        .buttonStyle(MacIconButtonStyle())
        .help(copied ? "Copied" : "Copy message")
        .accessibilityLabel(copied ? "Message copied" : "Copy message")
      }

      if hasCopyableContent {
        Button(action: onEditMessage) {
          Image(systemName: "pencil")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .buttonStyle(MacIconButtonStyle())
        .disabled(!canEdit)
        .help(canEdit ? "Edit & Resend" : "Wait for the current response to finish before editing")
        .accessibilityLabel("Edit and resend")
      }

      Button {
        showingMorePopover.toggle()
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(
            showingMorePopover ? MacDesignTokens.Colors.textPrimary : MacDesignTokens.Colors.textMuted
          )
      }
      .buttonStyle(MacIconButtonStyle())
      .popover(isPresented: $showingMorePopover, arrowEdge: .bottom) {
        morePopoverContent
          .presentationBackground(MacDesignTokens.Colors.surface)
      }
      .help("More actions")
      .accessibilityLabel("More actions")
    }
    .frame(height: MacDesignTokens.Control.iconButtonSize)
    .opacity(isVisible ? 1 : 0)
    .allowsHitTesting(isVisible)
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isVisible)
    .onDisappear {
      copyResetTask?.cancel()
      copyResetTask = nil
    }
  }

  private var morePopoverContent: some View {
    let hasTopActions = hasCopyableContent || (conversationID != nil && !attachments.isEmpty)
    return MacThemedActionPopoverContainer {
      if hasCopyableContent {
        MacThemedPopoverActionRow(
          title: "Export as Markdown",
          systemImage: "square.and.arrow.down"
        ) {
          showingMorePopover = false
          exportMessage()
        }

        ShareLink(item: message.content) {
          MacThemedPopoverActionRowLabel(
            title: "Share",
            systemImage: "square.and.arrow.up"
          )
        }
        .buttonStyle(.plain)
      }

      if let conversationID, !attachments.isEmpty {
        MacThemedPopoverActionRow(
          title: attachments.count == 1
            ? "Save Attachment to Library"
            : "Save Attachments to Library (\(attachments.count))",
          systemImage: "books.vertical"
        ) {
          showingMorePopover = false
          saveAttachmentsToLibrary(conversationID: conversationID)
        }
      }

      if hasTopActions {
        MacThemedPopoverDivider()
      }

      MacThemedPopoverActionRow(
        title: "Message Details",
        systemImage: "info.circle"
      ) {
        showingMorePopover = false
        onShowDetails()
      }
    }
  }

  private func copyText(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    copied = true
    copyResetTask?.cancel()
    copyResetTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled else { return }
      copied = false
    }
  }

  private func saveAttachmentsToLibrary(conversationID: ConversationID) {
    let items = attachments
    Task { @MainActor in
      var savedCount = 0
      var firstError: String?
      for attachment in items {
        let ok = await workspace.saveStoredAttachmentToLibrary(
          attachment,
          conversationID: conversationID,
          messageID: message.id
        )
        if ok {
          savedCount += 1
        } else if firstError == nil {
          firstError = workspace.consumeErrorMessage()
        }
      }
      if let firstError {
        chats.errorMessage = firstError
      } else if savedCount == 1 {
        toastCenter?.success(workspace.statusMessage ?? "Saved attachment to Library")
      } else if savedCount > 1 {
        toastCenter?.success("Saved \(savedCount) attachments to Library")
      }
    }
  }

  private func exportMessage() {
    let content = message.content
    let suggestedName = MacMessageExportSupport.filename(
      for: message,
      conversationTitle: chats.summary(conversationID)?.title
    )
    Task { @MainActor in
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.markdown, .plainText]
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      panel.nameFieldStringValue = suggestedName

      let response: NSApplication.ModalResponse
      if let window = NSApp.keyWindow {
        response = await panel.beginSheetModal(for: window)
      } else {
        response = panel.runModal()
      }
      guard response == .OK, let url = panel.url else { return }

      do {
        try content.write(to: url, atomically: true, encoding: .utf8)
        toastCenter?.success("Exported \"\(url.lastPathComponent)\"")
      } catch {
        MacAppAnalytics.reportError("message_export_failed", component: "chat")
        chats.errorMessage = error.localizedDescription
      }
    }
  }
}

private struct MacAssistantMessageActions: View {
  @Environment(\.macTranscriptIsActive) private var isTranscriptActive
  @Environment(\.macPreparedAnswers) private var preparedAnswers
  @Environment(\.macToastCenter) private var toastCenter
  @Environment(MacWorkspaceModel.self) private var workspace
  @Bindable var chats: MacChatSessionModel
  let conversationID: ConversationID?
  let message: ChatMessage
  let isLatestAssistant: Bool
  var includeRetry: Bool = true
  var hideEmptyContentActions: Bool = false
  var isUnifiedSelectionMode: Bool = false
  var onToggleUnifiedSelection: (() -> Void)? = nil
  let onShowDetails: () -> Void
  let onSaveImages: ([MacResponseImageCandidate]) -> Void
  let onRequestRegenerate: () -> Void

  @State private var copied = false
  @State private var copyResetTask: Task<Void, Never>?
  @State private var resolvedAnswer: MacPreparedAnswer?
  @State private var showingSourcesPopover = false
  @State private var showingMorePopover = false

  private struct PrepareRequest: Equatable {
    let cacheKey: MacAnswerCacheKey
    let isActive: Bool
  }

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

  private var hasCopyableContent: Bool {
    !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var hasReasoning: Bool {
    !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var attachments: [ChatAttachment] {
    message.attachments ?? []
  }

  private var showContentActions: Bool {
    !hideEmptyContentActions || hasCopyableContent
  }

  private var extractedSources: [MacAnswerSource] {
    guard showContentActions else { return [] }
    let textSources = hasCopyableContent ? (preparedAnswer?.sources ?? []) : []
    return MacCitationSupport.mergedSources(
      structuredCitations: message.citations,
      extractedSources: textSources
    )
  }

  private var hasStructuredBlocks: Bool {
    guard let blocks = preparedAnswer?.blocks else { return false }
    return blocks.contains { block in
      switch block {
      case .code, .table, .math, .callout, .details, .footnotes: true
      case .markdown: false
      }
    }
  }

  private var hasSavableImages: Bool {
    guard showContentActions, conversationID != nil, hasCopyableContent else { return false }
    return preparedAnswer?.hasSavableImages ?? false
  }

  var body: some View {
    let sources = extractedSources
    HStack(spacing: 2) {
      if showContentActions {
        Button {
          copyResponse()
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(copied ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted)
        }
        .buttonStyle(MacIconButtonStyle())
        .disabled(!hasCopyableContent)
        .help(copied ? "Copied" : "Copy response")
        .accessibilityLabel(copied ? "Response copied" : "Copy response")
      }

      if includeRetry && isLatestAssistant {
        if message.status == .failed {
          MacInlineRetryActionButton(
            isEnabled: canRetry,
            action: onRequestRegenerate
          )
        } else {
          Button(action: onRequestRegenerate) {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .buttonStyle(MacIconButtonStyle())
          .disabled(!canRetry)
          .help(canRetry ? "Retry response" : "Wait for generation to finish before retrying")
          .accessibilityLabel("Retry response")
        }
      }

      if !sources.isEmpty {
        MacSourcesPillButton(
          count: sources.count,
          isPresented: showingSourcesPopover
        ) {
          showingSourcesPopover.toggle()
        }
        .popover(isPresented: $showingSourcesPopover, arrowEdge: .bottom) {
          MacAnswerSourcesPopover(sources: sources) {
            showingSourcesPopover = false
          }
          .presentationBackground(MacDesignTokens.Colors.surface)
        }
        .padding(.horizontal, 4)
      }

      Button {
        showingMorePopover.toggle()
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(
            showingMorePopover ? MacDesignTokens.Colors.textPrimary : MacDesignTokens.Colors.textMuted
          )
      }
      .buttonStyle(MacIconButtonStyle())
      .popover(isPresented: $showingMorePopover, arrowEdge: .bottom) {
        morePopoverContent
          .presentationBackground(MacDesignTokens.Colors.surface)
      }
      .help("More actions")
      .accessibilityLabel("More actions")
    }
    // Pulls the leading glyph back over its centered frame's inset so the
    // first icon's visual edge lines up with the message text above.
    .padding(.leading, -6)
    .onDisappear {
      copyResetTask?.cancel()
      copyResetTask = nil
    }
    .task(id: PrepareRequest(cacheKey: contentCacheKey, isActive: isTranscriptActive)) {
      guard isTranscriptActive, showContentActions, hasCopyableContent else { return }
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

  private var morePopoverContent: some View {
    let hasSaveAttachments = conversationID != nil && !attachments.isEmpty
    let hasSaveResponse = conversationID != nil && showContentActions && hasCopyableContent
    let hasExportOrShare = showContentActions && hasCopyableContent
    let canToggleUnifiedSelection =
      onToggleUnifiedSelection != nil
      && showContentActions
      && hasCopyableContent
      && (hasStructuredBlocks || isUnifiedSelectionMode)
    let hasTopSection =
      hasReasoning || canToggleUnifiedSelection || hasSavableImages
      || hasSaveResponse || hasSaveAttachments || hasExportOrShare

    return MacThemedActionPopoverContainer {
      if canToggleUnifiedSelection, let onToggleUnifiedSelection {
        MacThemedPopoverActionRow(
          title: isUnifiedSelectionMode ? "Exit Unified Selection" : "Select Across Blocks",
          systemImage: "selection.pin.in.out"
        ) {
          showingMorePopover = false
          onToggleUnifiedSelection()
        }
      }

      if hasReasoning {
        MacThemedPopoverActionRow(
          title: "Copy Reasoning",
          systemImage: "brain"
        ) {
          showingMorePopover = false
          copyToPasteboard(message.reasoning)
          toastCenter?.success("Reasoning copied")
        }
      }

      if hasSavableImages {
        MacThemedPopoverActionRow(
          title: "Save Images",
          systemImage: "photo.on.rectangle.angled"
        ) {
          showingMorePopover = false
          let candidates = MacResponseImageScanner.imageCandidates(in: message.content)
          if !candidates.isEmpty {
            onSaveImages(candidates)
          }
        }
      }

      if hasSaveResponse, let conversationID {
        MacThemedPopoverActionRow(
          title: "Save Response to Library",
          systemImage: "books.vertical"
        ) {
          showingMorePopover = false
          saveResponseToLibrary(conversationID: conversationID)
        }
      }

      if hasSaveAttachments, let conversationID {
        MacThemedPopoverActionRow(
          title: attachments.count == 1
            ? "Save Attachment to Library"
            : "Save Attachments to Library (\(attachments.count))",
          systemImage: "paperclip"
        ) {
          showingMorePopover = false
          saveAttachmentsToLibrary(conversationID: conversationID)
        }
      }

      if hasExportOrShare {
        MacThemedPopoverActionRow(
          title: "Export as Markdown",
          systemImage: "square.and.arrow.down"
        ) {
          showingMorePopover = false
          exportMessage()
        }

        ShareLink(item: message.content) {
          MacThemedPopoverActionRowLabel(
            title: "Share",
            systemImage: "square.and.arrow.up"
          )
        }
        .buttonStyle(.plain)
      }

      if hasTopSection {
        MacThemedPopoverDivider()
      }

      MacThemedPopoverActionRow(
        title: "Message Details",
        systemImage: "info.circle"
      ) {
        showingMorePopover = false
        onShowDetails()
      }
    }
  }

  private func copyResponse() {
    copyToPasteboard(message.content)
    copied = true
    copyResetTask?.cancel()
    copyResetTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled else { return }
      copied = false
    }
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  private func saveResponseToLibrary(conversationID: ConversationID) {
    let content = message.content
    let messageID = message.id
    let createdAt = message.createdAt
    let title = chats.summary(conversationID)?.title
    Task { @MainActor in
      let ok = await workspace.saveResponseToLibrary(
        content,
        conversationID: conversationID,
        messageID: messageID,
        createdAt: createdAt,
        conversationTitle: title
      )
      if ok {
        toastCenter?.success(workspace.statusMessage ?? "Saved response to Library")
      } else if let error = workspace.consumeErrorMessage() {
        chats.errorMessage = error
      }
    }
  }

  private func saveAttachmentsToLibrary(conversationID: ConversationID) {
    let items = attachments
    Task { @MainActor in
      var savedCount = 0
      var firstError: String?
      for attachment in items {
        let ok = await workspace.saveStoredAttachmentToLibrary(
          attachment,
          conversationID: conversationID,
          messageID: message.id
        )
        if ok {
          savedCount += 1
        } else if firstError == nil {
          firstError = workspace.consumeErrorMessage()
        }
      }
      if let firstError {
        chats.errorMessage = firstError
      } else if savedCount == 1 {
        toastCenter?.success(workspace.statusMessage ?? "Saved attachment to Library")
      } else if savedCount > 1 {
        toastCenter?.success("Saved \(savedCount) attachments to Library")
      }
    }
  }

  private func exportMessage() {
    let content = message.content
    let suggestedName = MacMessageExportSupport.filename(
      for: message,
      conversationTitle: chats.summary(conversationID)?.title
    )
    Task { @MainActor in
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.markdown, .plainText]
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      panel.nameFieldStringValue = suggestedName

      let response: NSApplication.ModalResponse
      if let window = NSApp.keyWindow {
        response = await panel.beginSheetModal(for: window)
      } else {
        response = panel.runModal()
      }
      guard response == .OK, let url = panel.url else { return }

      do {
        try content.write(to: url, atomically: true, encoding: .utf8)
        toastCenter?.success("Exported \"\(url.lastPathComponent)\"")
      } catch {
        MacAppAnalytics.reportError("message_export_failed", component: "chat")
        chats.errorMessage = error.localizedDescription
      }
    }
  }
}

private struct MacInlineRetryActionButton: View {
  let isEnabled: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 11.5, weight: .semibold))
        Text("Retry")
          .font(.system(size: 12.5, weight: .medium))
      }
      .foregroundStyle(
        isEnabled ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted
      )
      .padding(.horizontal, 6)
      .frame(height: MacDesignTokens.Control.iconButtonSize)
      .background(
        Color.primary.opacity(isHovered && isEnabled ? MacDesignTokens.Control.hoverOpacity : 0),
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
      )
      .contentShape(
        RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
      )
      .opacity(isEnabled ? 1 : MacDesignTokens.Control.disabledOpacity)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .help(isEnabled ? "Retry response" : "Wait for generation to finish before retrying")
    .accessibilityLabel("Retry response")
  }
}

private struct MacSourcesPillButton: View {
  let count: Int
  var isPresented: Bool = false
  let action: () -> Void

  @State private var isHovered = false

  private var isActive: Bool {
    isHovered || isPresented
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: "globe")
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(isActive ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted)
        Text(count == 1 ? "1 Source" : "\(count) Sources")
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(isActive ? MacDesignTokens.Colors.textPrimary : MacDesignTokens.Colors.textMuted)
      }
      .padding(.horizontal, 8)
      .frame(height: 26)
      .background(
        isActive ? MacDesignTokens.Colors.selection.opacity(0.65) : MacDesignTokens.Colors.surface,
        in: Capsule()
      )
      .overlay {
        Capsule()
          .stroke(
            isActive
              ? MacDesignTokens.Colors.accent.opacity(0.45)
              : MacDesignTokens.Colors.separator.opacity(0.75),
            lineWidth: 0.65
          )
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isActive)
    .help("View \(count) cited \(count == 1 ? "source" : "sources")")
    .accessibilityLabel("Sources, \(count)")
  }
}

struct MacThemedActionPopoverContainer<Content: View>: View {
  var minWidth: CGFloat = 214
  var maxWidth: CGFloat? = nil
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      content()
    }
    .padding(6)
    .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: .leading)
    .background(MacDesignTokens.Colors.surface)
  }
}

struct MacThemedPopoverDivider: View {
  var body: some View {
    Rectangle()
      .fill(MacDesignTokens.Colors.separator.opacity(0.75))
      .frame(height: 1)
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
  }
}

struct MacThemedPopoverActionRow: View {
  let title: String
  let systemImage: String
  var isDestructive: Bool = false
  var iconTint: Color? = nil
  var showsDisclosureChevron: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      MacThemedPopoverActionRowLabel(
        title: title,
        systemImage: systemImage,
        isDestructive: isDestructive,
        iconTint: iconTint,
        showsDisclosureChevron: showsDisclosureChevron
      )
    }
    .buttonStyle(.plain)
  }
}

struct MacThemedPopoverActionRowLabel: View {
  let title: String
  let systemImage: String
  var isDestructive: Bool = false
  var iconTint: Color? = nil
  var showsDisclosureChevron: Bool = false

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(iconColor)
        .frame(width: 16, alignment: .center)

      Text(title)
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(textColor)
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 4)

      if showsDisclosureChevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    }
    .padding(.horizontal, 8)
    .frame(height: 28)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .contentShape(Rectangle())
    .opacity(isEnabled ? 1 : MacDesignTokens.Control.disabledOpacity)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
  }

  private var iconColor: Color {
    if isDestructive { return .red }
    if let iconTint { return iconTint }
    return isHovered && isEnabled ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted
  }

  private var textColor: Color {
    if isDestructive { return .red }
    return MacDesignTokens.Colors.textPrimary
  }

  private var backgroundColor: Color {
    guard isHovered && isEnabled else { return .clear }
    return isDestructive ? Color.red.opacity(0.10) : MacDesignTokens.Colors.selection.opacity(0.75)
  }
}

private struct MacTranscriptActivityKey: EnvironmentKey {
  static let defaultValue = true
}

private struct MacPreparedAnswersKey: EnvironmentKey {
  static let defaultValue: [MacAnswerCacheKey: MacPreparedAnswer] = [:]
}

private struct MacTranscriptContentWidthKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
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

  var macTranscriptContentWidth: CGFloat {
    get { self[MacTranscriptContentWidthKey.self] }
    set { self[MacTranscriptContentWidthKey.self] = newValue }
  }
}

