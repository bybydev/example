import AppFoundation
import SwiftUI

@main
@MainActor
struct BYOKchatApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      AppRootView(model: model)
        .appFoundationTheme(model.themeManager)
    }
  }
}
