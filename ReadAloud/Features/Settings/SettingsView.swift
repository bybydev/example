import AppFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(PurchaseManager.self)
    private var purchases
    @Environment(ThemeManager.self)
    private var themes
    @Environment(ProjectRuntimeManager.self)
    private var runtimeManager

    @AppStorage(
        ReadAloudPreferences
            .Key.defaultVoiceID
    )
    private var defaultVoiceID =
        ReadAloudNarrationCatalog
            .freeDefaultVoiceID

    @AppStorage(
        ReadAloudPreferences
            .Key.defaultSpeed
    )
    private var defaultSpeed = 1.0

    @AppStorage(ReadAloudPreferences.Key.pronunciationFallbackMode)
    private var pronunciationMode = PronunciationFallbackMode.adaptive.rawValue

    @AppStorage(
        ReadAloudPreferences
            .Key.skipInterval
    )
    private var skipInterval = 15

    @AppStorage(
        ReadAloudPreferences
            .Key.continueToNextChapter
    )
    private var continueToNextChapter =
        true

    @AppStorage(
        ReadAloudPreferences
            .Key.prefetchCount
    )
    private var prefetchCount = 2

    @AppStorage(
        ReadAloudPreferences
            .Key.generateWhileListening
    )
    private var generateWhileListening =
        true

    @State private var
        paywallPresented = false
    @State private var defaultVoicePickerPresented = false
    @State private var defaultSpeedPickerPresented = false

    private var version: String {
        let version =
            Bundle.main.object(
                forInfoDictionaryKey:
                    "CFBundleShortVersionString"
            ) as? String
        let build =
            Bundle.main.object(
                forInfoDictionaryKey:
                    "CFBundleVersion"
            ) as? String
        return
            "\(version ?? "—") (\(build ?? "—"))"
    }

    #if DEBUG
    private var developerConfiguration:
        FoundationDeveloperConfiguration
    {
        FoundationDeveloperConfiguration(
            replays: [
                FoundationDeveloperReplay(
                    id: "onboarding",
                    title: "Onboarding",
                    systemImage: "rectangle.stack.fill",
                    presentation: .fullScreen
                ) { close in
                    ReadAloudOnboardingView(onCompletion: close)
                        .appFoundationTheme(themes, purchaseManager: purchases)
                },
            ],
            additionalSections: [
                FoundationDeveloperSection(
                    title: "ReadAloud",
                    items: [
                        .destination(
                            FoundationDeveloperDestination(
                                title:
                                    "Kokoro Prototype",
                                systemImage:
                                    "waveform"
                            ) {
                                ReaderView()
                            }
                        ),
                        .destination(
                            FoundationDeveloperDestination(
                                title:
                                    "Pro Paywall",
                                systemImage:
                                    "crown"
                            ) {
                                ReadAloudProPaywall()
                            }
                        ),
                    ]
                )
            ]
        )
    }
    #endif

    var body: some View {
        ReadAloudThemedList {
            ProPlanSettingsSection(
                purchaseManager:
                    purchases,
                configuration:
                    ReadAloudCommerce
                        .planConfiguration,
                onUpgrade: {
                    paywallPresented = true
                }
            )

            Section("Appearance") {
                ThemePickerView(
                    manager: themes,
                    title: nil,
                    showsCountdown: false,
                    onRequestUpgrade: {
                        paywallPresented =
                            true
                    }
                )
                .padding(.vertical, 6)
            }

            Section {
                NavigationLink {
                    ONNXModelSettingsView()
                } label: {
                    Label("Kokoro ONNX INT8", systemImage: "cpu")
                }

                Picker("Unknown Words", selection: $pronunciationMode) {
                    ForEach(PronunciationFallbackMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            } header: {
                Text("Speech Engine")
            } footer: {
                Text(PronunciationFallbackMode(rawValue: pronunciationMode)?.explanation
                    ?? PronunciationFallbackMode.adaptive.explanation)
                Text("Only pronunciation problems use this mode. Model errors still stop playback. Speech assets are bundled for offline use.")
            }

            narrationDefaultsSection
            playbackSection
            generationSection

            Section("App Data") {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    Label(
                        "Storage",
                        systemImage:
                            "externaldrive"
                    )
                }
            }

            Section("Support") {
                Link(
                    destination:
                        ReadAloudCommerce
                            .supportURL
                ) {
                    Label(
                        "Support",
                        systemImage:
                            "questionmark.circle"
                    )
                }

                Link(
                    destination:
                        ReadAloudCommerce
                            .privacyURL
                ) {
                    Label(
                        "Privacy",
                        systemImage:
                            "hand.raised"
                    )
                }

                Link(
                    destination:
                        ReadAloudCommerce
                            .termsURL
                ) {
                    Label(
                        "Terms of Use",
                        systemImage:
                            "doc.text"
                    )
                }
            }

            Section("About") {
                LabeledContent(
                    "Synthesis",
                    value: "On-device"
                )
                LabeledContent(
                    "Version",
                    value: version
                )
            }

            #if DEBUG
            Section("Developer") {
                NavigationLink {
                    FoundationDeveloperView(
                        purchaseManager:
                            purchases,
                        configuration:
                            developerConfiguration
                    )
                } label: {
                    Label(
                        "Developer Tools",
                        systemImage:
                            "hammer.fill"
                    )
                }
            }
            #endif
        }
        .readAloudThemeSurface()
        .navigationTitle("Settings")
        .sheet(
            isPresented:
                $paywallPresented
        ) {
            ReadAloudProPaywall()
        }
        .sheet(isPresented: $defaultVoicePickerPresented) {
            ReadAloudVoicesPickerView(
                selectedVoiceID: defaultVoiceID,
                inheritTitle: nil,
                inheritDetail: nil
            ) { voiceID in
                guard let voiceID else { return false }
                defaultVoiceID = voiceID
                return true
            }
        }
        .sheet(isPresented: $defaultSpeedPickerPresented) {
            ReadAloudSpeedPickerView(speed: defaultSpeed) { speed in
                guard let speed else { return false }
                defaultSpeed = speed
                return true
            }
        }
        .onChange(of: pronunciationMode) { _, _ in
            refreshLoadedProjects()
        }
        .onChange(
            of: defaultVoiceID
        ) { _, _ in
            refreshLoadedProjects()
        }
        .onChange(
            of: defaultSpeed
        ) { _, _ in
            refreshLoadedProjects()
        }
        .onChange(
            of: prefetchCount
        ) { _, _ in
            refreshLoadedProjects()
        }
        .onChange(
            of: generateWhileListening
        ) { _, _ in
            refreshLoadedProjects()
        }
    }

    private var narrationDefaultsSection:
        some View
    {
        Section {
            Button {
                defaultVoicePickerPresented = true
            } label: {
                HStack {
                    Text("Default Voice")
                    Spacer()
                    Text(ReadAloudNarrationCatalog.voiceName(defaultVoiceID))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                defaultSpeedPickerPresented = true
            } label: {
                HStack {
                    Text("Default Speed")
                    Spacer()
                    Text(ReadAloudSpeedPickerView.speedLabel(defaultSpeed))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("ReadAloud Defaults")
        } footer: {
            if !purchases.hasPro,
               !ReadAloudAccessPolicy
                .freeVoiceIDs
                .contains(
                    defaultVoiceID
                )
            {
                Text(
                    "Your saved Pro voice is preserved. Heart is used while Pro is inactive."
                )
            } else {
                Text(
                    "Projects set to App Default follow these values."
                )
            }
        }
    }

    private var playbackSection:
        some View
    {
        Section("Playback") {
            Picker(
                "Skip Interval",
                selection:
                    $skipInterval
            ) {
                ForEach(
                    ReadAloudPreferences
                        .supportedSkipIntervals,
                    id: \.self
                ) { seconds in
                    Text(
                        "\(seconds) seconds"
                    )
                    .tag(seconds)
                }
            }

            Toggle(
                "Continue to Next Chapter",
                isOn:
                    $continueToNextChapter
            )
        }
    }

    private var generationSection: some View {
        Section {
            Picker("Prefetch", selection: $prefetchCount) {
                Text("Off").tag(0)
                Text("Next Chapter").tag(1)
                Text("Next 2 Chapters").tag(2)
            }
            Toggle("Generate While Listening", isOn: $generateWhileListening)
            Toggle("Background Generation", isOn: Binding(
                get: { !runtimeManager.isBackgroundPrefetchPaused },
                set: { runtimeManager.setBackgroundPrefetchPaused(!$0) }
            ))
        } header: {
            Text("Generation")
        } footer: {
            Text("Queued generation yields to live speech and pauses when ReadAloud is in the background without listening. Turning off Background Generation keeps queued work for later and does not stop listening.")
            if let error = runtimeManager.generationRecoveryError {
                Text("Some offline work could not be restored: \(error)")
            }
        }
    }

    private func refreshLoadedProjects() {
        Task {
            await runtimeManager
                .refreshAllLoaded()
        }
    }
}

