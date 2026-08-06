import SwiftUI

@main
struct BYOKchatApp: App {
  @State private var model = ProviderManagementModel()

  var body: some Scene {
    WindowGroup {
      ProviderRootView(model: model)
    }
  }
}
