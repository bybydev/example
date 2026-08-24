import AppFoundation
import BYOKchatProviderCore
import SwiftUI

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
  @State private var selectedConversationID: ConversationID?
  @State private var newChatProjectID: ProjectID?
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
    .onChange(of: model.projects.projects.map(\.id)) { _, ids in
      if let newChatProjectID, !ids.contains(newChatProjectID) {
        self.newChatProjectID = nil
      }
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
    NavigationStack {
      Group {
        if let selectedConversationID,
          model.chats.conversation(selectedConversationID) != nil
        {
          ChatView(
            conversationID: selectedConversationID,
            initialScrollMessageID: initialScrollMessageID,
            enteredFromProject: openedChatFromProject,
            chats: model.chats,
            providers: model.providers,
            projects: model.projects,
            mcp: model.mcp,
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
            SidebarLibraryView(
              conversations: model.chats.conversations,
              openSidebar: openSidebar
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
            EmptyView()
          }
        } else {
          NewChatView(
            chats: model.chats,
            providers: model.providers,
            projects: model.projects,
            mcp: model.mcp,
            projectID: newChatProjectID,
            openSidebar: openSidebar,
            openSettings: openSettings,
            selectConversation: selectConversation
          )
        }
      }
      // Project rows in the main-screen projects list push their detail onto
      // the root stack. Opening a chat from there keeps the project context.
      .navigationDestination(for: ProjectID.self) { projectID in
        ProjectDetailView(
          projectID: projectID,
          chats: model.chats,
          projects: model.projects,
          providers: model.providers,
          mcp: model.mcp,
          newChat: startNewChat(in:),
          openChat: selectProjectConversation
        )
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

  private func startNewChat(in projectID: ProjectID?) {
    selectedConversationID = nil
    newChatProjectID = projectID
    initialScrollMessageID = nil
    activeProjectViewID = nil
    openedChatFromProject = false
    activeScreen = nil
    closeSidebar()
  }

  /// Sidebar menu sections (library/projects/plugins) replace the main
  /// screen; whatever was showing yields.
  private func openMainScreen(_ screen: ChatSidebarView.SidebarDestination) {
    selectedConversationID = nil
    newChatProjectID = nil
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
    selectedConversationID = id
    newChatProjectID = nil
    initialScrollMessageID = nil
    activeProjectViewID = nil
    openedChatFromProject = false
    activeScreen = nil
    closeSidebar()
  }

  private func selectSearchResult(_ result: ConversationSearchResult) {
    selectedConversationID = result.conversationID
    newChatProjectID = nil
    initialScrollMessageID = result.messageID
    activeProjectViewID = nil
    openedChatFromProject = false
    activeScreen = nil
    closeSidebar()
  }

  private func openSettings() {
    closeSidebar()
    isSettingsPresented = true
  }
}
