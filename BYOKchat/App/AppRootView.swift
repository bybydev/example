import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// Explicit push destinations for the root navigation stack. Only flows that
/// must layer *on top of* the current main screen live here; everything else
/// keeps swapping the root.
enum AppRoute: Hashable {
  case project(ProjectID)
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
  /// Guards double-taps on a project's New Chat from stacking two empties.
  @State private var isCreatingStackChat = false
  @State private var selectedConversationID: ConversationID?
  @State private var initialScrollMessageID: ChatMessageID?
  @State private var isSidebarPresented = false
  @State private var isSettingsPresented = false
  /// The visible chat was opened from a project's chat list, so it shows a
  /// back chevron instead of the sidebar hamburger.
  @State private var openedChatFromProject = false
  /// When set (and no chat is selected), the root shows that project's screen.
  @State private var activeProjectViewID: ProjectID?
  /// Sidebar menu section currently replacing the main screen
  /// (library/projects/plugins). Mutually exclusive with the states above.
  @State private var activeScreen: ChatSidebarView.SidebarDestination?

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
    ZStack {
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
      if phase == .active {
        Task { await model.projectSync.syncIfEnabled() }
      } else {
        Task { await model.chats.persistActiveMessages() }
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
      if model.providers.isBusy || model.chats.isBusy || model.projects.isBusy || model.mcp.isBusy
        || model.dataPortability.isBusy
      {
        ProgressView()
          .padding(10)
          .background(.regularMaterial, in: Capsule())
          .padding(.top, 8)
      }
    }
    .alert(
      "BYOKchat",
      isPresented: Binding(
        get: {
          model.providers.errorMessage != nil
            || model.chats.errorMessage != nil
            || model.projects.errorMessage != nil
            || model.mcp.errorMessage != nil
            || model.projectSync.errorMessage != nil
        },
        set: { presented in
          if !presented {
            model.providers.errorMessage = nil
            model.chats.errorMessage = nil
            model.projects.errorMessage = nil
            model.mcp.errorMessage = nil
            model.projectSync.errorMessage = nil
          }
        }
      )
    ) {
      Button("OK") {
        model.providers.errorMessage = nil
        model.chats.errorMessage = nil
        model.projects.errorMessage = nil
        model.mcp.errorMessage = nil
        model.projectSync.errorMessage = nil
      }
    } message: {
      Text(
        model.chats.errorMessage
          ?? model.projects.errorMessage
          ?? model.providers.errorMessage
          ?? model.mcp.errorMessage
          ?? model.projectSync.errorMessage
          ?? "Unknown error"
      )
    }
  }

  @ViewBuilder
  private var mainContent: some View {
    NavigationStack(path: $navigationPath) {
      Group {
        if let selectedConversationID,
          model.chats.conversation(selectedConversationID) != nil
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
          // Home: fresh pre-creation chat surface.
          ChatView(
            subject: .fresh(projectID: nil),
            chats: model.chats,
            providers: model.providers,
            projects: model.projects,
            mcp: model.mcp,
            library: model.library,
            onFreshConversationCreated: selectConversation,
            openSidebar: openSidebar,
            openSettings: openSettings
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
            newChatInStack: { pushEmptyProjectChat(projectID) }
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
                pushEmptyProjectChat(projectID)
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

  /// "New chat" inside a project is just a chat with no messages yet: create
  /// the conversation with the project's defaults and push a real ChatView.
  private func pushEmptyProjectChat(_ projectID: ProjectID) {
    guard !isCreatingStackChat else { return }
    isCreatingStackChat = true
    Task { @MainActor in
      defer { isCreatingStackChat = false }
      guard
        let id = await model.chats.createConversation(projectID: projectID)
      else { return }
      await model.projects.reloadFromStorage()
      await model.mcp.reloadFromStorage()
      navigationPath.append(.chat(id))
    }
  }

  /// A zero-message conversation stops existing the moment it stops being the
  /// visible chat — drafts included, per the strict-cleanup rule.
  private func discardIfEmpty(_ id: ConversationID?) {
    guard let id,
      let conversation = model.chats.conversation(id),
      conversation.messages.isEmpty,
      !model.chats.isGenerating(id)
    else { return }
    Task { await model.chats.deleteConversation(id) }
  }

  private func startNewChat(in projectID: ProjectID?) {
    if let projectID {
      // Every project-scoped new chat is a real, eagerly created conversation.
      closeSidebar()
      pushEmptyProjectChat(projectID)
      return
    }
    navigationPath = []
    discardIfEmpty(selectedConversationID)
    selectedConversationID = nil
    initialScrollMessageID = nil
    activeProjectViewID = nil
    openedChatFromProject = false
    activeScreen = nil
    closeSidebar()
  }

  /// Sidebar menu sections (library/projects/plugins) replace the main
  /// screen; whatever was showing yields.
  private func openMainScreen(_ screen: ChatSidebarView.SidebarDestination) {
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
