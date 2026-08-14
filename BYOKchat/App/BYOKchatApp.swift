import AppFoundation
import SwiftUI

@main
@MainActor
struct BYOKchatApp: App {
  @State private var model: AppModel
  private let purchases: BYOKPurchaseStore

  init() {
    #if DEBUG
    BYOKScreenshotFixtures.prepareIfNeeded()
    #endif
    _model = State(initialValue: AppModel())
    purchases = BYOKPurchaseStore()
  }

  var body: some Scene {
    WindowGroup {
      AppRootView(
        model: model,
        purchases: purchases,
        restartApp: { model = AppModel() }
      )
      .id(ObjectIdentifier(model))
      .appFoundationTheme(model.themeManager)
      .environment(model)
      .environment(purchases.manager)
    }
  }
}
