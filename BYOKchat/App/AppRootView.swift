import AppFoundation
import BYOKchatProviderCore
import SwiftUI
import UIKit

/// Explicit push destinations for the root navigation stack. Only flows that
/// must layer *on top of* the current main screen live here; everything else
/// keeps swapping the root.
enum AppRoute: Hashable {
  case project(ProjectID)
  case newChatSetup(ProjectID)
  /// A live conversation shown inside the stack. "New chat" inside a project
  /// creates the conversation eagerly, so this is the only chat shape there
  /// is — an empty one is just a chat with no messages yet.
  case chat(ConversationID, messageID: ChatMessageID? = nil)

  var chatID: ConversationID? {
    if case .chat(let id, _) = self { return id }
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

  private struct PendingSidebarChatSelection: Equatable {
    let conversationID: ConversationID
    let initialScrollMessageID: ChatMessageID?
    let revision: UInt
  }

  @Bindable var model: AppModel
  let purchases: BYOKPurchaseStore
  let restartApp: () -> Void

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.displayScale) private var displayScale
  @AppStorage("byokchat.onboarding.completed.v1") private var hasCompletedOnboarding = false
  @State private var bootstrap = AppBootstrapController()
  @State private var toastCenter = BYOKToastCenter()
  /// Pushed screens layered above the main content (project details, pushed
  /// project chats).
  @State private var navigationPath: [AppRoute] = []
  @State private var isCreatingNewChat = false
  @State private var pendingNewChatProjectID: ProjectID?
  @State private var newChatRequestRevision: UInt = 0
  @State private var newChatRequestPath: [AppRoute] = []
  @State private var selectedConversationID: ConversationID?
  @State private var initialScrollMessageID: ChatMessageID?
  @State private var pendingSidebarChat: PendingSidebarChatSelection?
  @State private var sidebarChatSelectionRevision: UInt = 0
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
    .byokToastOverlay(toastCenter)
    .task {
      await bootstrap.start(model: model) { initialConversationID in
        selectedConversationID = initialConversationID
      }
    }
    .task {
      // Also bind a newly recreated AppModel before StoreKit preparation.
      // Binding is idempotent; unresolved checks must not be treated as Free.
      model.themeManager.bind(to: purchases.manager)
      await purchases.prepare()
    }
  }

  private var readyAppContent: some View {
    let alertError = presentedRootError
    return ZStack {
      theme.backgroundColor
        .ignoresSafeArea()

      GeometryReader { geometry in
        let drawerWidth = min(geometry.size.width * 0.80, 390)
        let scrimOpacity = theme.appearance.preferredColorScheme == .light ? 0.18 : 0.34

        ZStack(alignment: .leading) {
          mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: isSidebarPresented ? drawerWidth : 0)
            .allowsHitTesting(!isSidebarPresented)
            .accessibilityHidden(isSidebarPresented)

          if isSidebarPresented {
            Color.black.opacity(scrimOpacity)
              .ignoresSafeArea()
              .contentShape(Rectangle())
              .onTapGesture { closeSidebar() }
              .accessibilityElement()
              .accessibilityLabel("Close sidebar")
              .accessibilityAddTraits(.isButton)
              .accessibilityAction { closeSidebar() }
              .transition(.opacity)
              .zIndex(1)

            ChatSidebarView(
              chats: model.chats,
              projects: model.projects,
              mcp: model.mcp,
              purchases: purchases,
              selectedConversationID: pendingSidebarChat?.conversationID ?? selectedConversationID,
              activeDestination: activeScreen,
              newChat: startNewChat(in:),
              selectConversation: selectConversation,
              selectSearchResult: selectSearchResult,
              openDestination: openMainScreen,
              openSettings: openSettings,
              close: closeSidebar
            )
            .frame(width: drawerWidth)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) {
              Rectangle()
                .fill(theme.borderColor)
                .frame(width: 0.5)
                .ignoresSafeArea()
            }
            .shadow(color: theme.appearance.shadow.color, radius: 14, x: 4, y: 0)
            .accessibilitySortPriority(1)
            .transition(.move(edge: .leading))
            .zIndex(2)
          }
        }
        .simultaneousGesture(closeSidebarGesture, including: .all)
        .animation(Self.sidebarAnimation, value: isSidebarPresented)
      }
    }
    .onChange(of: model.chats.conversations.map(\.id), initial: true) { _, ids in
      let validIDs = Set(ids)
      model.preferences.prunePinnedConversations(keeping: validIDs)
      if navigationPath.contains(where: { destination in
        guard let chatID = destination.chatID else { return false }
        return !validIDs.contains(chatID)
      }) {
        navigationPath.removeAll { destination in
          guard let chatID = destination.chatID else { return false }
          return !validIDs.contains(chatID)
        }
      }
      if let pendingSidebarChat, !validIDs.contains(pendingSidebarChat.conversationID) {
        cancelPendingSidebarChat()
      }
      guard let selectedConversationID, !validIDs.contains(selectedConversationID) else { return }
      self.selectedConversationID = nil
      initialScrollMessageID = nil
      openedChatFromProject = false
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
      handleProjectListChange(ids)
    }
    .onChange(of: model.projects.statusMessage) { _, message in
      handleProjectStatusMessage(message)
    }
    .onChange(of: model.mcp.statusMessage) { _, message in
      handleMCPStatusMessage(message)
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
        guard !hasCompletedOnboarding else { return }
        hasCompletedOnboarding = true
        BYOKAppAnalytics.track(.onboardingCompleted)
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
            openProject: exitToProjectView,
            onDeleted: handleRootConversationDeleted
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
        } else if let pendingSidebarChat {
          sidebarChatTransitionShell(for: pendingSidebarChat.conversationID)
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
              openSidebar: openSidebar
            )
          case .plugins:
            MCPServerListView(model: model.mcp, openSidebar: openSidebar)
          case .usage:
            UsageDashboardView(
              conversations: model.chats.conversations,
              openSidebar: openSidebar
            )
          case .allChats:
            ChatListView(
              chats: model.chats,
              providers: model.providers,
              projects: model.projects,
              mcp: model.mcp,
              openSidebar: openSidebar,
              startNewChat: { startNewChat(in: nil) }
            )
          }
        } else if isCreatingNewChat {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Opening chat")
        } else {
          // Connection setup only. A ready target opens a real conversation.
          ChatView(
            subject: .fresh(projectID: nil),
            chats: model.chats,
            providers: model.providers,
            projects: model.projects,
            mcp: model.mcp,
            library: model.library,
            onReadyForConversation: {
              startNewChat(in: nil, closeDrawer: !isSidebarPresented)
            },
            openSidebar: openSidebar
          )
        }
      }
      // Keep the drawer gesture on top-level content; pushed screens own Back.
      .simultaneousGesture(openSidebarGesture, including: .all)
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
        case .chat(let conversationID, let messageID):
          ChatView(
            subject: .existing(conversationID),
            initialScrollMessageID: messageID,
            chats: model.chats,
            providers: model.providers,
            projects: model.projects,
            mcp: model.mcp,
            library: model.library,
            pushedFromStack: true,
            openSidebar: {},
            startNewChat: {
              startNewChat(in: model.projects.projectID(for: conversationID))
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

  private static let sidebarAnimation: Animation = .snappy(duration: 0.28)

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
          navigationPath.isEmpty,
          activeProjectViewID == nil,
          !openedChatFromProject,
          horizontalTravel > 90,
          value.translation.width > 0,
          abs(value.translation.width) > verticalTravel * 1.35
        else { return }

        openSidebar()
      }
  }

  private var closeSidebarGesture: some Gesture {
    DragGesture(minimumDistance: 20, coordinateSpace: .local)
      .onEnded { value in
        guard isSidebarPresented else { return }
        let horizontalTravel = min(value.translation.width, value.predictedEndTranslation.width)
        let verticalTravel = abs(value.translation.height)

        guard horizontalTravel < -70,
          value.translation.width < 0,
          abs(value.translation.width) > verticalTravel * 1.35
        else { return }

        closeSidebar()
      }
  }

  private func handleProjectListChange(_ ids: [ProjectID]) {
    let valid = Set(ids)
    if let activeProjectViewID, !valid.contains(activeProjectViewID) {
      self.activeProjectViewID = nil
    }
    navigationPath.removeAll { route in
      switch route {
      case .project(let id), .newChatSetup(let id):
        return !valid.contains(id)
      case .chat:
        return false
      }
    }
  }

  private func handleProjectStatusMessage(_ message: String?) {
    guard let message else { return }
    toastCenter.success(message)
    model.projects.statusMessage = nil
  }

  private func handleMCPStatusMessage(_ message: String?) {
    guard let message else { return }
    toastCenter.success(message)
    model.mcp.statusMessage = nil
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }

  private func openSidebar() {
    dismissKeyboard()
    withAnimation(Self.sidebarAnimation) { isSidebarPresented = true }
  }

  private func closeSidebar() {
    withAnimation(Self.sidebarAnimation) { isSidebarPresented = false }
  }

  private var visibleConversationID: ConversationID? {
    if let last = navigationPath.last { return last.chatID }
    return selectedConversationID
  }

  /// Lightweight themed shell rendered while the sidebar slides closed for a
  /// chat switch so the main thread stays free at 120fps while hydration and
  /// Markdown/thumbnail prewarming run off the main actor.
  private func sidebarChatTransitionShell(for conversationID: ConversationID) -> some View {
    let project = model.projects.project(for: conversationID)
    return theme.backgroundColor
      .ignoresSafeArea()
      .toolbarBackground(.hidden, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Open Sidebar", systemImage: "text.alignleft", action: openSidebar)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Open sidebar")
        }

        if let project {
          ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
              ProjectIconView(project: project, size: 20)
              Text(project.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Project \(project.name)")
          }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
          Button("New Chat", systemImage: "square.and.pencil") {
            startNewChat(in: project?.id)
          }
          .labelStyle(.iconOnly)
        }
      }
  }

  private func invalidateNewChatRequest() {
    newChatRequestRevision &+= 1
    isCreatingNewChat = false
  }

  private func cancelPendingSidebarChat() {
    sidebarChatSelectionRevision &+= 1
    pendingSidebarChat = nil
  }

  private func completePendingSidebarChat(revision: UInt) {
    guard let pending = pendingSidebarChat, pending.revision == revision else { return }
    pendingSidebarChat = nil
    guard model.chats.hasConversation(pending.conversationID) else { return }
    selectedConversationID = pending.conversationID
    initialScrollMessageID = pending.initialScrollMessageID
    openedChatFromProject = false
  }

  private func discardIfEmpty(_ id: ConversationID?) {
    model.chats.abandonNewChat(id)
  }

  private func startNewChat(in projectID: ProjectID?) {
    startNewChat(in: projectID, closeDrawer: true)
  }

  private func startNewChat(in projectID: ProjectID?, closeDrawer: Bool) {
    cancelPendingSidebarChat()
    if closeDrawer { closeSidebar() }
    if isCreatingNewChat && pendingNewChatProjectID == projectID { return }
    if let id = visibleConversationID,
      model.chats.hasConversation(id),
      !model.chats.historyConversations.contains(where: { $0.id == id }),
      !model.chats.isGenerating(id), model.projects.projectID(for: id) == projectID
    {
      return // Repeated New Chat preserves the active unsent session and edits.
    }

    let pushInStack = projectID != nil && (!navigationPath.isEmpty || selectedConversationID == nil)

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
      guard canCreateStandaloneChat else { return }
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
        if let projectID, shouldPresentProjectSetup(for: projectID),
          navigationPath.last != .newChatSetup(projectID)
        {
          navigationPath.append(.newChatSetup(projectID))
        }
        return
      }
      if pushInStack {
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
        initialScrollMessageID = nil
      }
    }
  }

  /// Matches `ChatView.readiness == .ready` for standalone chats so tapping
  /// "New Chat" without a usable provider lands on the setup screen directly
  /// instead of triggering an error alert and false storage telemetry.
  private var canCreateStandaloneChat: Bool {
    let enabledAccounts = model.providers.accounts.filter(\.isEnabled)
    let resolvedAccount: ProviderAccount?
    if let defaultAccount = model.providers.resolvedDefaultAccount, defaultAccount.isEnabled {
      resolvedAccount = defaultAccount
    } else {
      resolvedAccount = enabledAccounts.first
    }
    guard let account = resolvedAccount else { return false }
    if model.providers.provider(for: account.providerID)?.requiresCredential == true,
      !model.providers.credentialAccountIDs.contains(account.id)
    {
      return false
    }
    return model.providers.models(for: account.id).contains(where: \.isAvailable)
  }

  /// Only push `.newChatSetup(projectID)` when the project still exists and
  /// genuinely lacks a usable provider account or available model; storage or
  /// not-found failures are already reported via `chats.errorMessage` and would
  /// otherwise spin forever on a `.ready` setup screen.
  private func shouldPresentProjectSetup(for projectID: ProjectID) -> Bool {
    guard let project = model.projects.project(projectID) else { return false }
    let enabledAccounts = model.providers.accounts.filter(\.isEnabled)
    let resolvedAccount: ProviderAccount?
    if let accountID = project.accountID {
      resolvedAccount = enabledAccounts.first { $0.id == accountID }
    } else if let defaultAccount = model.providers.resolvedDefaultAccount, defaultAccount.isEnabled {
      resolvedAccount = defaultAccount
    } else {
      resolvedAccount = enabledAccounts.first
    }
    guard let account = resolvedAccount else { return true }
    let availableModels = model.providers.models(for: account.id).filter(\.isAvailable)
    if let modelID = project.modelID {
      return !availableModels.contains(where: { $0.model.id == modelID })
    }
    return availableModels.isEmpty
  }

  private func handleRootConversationDeleted(in projectID: ProjectID?) {
    cancelPendingSidebarChat()
    let validProjectID = projectID.flatMap { model.projects.project($0)?.id }
    if openedChatFromProject, let validProjectID {
      invalidateNewChatRequest()
      activeProjectViewID = validProjectID
      openedChatFromProject = false
      selectedConversationID = nil
      initialScrollMessageID = nil
    } else {
      startNewChat(in: validProjectID)
    }
  }

  /// Sidebar menu sections replace the main screen; whatever was showing
  /// yields.
  private func openMainScreen(_ screen: ChatSidebarView.SidebarDestination) {
    cancelPendingSidebarChat()
    if activeScreen == screen,
      selectedConversationID == nil,
      activeProjectViewID == nil,
      navigationPath.isEmpty
    {
      closeSidebar()
      return
    }
    invalidateNewChatRequest()
    navigationPath = []
    discardIfEmpty(selectedConversationID)
    selectedConversationID = nil
    initialScrollMessageID = nil
    activeProjectViewID = nil
    openedChatFromProject = false
    activeScreen = screen
    closeSidebar()
    switch screen {
    case .providers: BYOKAppAnalytics.track(.featureOpened, dimension: .providers)
    case .library: BYOKAppAnalytics.track(.featureOpened, dimension: .library)
    case .projects: BYOKAppAnalytics.track(.featureOpened, dimension: .projects)
    case .plugins: BYOKAppAnalytics.track(.featureOpened, dimension: .mcp)
    case .usage, .allChats: break // The dashboard also records openings from chat sheets.
    }
  }

  /// Back chevron on a project chat: swap the chat for its project's screen.
  private func exitToProjectView() {
    cancelPendingSidebarChat()
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
    openConversation(id, initialScrollMessageID: nil)
  }

  private func selectSearchResult(_ result: ConversationSearchResult) {
    openConversation(result.conversationID, initialScrollMessageID: result.messageID)
  }

  private func openConversation(
    _ id: ConversationID,
    initialScrollMessageID targetMessageID: ChatMessageID?
  ) {
    invalidateNewChatRequest()

    // Already displaying this exact conversation on the root screen: simply
    // close the drawer without tearing down or flashing the timeline.
    if selectedConversationID == id,
      initialScrollMessageID == targetMessageID,
      activeProjectViewID == nil,
      activeScreen == nil,
      navigationPath.isEmpty,
      !openedChatFromProject
    {
      cancelPendingSidebarChat()
      if isSidebarPresented { closeSidebar() }
      return
    }

    navigationPath = []
    discardIfEmpty(selectedConversationID == id ? nil : selectedConversationID)
    activeProjectViewID = nil
    openedChatFromProject = false
    activeScreen = nil

    guard isSidebarPresented else {
      cancelPendingSidebarChat()
      selectedConversationID = id
      initialScrollMessageID = targetMessageID
      return
    }

    // Two-phase sidebar handoff:
    // 1. Immediately clear the outgoing surface to a lightweight shell and kick
    //    off background hydration + Markdown/thumbnail prewarming in parallel.
    // 2. Mount the incoming ChatView once the drawer close animation finishes.
    cancelPendingSidebarChat()
    let revision = sidebarChatSelectionRevision
    selectedConversationID = nil
    initialScrollMessageID = nil
    pendingSidebarChat = PendingSidebarChatSelection(
      conversationID: id,
      initialScrollMessageID: targetMessageID,
      revision: revision
    )

    let scale = displayScale
    Task { @MainActor in
      await model.chats.loadConversation(id, displayScale: scale)
    }

    withAnimation(Self.sidebarAnimation, completionCriteria: .logicallyComplete) {
      isSidebarPresented = false
    } completion: {
      completePendingSidebarChat(revision: revision)
    }
  }

  /// A library entry saved from a chat jumps back to its source message.
  private func openLibrarySourceChat(_ entry: LibraryEntry) {
    guard case let .chat(conversationID, messageID) = entry.source,
      model.chats.hasConversation(conversationID)
    else { return }
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
    BYOKAppAnalytics.track(.featureOpened, dimension: .settings)
  }
}
