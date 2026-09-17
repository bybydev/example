import Logging
import MacAppFoundation
import SwiftUI

@main
@MainActor
struct InkribeApp: App {
    @Environment(\.openWindow) private var openWindow

    @State private var themeStore: MacAppThemeStore
    @State private var settingsRouter: MacAppSettingsRouter
    @State private var onboarding: OnboardingState
    @State private var appState: InkribeAppState

    private let purchases: PurchaseManager
    private let logger: Logger

    init() {
        InkribeLogging.bootstrap()
        logger = Logger(label: "Inkribe.App")

        _themeStore = State(
            initialValue: MacAppThemeStore(configuration: InkribeTheme.configuration)
        )
        _settingsRouter = State(initialValue: MacAppSettingsRouter())
        _onboarding = State(
            initialValue: OnboardingState(
                id: "inkribe",
                stepCount: 4
            )
        )

        let appState = InkribeAppState()
        _appState = State(initialValue: appState)
        purchases = InkribeCommerce.makePurchaseManager()

        do {
            try appState.start()
            logger.info("Inkribe foundation initialized")
        } catch {
            logger.error("Inkribe foundation startup failed: \(String(describing: error))")
        }
    }

    var body: some Scene {
        Window("Inkribe", id: InkribeWindowID.main) {
            InkribeRootView(appState: appState)
                .macAppTheme(themeStore)
                .managesPurchases(purchases)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            #if DEBUG
            CommandMenu("Developer") {
                Button("Developer Tools…") {
                    openWindow(id: MacAppFoundationDeveloperTools.windowID)
                }
                .keyboardShortcut("d", modifiers: [.command, .option])

                Button("Show Logs") {
                    openWindow(id: InkribeWindowID.logs)
                }
            }
            #endif
        }

        #if DEBUG
        Window(
            MacAppFoundationDeveloperTools.windowTitle,
            id: MacAppFoundationDeveloperTools.windowID
        ) {
            FoundationDeveloperView(
                purchaseManager: purchases,
                configuration: FoundationDeveloperConfiguration()
            )
            .macAppTheme(themeStore)
        }
        .defaultSize(
            width: MacAppFoundationDeveloperTools.defaultWidth,
            height: MacAppFoundationDeveloperTools.defaultHeight
        )

        Window("Logs", id: InkribeWindowID.logs) {
            LogInspectorView(store: LogStore.shared)
                .macAppTheme(themeStore)
                .frame(minWidth: 600, minHeight: 500)
        }
        .defaultSize(width: 700, height: 600)
        #endif
    }
}
