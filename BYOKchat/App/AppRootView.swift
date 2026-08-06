import BYOKchatProviderCore
import SwiftUI

struct AppRootView: View {
  @Bindable var model: AppModel

  @Environment(\.scenePhase) private var scenePhase
  @State private var selectedConversationID: ConversationID?
  @State private var isSidebarPresented = false
  @State private var isSettingsPresented = false
  @State private var didRestoreSelection = false

  var body: some View {
    GeometryReader { geometry in
      let drawerWidth = min(geometry.size.width * 0.88, 360)

      ZStack(alignment: .leading) {
        mainContent
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .allowsHitTesting(!isSidebarPresented)
          .simultaneousGesture(openSidebarGesture)

        if isSidebarPresented {
          Color.black.opacity(0.28)
            .ignoresSafeArea()
            .onTapGesture { closeSidebar() }
            .transition(.opacity)
            .zIndex(1)

          ChatSidebarView(
            chats: model.chats,
            providers: model.providers,
            selectedConversationID: $selectedConversationID,
            newChat: startNewChat,
            openSettings: openSettings,
            close: closeSidebar
          )
          .frame(width: drawerWidth)
          .frame(maxHeight: .infinity)
          .transition(.move(edge: .leading))
          .zIndex(2)
        }
      }
      .animation(.snappy(duration: 0.24), value: isSidebarPresented)
    }
    .task {
      await model.load()
      guard !didRestoreSelection else { return }
      selectedConversationID = model.chats.conversations.first?.id
      didRestoreSelection = true
    }
    .onChange(of: model.chats.conversations.map(\.id)) { _, ids in
      guard let selectedConversationID, !ids.contains(selectedConversationID) else { return }
      self.selectedConversationID = nil
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase != .active else { return }
      Task { await model.chats.persistActiveMessages() }
    }
    .sheet(isPresented: $isSettingsPresented) {
      SettingsView(model: model)
        .presentationDragIndicator(.visible)
    }
    .overlay(alignment: .top) {
      if model.providers.isBusy || model.chats.isBusy || model.dataPortability.isBusy {
        ProgressView()
          .padding(10)
          .background(.regularMaterial, in: Capsule())
          .padding(.top, 8)
      }
    }
    .alert(
      "BYOKchat",
      isPresented: Binding(
        get: { model.providers.errorMessage != nil || model.chats.errorMessage != nil },
        set: { presented in
          if !presented {
            model.providers.errorMessage = nil
            model.chats.errorMessage = nil
          }
        }
      )
    ) {
      Button("OK") {
        model.providers.errorMessage = nil
        model.chats.errorMessage = nil
      }
    } message: {
      Text(model.chats.errorMessage ?? model.providers.errorMessage ?? "Unknown error")
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
          chats: model.chats,
          providers: model.providers,
          openSidebar: openSidebar,
          startNewChat: startNewChat
        )
        .id(selectedConversationID)
      } else {
        NewChatView(
          chats: model.chats,
          providers: model.providers,
          openSidebar: openSidebar,
          openSettings: openSettings,
          selectConversation: selectConversation
        )
      }
    }
  }

  private var openSidebarGesture: some Gesture {
    DragGesture(minimumDistance: 20)
      .onEnded { value in
        guard !isSidebarPresented,
          value.startLocation.x < 28,
          value.translation.width > 80,
          abs(value.translation.width) > abs(value.translation.height)
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

  private func startNewChat() {
    selectedConversationID = nil
    closeSidebar()
  }

  private func selectConversation(_ id: ConversationID) {
    selectedConversationID = id
    closeSidebar()
  }

  private func openSettings() {
    closeSidebar()
    isSettingsPresented = true
  }
}
