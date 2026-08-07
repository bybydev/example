import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct AppRootView: View {
  private struct ChatPresentationID: Hashable {
    let conversationID: ConversationID
    let messageID: ChatMessageID?
  }

  @Bindable var model: AppModel

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @State private var selectedConversationID: ConversationID?
  @State private var newChatProjectID: ProjectID?
  @State private var initialScrollMessageID: ChatMessageID?
  @State private var isSidebarPresented = false
  @State private var isSettingsPresented = false

  var body: some View {
    GeometryReader { geometry in
      let drawerWidth = min(geometry.size.width * 0.80, 390)

      ZStack(alignment: .leading) {
        theme.backgroundColor
          .ignoresSafeArea()

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
            selectedConversationID: selectedConversationID,
            newChat: startNewChat(in:),
            selectConversation: selectConversation,
            selectSearchResult: selectSearchResult,
            openSettings: openSettings,
            close: closeSidebar
          )
          .frame(width: drawerWidth)
          .frame(maxHeight: .infinity)
          .transition(.move(edge: .leading))
          .zIndex(2)
        }
      }
      .clipped()
      .animation(.snappy(duration: 0.28), value: isSidebarPresented)
    }
    .task {
      await model.load()
    }
    .onChange(of: model.chats.conversations.map(\.id)) { _, ids in
      guard let selectedConversationID, !ids.contains(selectedConversationID) else { return }
      self.selectedConversationID = nil
      initialScrollMessageID = nil
    }
    .onChange(of: model.projects.projects.map(\.id)) { _, ids in
      guard let newChatProjectID, !ids.contains(newChatProjectID) else { return }
      self.newChatProjectID = nil
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        Task { await model.projectSync.syncIfEnabled() }
      } else {
        Task { await model.chats.persistActiveMessages() }
      }
    }
    .sheet(isPresented: $isSettingsPresented) {
      SettingsView(model: model)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          ProjectSyncSettingsBar(model: model.projectSync)
        }
        .presentationDragIndicator(.visible)
    }
    .overlay(alignment: .top) {
      if model.providers.isBusy || model.chats.isBusy || model.projects.isBusy || model.mcp.isBusy
        || model.projectSync.isSyncing || model.dataPortability.isBusy
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
      if let selectedConversationID,
        model.chats.conversation(selectedConversationID) != nil
      {
        ChatView(
          conversationID: selectedConversationID,
          initialScrollMessageID: initialScrollMessageID,
          chats: model.chats,
          providers: model.providers,
          projects: model.projects,
          mcp: model.mcp,
          openSidebar: openSidebar,
          startNewChat: {
            startNewChat(in: model.projects.projectID(for: selectedConversationID))
          }
        )
        .id(
          ChatPresentationID(
            conversationID: selectedConversationID,
            messageID: initialScrollMessageID
          )
        )
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
  }

  private var openSidebarGesture: some Gesture {
    DragGesture(minimumDistance: 16, coordinateSpace: .local)
      .onEnded { value in
        let horizontalTravel = max(value.translation.width, value.predictedEndTranslation.width)
        let verticalTravel = abs(value.translation.height)

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
    closeSidebar()
  }

  private func selectConversation(_ id: ConversationID) {
    selectedConversationID = id
    newChatProjectID = nil
    initialScrollMessageID = nil
    closeSidebar()
  }

  private func selectSearchResult(_ result: ConversationSearchResult) {
    selectedConversationID = result.conversationID
    newChatProjectID = nil
    initialScrollMessageID = result.messageID
    closeSidebar()
  }

  private func openSettings() {
    closeSidebar()
    isSettingsPresented = true
  }
}
