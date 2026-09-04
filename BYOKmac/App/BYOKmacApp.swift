import MacAppFoundation
import SwiftUI

@main
@MainActor
struct BYOKmacApp: App {
  @Environment(\.openWindow) private var openWindow
  @State private var model = MacAppModel()
  @State private var proGateCenter = MacProGateCenter.shared

  private let purchases = MacPurchaseStore.manager

  var body: some Scene {
    WindowGroup("BYOKchat", id: "main") {
      MacStartupView(model: model)
        .frame(minWidth: 760, minHeight: 520)
        .preferredColorScheme(model.theme.preferredColorScheme)
        .tint(MacDesignTokens.Colors.accent)
        .environment(\.macThemeRevision, model.theme.revision)
        .environment(purchases)
        .environment(proGateCenter)
        .managesPurchases(purchases)
        .onChange(of: proGateCenter.requestID) { _, _ in
          openWindow(id: MacWindowID.proPaywall)
        }
        .task {
          await model.start()
        }
    }
    .defaultSize(width: 1_180, height: 760)
    .windowResizability(.contentMinSize)
    .commands {
      SidebarCommands()
      MacCommands(model: model)

      #if DEBUG
      CommandMenu("Developer") {
        Button("Developer Tools…") {
          openWindow(id: MacAppFoundationDeveloperTools.windowID)
        }
        .keyboardShortcut("d", modifiers: [.command, .option])

        Divider()

        Button("Use Simulated Purchases") {
          UserDefaults.standard.set(true, forKey: MacPurchaseStore.simulatedModeKey)
          Task { await purchases.setSimulatedPurchasesEnabled(true) }
        }

        Button("Use StoreKit") {
          UserDefaults.standard.set(false, forKey: MacPurchaseStore.simulatedModeKey)
          Task { await purchases.setSimulatedPurchasesEnabled(false) }
        }

        Button("Reset Simulated Purchases", role: .destructive) {
          UserDefaults.standard.set(true, forKey: MacPurchaseStore.simulatedModeKey)
          Task {
            await purchases.setSimulatedPurchasesEnabled(true)
            await purchases.resetSimulatedPurchases()
          }
        }
      }
      #endif
    }

    Window("BYOK Pro", id: MacWindowID.proPaywall) {
      MacProPaywallWindow(purchaseManager: purchases)
        .preferredColorScheme(model.theme.preferredColorScheme)
        .tint(MacDesignTokens.Colors.accent)
        .environment(\.macThemeRevision, model.theme.revision)
        .environment(purchases)
    }
    .defaultSize(width: 860, height: 600)
    .windowResizability(.contentSize)

    #if DEBUG
    Window(
      MacAppFoundationDeveloperTools.windowTitle,
      id: MacAppFoundationDeveloperTools.windowID
    ) {
      FoundationDeveloperView(
        purchaseManager: purchases,
        configuration: MacPurchaseStore.developerConfiguration
      )
      .environment(purchases)
    }
    .defaultSize(
      width: MacAppFoundationDeveloperTools.defaultWidth,
      height: MacAppFoundationDeveloperTools.defaultHeight
    )
    #endif

    Settings {
      MacSettingsView(model: model, purchaseManager: purchases)
        .environment(purchases)
    }
  }
}