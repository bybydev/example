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
    @State private var shellState: InkribeShellState

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
        _shellState = State(initialValue: InkribeShellState())

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
            InkribeRootView(
                appState: appState,
                shellState: shellState,
                purchaseManager: purchases,
                settingsRouter: settingsRouter
            )
            .macAppTheme(themeStore)
            .managesPurchases(purchases)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button(shellState.isSidebarExpanded ? "Hide Sidebar" : "Show Sidebar") {
                    shellState.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }

            CommandMenu("Navigate") {
                Button("Library") { shellState.select(.library) }
                    .keyboardShortcut("1", modifiers: [.command])

                Button("Record") { shellState.select(.record) }
                    .keyboardShortcut("2", modifiers: [.command])

                Button("Import") { shellState.select(.import) }
                    .keyboardShortcut("3", modifiers: [.command])
            }

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

        Settings {
            InkribeSettingsView(
                purchaseManager: purchases,
                themeStore: themeStore,
                settingsRouter: settingsRouter
            )
            .macAppTheme(themeStore)
        }
        .windowStyle(.hiddenTitleBar)

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
