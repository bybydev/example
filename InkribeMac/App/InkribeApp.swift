import InkribeExport
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
                id: InkribeOnboardingConfiguration.id,
                stepCount: InkribeOnboardingConfiguration.stepCount
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
        .defaultLaunchBehavior(onboarding.mainWindowLaunchBehavior)
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

            CommandMenu("Transcript") {
                Button("Copy Edited Transcript") {
                    copyActiveTranscript(source: .edited)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(shellState.activeTranscriptID == nil)

                Button("Copy Raw Transcript") {
                    copyActiveTranscript(source: .raw)
                }
                .disabled(shellState.activeTranscriptID == nil)

                Divider()

                Menu("Export Plain Text") {
                    Button("Edited…") {
                        exportActiveTranscript(.plainText, source: .edited)
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(shellState.activeTranscriptID == nil)

                    Button("Raw…") {
                        exportActiveTranscript(.plainText, source: .raw)
                    }
                    .disabled(shellState.activeTranscriptID == nil)
                }

                Menu("Export Markdown") {
                    Button("Edited…") {
                        exportActiveTranscript(.markdown, source: .edited)
                    }
                    .disabled(shellState.activeTranscriptID == nil)

                    Button("Raw…") {
                        exportActiveTranscript(.markdown, source: .raw)
                    }
                    .disabled(shellState.activeTranscriptID == nil)
                }

                Button("Export SRT…") {
                    exportActiveTranscript(.srt)
                }
                .disabled(shellState.activeTranscriptID == nil)

                Button("Export VTT…") {
                    exportActiveTranscript(.vtt)
                }
                .disabled(shellState.activeTranscriptID == nil)
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

        OnboardingWindow(
            "Welcome to Inkribe",
            id: InkribeWindowID.onboarding,
            state: onboarding,
            defaultWidth: InkribeOnboardingConfiguration.defaultWidth,
            defaultHeight: InkribeOnboardingConfiguration.defaultHeight
        ) {
            InkribeOnboardingView(onboarding: onboarding)
                .macAppTheme(themeStore)
        }

        Window("Inkribe Pro", id: InkribeWindowID.proPaywall) {
            InkribeProPaywallView(purchaseManager: purchases)
                .macAppTheme(themeStore)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 860, height: 580)
        .windowResizability(.contentSize)

        Settings {
            InkribeSettingsView(
                purchaseManager: purchases,
                themeStore: themeStore,
                settingsRouter: settingsRouter,
                appState: appState
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
                configuration: developerConfiguration
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

    private func copyActiveTranscript(source: TranscriptTextSource) {
        guard let id = shellState.activeTranscriptID else { return }
        TranscriptExportActions.copy(
            id: id,
            source: source,
            appState: appState
        )
    }

    private func exportActiveTranscript(
        _ format: TranscriptExportFormat,
        source: TranscriptTextSource = .edited
    ) {
        guard let id = shellState.activeTranscriptID else { return }

        if format == .srt || format == .vtt,
           case .requiresPro = InkribeProCapability.subtitleExport.decision(
               hasPro: purchases.hasPro
           ) {
            openWindow(id: InkribeWindowID.proPaywall)
            return
        }

        TranscriptExportActions.export(
            id: id,
            format: format,
            textSource: source,
            appState: appState
        )
    }

    #if DEBUG
    private var developerConfiguration: FoundationDeveloperConfiguration {
        FoundationDeveloperConfiguration(
            replays: developerReplays,
            additionalSections: [
                FoundationDeveloperSection(
                    id: "inkribe.product-flows",
                    title: "Product Flows",
                    items: [
                        .value(
                            FoundationDeveloperValue(
                                id: "inkribe.onboarding-status",
                                title: "Onboarding",
                                value: {
                                    onboarding.isCompleted
                                        ? "Completed"
                                        : "Step \(onboarding.currentStep + 1) of \(onboarding.stepCount)"
                                }
                            )
                        ),
                        .action(
                            FoundationDeveloperAction(
                                id: "inkribe.replay-onboarding",
                                title: "Replay Onboarding",
                                systemImage: "sparkles"
                            ) {
                                onboarding.restart()
                                openWindow(id: InkribeWindowID.onboarding)
                            }
                        )
                    ]
                )
            ]
        )
    }

    private var developerReplays: [FoundationDeveloperReplay] {
        var replays: [FoundationDeveloperReplay] = []

        if let paywallConfiguration = InkribeCommerce.paywallConfiguration {
            replays.append(
                FoundationDeveloperReplay(
                    id: "inkribe.pro-paywall",
                    title: "Pro Paywall",
                    systemImage: "crown.fill"
                ) { dismiss in
                    ProPaywallView(
                        purchaseManager: purchases,
                        configuration: paywallConfiguration,
                        onPurchased: { _ in dismiss() },
                        onRestored: dismiss,
                        onClose: dismiss
                    )
                    .macAppTheme(themeStore)
                }
            )
        }

        replays.append(
            FoundationDeveloperReplay(
                id: "inkribe.ai-upsell",
                title: "Local AI Upsell",
                systemImage: "sparkles"
            ) { dismiss in
                InkribeProUpsellView(
                    capability: .localAI,
                    onUpgrade: {
                        dismiss()
                        openWindow(id: InkribeWindowID.proPaywall)
                    },
                    onDismiss: dismiss
                )
                .macAppTheme(themeStore)
            }
        )

        return replays
    }
    #endif
}
