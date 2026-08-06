import SwiftUI

struct AppRootView: View {
  @Bindable var model: AppModel
  @State private var selectedTab: AppTab = .chats

  enum AppTab: Hashable {
    case chats
    case providers
    case console
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      ChatListView(
        chats: model.chats,
        providers: model.providers,
        openProviders: { selectedTab = .providers }
      )
      .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
      .tag(AppTab.chats)

      NavigationStack {
        ProviderListView(model: model.providers)
      }
      .tabItem { Label("Providers", systemImage: "key.horizontal") }
      .tag(AppTab.providers)

      NavigationStack {
        ProviderConsoleView(model: model.providers)
      }
      .tabItem { Label("Console", systemImage: "terminal") }
      .tag(AppTab.console)
    }
    .task { await model.load() }
    .overlay(alignment: .top) {
      if model.providers.isBusy || model.chats.isBusy {
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
