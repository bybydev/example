import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// Explicit push destinations for the root navigation stack. Only flows that
/// must layer *on top of* the current main screen live here; everything else
/// keeps swapping the root.
enum AppRoute: Hashable {
  case project(ProjectID)
  case newChatSetup(ProjectID)
  /// A live conversation shown inside the stack. "New chat" inside a project
  /// creates the conversation eagerly, so this is the only chat shape there
  /// is — an empty one is just a chat with no messages yet.
  case chat(ConversationID)

  var chatID: ConversationID? {
    if case .chat(let id) = self { return id }
    return nil
  }
}

struct AppRootView: View {
  private struct RootError: Equatable {
    enum Source: Equatable {
      case chat, provider, mcp
      case project(ProjectManagementModel.OperationError)
    }
    let source: Source
    let message: String
  }

  private struct ChatPresentationID: Hashable {
    let conversationID: ConversationID
    let messageID: ChatMessageID?
  }

  @Bindable var model: AppModel
  let purchases: BYOKPurchaseStore
  let restartApp: () -> Void

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("byokchat.onboarding.completed.v1") private var hasCompletedOnboarding = false
  @State private var bootstrap = AppBootstrapController()
  /// Pushed screens layered above the main content (project details, pushed
  /// project chats).
  @State private var navigationPath: [AppRoute] = []
  @State private var isCreatingNewChat = false
  @State private var pendingNewChatProjectID: ProjectID?
  @State private var newChatRequestRevision: UInt = 0
  @State private var newChatRequestPath: [AppRoute] = []
  @State private var selectedConversationID: ConversationID?
  @State private var initialScrollMessageID: ChatMessageID?
  @State private var isSidebarPresented = false
  @State private var isSettingsPresented = false
  /// The visible chat was opened from a project's chat list, so it shows a
  /// back chevron instead of the sidebar hamburger.
  @State private var openedChatFromProject = false
  /// When set (and no chat is selected), the root shows that project's screen.
  @State private var activeProjectViewID: ProjectID?
  /// Sidebar menu section currently replacing the main screen. Mutually
  /// exclusive with the states above.
  @State private var activeScreen: ChatSidebarView.SidebarDestination?
  @State private var presentedRootError: RootError?

  var body: some View {
    Group {
      switch bootstrap.state {
      case .loading:
        AppStartupLoadingView()
      case .ready:
        readyAppContent
      case .failed(let failure):
        AppStartupFailureView(failure: failure, restartApp: restartApp)
      }
    }
    .task {
      await bootstrap.start(model: model)
    }
    .task {
      await purchases.prepare()
      model.themeManager.synchronizeProAccess(purchases.hasPro)
    }
    .onChange(of: purchases.manager.hasPro) { _, hasPro in
      model.themeManager.synchronizeProAccess(hasPro)
    }
  }

  private var readyAppContent: some View {
    let alertError = presentedRootError
    return ZStack {
      theme.backgroundColor
        .ignoresSafeArea()

      GeometryReader { geometry in
        let drawerWidth = min(geometry.size.width * 0.80, 390)

        ZStack(alignment: .leading) {
          mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: isSidebarPresented ? drawerWidth : 0)
            .allowsHitTesting(!isSidebarPresented)
            .simultaneousGesture(openSidebarGesture, including: .all)
            .overlay {
              if isSidebarPresented {
                Color.black.opacity(0.12)
                  .ignoresSafeArea()
                  .onTapGesture { closeSidebar() }
              }
            }

          if isSidebarPresented {
            ChatSidebarView(
              chats: model.chats,
              providers: model.providers,
              projects: model.projects,
              mcp: model.mcp,
              purchases: purchases,
              selectedConversationID: selectedConversationID,
              newChat: startNewChat(in:),
              selectConversation: selectConversation,
              selectProjectConversation: selectProjectConversation,
              selectSearchResult: selectSearchResult,
              openDestination: openMainScreen,
              openSettings: openSettings,
              close: closeSidebar
            )
            .frame(width: drawerWidth)
            .frame(maxHeight: .infinity)
            .transition(.move(edge: .leading))
            .zIndex(2)
          }
        }
        .animation(.snappy(duration: 0.28), value: isSidebarPresented)
      }
    }
    .onChange(of: model.chats.conversations.map(\.id)) { _, ids in
      guard let selectedConversationID, !ids.contains(selectedConversationID) else { return }
      self.selectedConversationID = nil
      initialScrollMessageID = nil
    }
    // A pushed project chat that never received a message is discarded when
    // it leaves the stack, so backing out of "New Chat" leaves no clutter.
    .onChange(of: navigationPath) { oldValue, newValue in
      if isCreatingNewChat && newValue != newChatRequestPath {
        invalidateNewChatRequest()
      }
      let oldChats = oldValue.compactMap(\.chatID)
      let kept = Set(newValue.compactMap(\.chatID))
      for id in oldChats where !kept.contains(id) {
        discardIfEmpty(id)
      }
    }
    .onChange(of: model.projects.projects.map(\.id)) { _, ids in
      if let activeProjectViewID, !ids.contains(activeProjectViewID) {
        self.activeProjectViewID = nil
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active {
        Task { await model.chats.persistActiveMessages() }
      } else {
        model.chats.retryAbandonedNewChats()
      }
    }
    .sheet(isPresented: $isSettingsPresented) {
      SettingsView(model: model, purchases: purchases)
        .appFoundationTheme(model.themeManager)
        .presentationDragIndicator(.visible)
    }
    .fullScreenCover(
      isPresented: Binding(
        get: { !hasCompletedOnboarding },
        set: { presented in
          if !presented { hasCompletedOnboarding = true }
        }
      )
    ) {
      BYOKOnboardingView {
        hasCompletedOnboarding = true
      }
      .appFoundationTheme(model.themeManager)
      .interactiveDismissDisabled()
    }
    .overlay(alignment: .top) {
      if isCreatingNewChat || model.providers.isBusy || model.chats.isBusy || model.projects.isBusy || model.mcp.isBusy
        || model.dataPortability.isBusy
      {
        ProgressView()
          .padding(10)
          .background(.regularMaterial, in: Capsule())
          .padding(.top, 8)
      }
    }
    .onChange(of: rootErrorCandidate, initial: true) { _, _ in synchronizeRootErrorPresentation() }
    .onChange(of: model.projects.errorForPresenter()) { _, _ in synchronizeRootErrorPresentation() }
    .onChange(of: model.mcp.shouldPresentError()) { _, _ in synchronizeRootErrorPresentation() }
    .alert(
      "BYOKchat",
      isPresented: Binding(
        get: { presentedRootError != nil },
        set: { presented in
          if !presented, let error = alertError {
            acknowledgeRootError(error)
          }
        }
      ),
      presenting: alertError
    ) { error in
      Button("OK") { acknowledgeRootError(error) }
    } message: { error in
      Text(error.message)
    }
  }

  private var rootErrorCandidate: RootError? {
    if let message = model.chats.errorMessage { return RootError(source: .chat, message: message) }
    if let error = model.projects.errorForPresenter() {
      return RootError(source: .project(error), message: error.message)
    }
    if let message = model.providers.errorMessage { return RootError(source: .provider, message: message) }
    if model.mcp.shouldPresentError(), let message = model.mcp.errorMessage {
      return RootError(source: .mcp, message: message)
    }
    return nil
  }

  private func synchronizeRootErrorPresentation() {
    // Ownership can change even while a higher-priority error is pending.
    // A local surface takes over without acknowledging the Project/MCP error.
    if let displayed = presentedRootError {
      switch displayed.source {
      case .project:
        if model.projects.errorForPresenter() == nil { presentedRootError = nil }
      case .mcp:
        if !model.mcp.shouldPresentError() { presentedRootError = nil }
      case .chat, .provider:
        break
      }
    }
    if presentedRootError == nil { presentedRootError = rootErrorCandidate }
  }

  private func acknowledgeRootError(_ error: RootError) {
    guard presentedRootError == error else { return }
    switch error.source {
    case .chat:
      if model.chats.errorMessage == error.message { model.chats.errorMessage = nil }
    case .provider:
      if model.providers.errorMessage == error.message { model.providers.errorMessage = nil }
    case .mcp:
      if model.mcp.shouldPresentError(), model.mcp.errorMessage == error.message { model.mcp.errorMessage = nil }
    case .project(let projectError):
      model.projects.acknowledgeError(projectError)
    }
    presentedRootError = nil
    Task { @MainActor in
      await Task.yield()
      synchronizeRootErrorPresentation()
    }
  }

  @ViewBuilder
  private var mainContent: some View {
    NavigationStack(path: $navigationPath) {
      Group {
        if let selectedConversationID,
          model.chats.hasConversation(selectedConversationID)
        {
          ChatView(
            subject: .existing(selectedConversationID),
            initialScrollMessageID: initialScrollMessageID,
            enteredFromProject: openedChatFromProject,
            chats: model.chats,
            providers: model.providers,
            projects: model.projects,
            mcp: model.mcp,
            library: model.library,
            openSidebar: openSidebar,
            startNewChat: {
              startNewChat(in: model.projects.projectID(for: selectedConversationID))
            },
            openProject: exitToProjectView
          )
          .id(
            ChatPresentationID(
              conversationID: selectedConversationID,
              messageID: initialScrollMessageID
            )
          )
          .background {
            theme.backgroundColor
              .ignoresSafeArea()
          }
        } else if let activeProjectViewID {
          ProjectDetailView(
            projectID: activeProjectViewID,
            chats: model.chats,
            projects: model.projects,
            providers: model.providers,
            mcp: model.mcp,
            newChat: startNewChat(in:),
            openChat: selectProjectConversation,
            homeExit: { startNewChat(in: nil) }
          )
        } else if let activeScreen {
          switch activeScreen {
          case .providers:
            ProvidersView(model: model.providers, openSidebar: openSidebar)
          case .library:
            LibraryView(
              library: model.library,
              chats: model.chats,
              openSidebar: openSidebar,
              openSourceChat: openLibrarySourceChat
            )
          case .projects:
            SidebarProjectsView(
              chats: model.chats,
              projects: model.projects,
              providers: model.providers,
              mcp: model.mcp,
              newChat: startNewChat(in:),
              openChat: selectProjectConversation,
              openSidebar: openSidebar
            )
          case .plugins:
            MCPServerListView(model: model.mcp, openSidebar: openSidebar)
          case .usage:
            UsageDashboardView(
              conversations: model.chats.conversations,
              openSidebar: openSidebar
            )
          }
        } else {
          // Connection setup only. A ready target opens a real conversation.
          ChatView(
            subject: .fresh(projectID: nil),
            chats: model.chats,
            providers: model.providers,
            projects: model.projects,
            mcp: model.mcp,
            library: model.library,
            onReadyForConversation: { startNewChat(in: nil) },
            openSidebar: openSidebar
          )
        }
      }
      // Project rows in the main-screen projects list push their detail onto
      // the root stack; the detail's new-chat composer pushes on top of it so
      // back returns to the project instead of swapping the main screen.
      .navigationDestination(for: AppRoute.self) { route in
        switch route {
        case .project(let projectID):
          ProjectDetailView(
            projectID: projectID,
            chats: model.chats,
            projects: model.projects,
            providers: model.providers,
            mcp: model.mcp,
            newChat: startNewChat(in:),
            openChat: selectProjectConversation,
            newChatInStack: { startNewChat(in: projectID) }
          )
        case .newChatSetup(let projectID):
          ChatView(
            subject: .fresh(projectID: projectID),
            chats: model.chats,
            providers: model.providers,
            projects: model.projects,
            mcp: model.mcp,
            library: model.library,
            pushedFromStack: true,
            onReadyForConversation: { startNewChat(in: projectID) }
          )
        case .chat(let conversationID):
          ChatView(
            subject: .existing(conversationID),
            chats: model.chats,
            providers: model.providers,
            projects: model.projects,
            mcp: model.mcp,
            library: model.library,
            pushedFromStack: true,
            openSidebar: {},
            startNewChat: {
              if let projectID = model.projects.projectID(for: conversationID) {
                startNewChat(in: projectID)
              }
            },
            openProject: {}
          )
        }
      }
    }
    .background {
      theme.backgroundColor
        .ignoresSafeArea()
    }
  }

  /// Swipes only open the sidebar when they begin this close to the leading
  /// edge. The gesture runs simultaneously with content gestures, so without a
  /// start-location gate a rightward drag anywhere — like scrolling a wide
  /// markdown table horizontally — would yank the drawer open mid-scroll.
  private static let sidebarSwipeEdgeZone: CGFloat = 28

  private var openSidebarGesture: some Gesture {
    DragGesture(minimumDistance: 16, coordinateSpace: .local)
      .onEnded { value in
        let horizontalTravel = max(value.translation.width, value.predictedEndTranslation.width)
        let verticalTravel = abs(value.translation.height)

        guard value.startLocation.x < Self.sidebarSwipeEdgeZone else { return }

        guard !isSidebarPresented,
          horizontalTravel > 90,
          value.translation.width > 0,
          abs(value.translation.width) > verticalTravel * 1.35
        else { return }

        openSidebar()
      }
  }

  private func openSidebar() {
    withAnimation { isSidebarPresented = true }
  }

  private func closeSidebar() {
    withAnimation { isSidebarPresented = false }
  }

  private var visibleConversationID: ConversationID? {
    if let last = navigationPath.last { return last.chatID }
    return selectedConversationID
  }

  private func invalidateNewChatRequest() {
    newChatRequestRevision &+= 1
    isCreatingNewChat = false
  }

  private func discardIfEmpty(_ id: ConversationID?) {
    model.chats.abandonNewChat(id)
  }

  private func startNewChat(in projectID: ProjectID?) {
    closeSidebar()
    if isCreatingNewChat && pendingNewChatProjectID == projectID { return }
    if let id = visibleConversationID,
      model.chats.hasConversation(id),
      !model.chats.historyConversations.contains(where: { $0.id == id }),
      !model.chats.isGenerating(id), model.projects.projectID(for: id) == projectID
    {
      return // Repeated New Chat preserves the active unsent session and edits.
    }

    invalidateNewChatRequest()
    let revision = newChatRequestRevision
    discardIfEmpty(visibleConversationID)
    if projectID == nil {
      discardIfEmpty(selectedConversationID)
      navigationPath = []
      selectedConversationID = nil
      initialScrollMessageID = nil
      activeProjectViewID = nil
      openedChatFromProject = false
      activeScreen = nil
    }
    pendingNewChatProjectID = projectID
    newChatRequestPath = navigationPath
    isCreatingNewChat = true

    Task { @MainActor in
      let id = await model.chats.newChat(projectID: projectID)
      guard revision == newChatRequestRevision else {
        // A newer same-scope request may share this exact creation task.
        if !(isCreatingNewChat && pendingNewChatProjectID == projectID),
          id != visibleConversationID {
          model.chats.abandonNewChat(id)
        }
        return
      }
      await model.projects.reloadFromStorage()
      await model.mcp.reloadFromStorage()
      guard revision == newChatRequestRevision else {
        if !(isCreatingNewChat && pendingNewChatProjectID == projectID),
          id != visibleConversationID {
          model.chats.abandonNewChat(id)
        }
        return
      }
      isCreatingNewChat = false
      guard let id else {
        if let projectID, navigationPath.last != .newChatSetup(projectID) {
          navigationPath.append(.newChatSetup(projectID))
        }
        return
      }
      if projectID != nil {
        if navigationPath.last?.chatID == id { return }
        // Starting after a sent project chat replaces that top chat, preserving
        // the project's Back destination rather than stacking another chat.
        if navigationPath.last?.chatID != nil {
          navigationPath.removeLast()
        } else if case .newChatSetup? = navigationPath.last {
          navigationPath.removeLast()
        }
        navigationPath.append(.chat(id))
      } else {
        selectedConversationID = id
      }
    }
  }

  /// Sidebar menu sections replace the main screen; whatever was showing
  /// yields.
  private func openMainScreen(_ screen: ChatSidebarView.SidebarDestination) {
    invalidateNewChatRequest()
    navigationPath = []
    discardIfEmpty(selectedConversationID)
    selectedConversationID = nil
    initialScrollMessageID = nil
    activeProjectViewID = nil
    openedChatFromProject = false
    activeScreen = screen
    closeSidebar()
  }

  /// Back chevron on a project chat: swap the chat for its project's screen.
  private func exitToProjectView() {
    invalidateNewChatRequest()
    guard let conversationID = selectedConversationID else { return }
    activeProjectViewID = model.projects.projectID(for: conversationID)
    openedChatFromProject = false
    discardIfEmpty(conversationID)
    selectedConversationID = nil
    initialScrollMessageID = nil
  }

  /// Opening a chat from a project's screen keeps the project context so the
  /// chat offers a back chevron back into that project.
  private func selectProjectConversation(_ id: ConversationID) {
    selectConversation(id)
    openedChatFromProject = true
  }

  private func selectConversation(_ id: ConversationID) {
    invalidateNewChatRequest()
    navigationPath = []
    discardIfEmpty(selectedConversationID == id ? nil : selectedConversationID)
    selectedConversationID = id
    initialScrollMessageID = nil
    activeProjectViewID = nil
    openedChatFromProject = false
    activeScreen = nil
    closeSidebar()
  }

  private func selectSearchResult(_ result: ConversationSearchResult) {
    invalidateNewChatRequest()
    navigationPath = []
    discardIfEmpty(selectedConversationID == result.conversationID ? nil : selectedConversationID)
    selectedConversationID = result.conversationID
    initialScrollMessageID = result.messageID
    activeProjectViewID = nil
    openedChatFromProject = false
    activeScreen = nil
    closeSidebar()
  }

  /// A library entry saved from a chat jumps back to its source message.
  private func openLibrarySourceChat(_ entry: LibraryEntry) {
    guard case let .chat(conversationID, messageID) = entry.source else { return }
    selectSearchResult(
      ConversationSearchResult(
        conversationID: conversationID,
        messageID: messageID,
        role: .user,
        title: model.chats.conversation(conversationID)?.title ?? "Chat",
        snippet: "Saved: \(entry.filename)",
        updatedAt: entry.createdAt
      )
    )
  }

  private func openSettings() {
    closeSidebar()
    isSettingsPresented = true
  }
}
