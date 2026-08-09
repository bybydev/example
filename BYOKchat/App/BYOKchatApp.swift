import AppFoundation
import SwiftUI

@main
@MainActor
struct BYOKchatApp: App {
  @State private var model = AppModel()
  private let purchases = BYOKPurchaseStore()

  var body: some Scene {
    WindowGroup {
      AppRootView(model: model, purchases: purchases)
        .appFoundationTheme(model.themeManager)
        .environment(model)
        .environment(purchases.manager)
    }
  }
}
