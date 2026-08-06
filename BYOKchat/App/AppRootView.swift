import SwiftUI

struct AppRootView: View {
  @Bindable var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var selectedTab: AppTab = .chats

  enum AppTab: Hashable {
    case chats
    case settings
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      ChatListView(
        chats: model.chats,
        providers: model.providers,
        openProviders: { selectedTab = .settings }
      )
      .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
      .tag(AppTab.chats)

      SettingsView(model: model)
        .tabItem { Label("Settings", systemImage: "gearshape") }
        .tag(AppTab.settings)
    }
    .task { await model.load() }
    .onChange(of: scenePhase) { _, phase in
      guard phase != .active else { return }
      Task { await model.chats.persistActiveMessages() }
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
}
