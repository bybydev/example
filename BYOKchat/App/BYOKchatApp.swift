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
    let appModel = AppModel()
    let purchaseStore = BYOKPurchaseStore()
    // Bind before preparing StoreKit so verified access and theme persistence
    // stay in sync even when the root view is not mounted yet.
    appModel.themeManager.bind(to: purchaseStore.manager)
    _model = State(initialValue: appModel)
    purchases = purchaseStore
  }

  var body: some Scene {
    WindowGroup {
      AppRootView(
        model: model,
        purchases: purchases,
        restartApp: { model = AppModel() }
      )
      .id(ObjectIdentifier(model))
      .appFoundationTheme(model.themeManager, purchaseManager: purchases.manager)
      .environment(model)
      .environment(purchases.manager)
    }
  }
}
