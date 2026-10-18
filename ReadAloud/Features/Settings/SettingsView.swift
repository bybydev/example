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
                    title: "Speech Diagnostics",
                    items: [
                        .destination(
                            FoundationDeveloperDestination(
                                title: "Kokoro ONNX INT8",
                                systemImage: "cpu"
                            ) {
                                ONNXModelSettingsView()
                            }
                        ),
                        .destination(
                            FoundationDeveloperDestination(
                                title: "Generation Recovery",
                                systemImage: "arrow.clockwise"
                            ) {
                                ReadAloudThemedList {
                                    Section("Details") {
                                        Text(runtimeManager.generationRecoveryError
                                            ?? "No generation recovery errors.")
                                    }
                                }
                                .readAloudThemeSurface()
                                .navigationTitle("Generation Recovery")
                            }
                        ),
                    ]
                ),
                FoundationDeveloperSection(
                    title: "Prototypes",
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
                    ]
                ),
                FoundationDeveloperSection(
                    title: "UI Previews",
                    items: [
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

            listeningSection

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

            offlineStorageSection

            Section("Advanced") {
                NavigationLink {
                    AdvancedListeningSettingsView()
                } label: {
                    Label("Advanced Listening", systemImage: "slider.horizontal.3")
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

            Section {
                LabeledContent(
                    "Version",
                    value: version
                )
            } header: {
                Text("About")
            } footer: {
                Text("Speech is generated on your device and works offline.")
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
    }

    private var listeningSection:
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

            playbackRows
        } header: {
            Text("Listening")
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
                    "Projects set to App Default follow the default voice and speed."
                )
            }
        }
    }

    private var playbackRows:
        some View
    {
        Group {
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

    private var offlineStorageSection: some View {
        Section {
            Toggle("Pause Audio Generation", isOn: Binding(
                get: { runtimeManager.isBackgroundPrefetchPaused },
                set: { runtimeManager.setBackgroundPrefetchPaused($0) }
            ))
            NavigationLink {
                StorageManagementView()
            } label: {
                Label("Storage", systemImage: "externaldrive")
            }
        } header: {
            Text("Offline & Storage")
        } footer: {
            Text("Pauses queued generation and preparation of upcoming chapters. Listening continues and queued work is kept for later.")
            if runtimeManager.generationRecoveryError != nil {
                Text("Some queued audio could not be restored. Open the book and try generating its audio again.")
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

private struct AdvancedListeningSettingsView: View {
    @Environment(ProjectRuntimeManager.self) private var runtimeManager

    @AppStorage(ReadAloudPreferences.Key.pronunciationFallbackMode)
    private var pronunciationMode = PronunciationFallbackMode.adaptive.rawValue
    @AppStorage(ReadAloudPreferences.Key.prefetchCount)
    private var prefetchCount = 2
    @AppStorage(ReadAloudPreferences.Key.generateWhileListening)
    private var generateWhileListening = true

    var body: some View {
        ReadAloudThemedList {
            Section {
                Picker("Unknown Words", selection: $pronunciationMode) {
                    ForEach(PronunciationFallbackMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            } header: {
                Text("Pronunciation")
            } footer: {
                Text(PronunciationFallbackMode(rawValue: pronunciationMode)?.explanation
                    ?? PronunciationFallbackMode.adaptive.explanation)
            }

            Section {
                Picker("Prepare Upcoming Chapters", selection: $prefetchCount) {
                    Text("Off").tag(0)
                    Text("Next Chapter").tag(1)
                    Text("Next 2 Chapters").tag(2)
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Offline Preparation")
            } footer: {
                Text("Choose how many upcoming chapters to prepare while listening. Audio generation must be unpaused.")
            }

            Section {
                Toggle("Generate While Listening", isOn: $generateWhileListening)
            } header: {
                Text("Performance")
            } footer: {
                Text("Allow queued audio generation while a book is playing. Turn this off if listening feels slow.")
            }
        }
        .readAloudThemeSurface()
        .navigationTitle("Advanced Listening")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pronunciationMode) { _, _ in refreshLoadedProjects() }
        .onChange(of: prefetchCount) { _, _ in refreshLoadedProjects() }
        .onChange(of: generateWhileListening) { _, _ in refreshLoadedProjects() }
    }

    private func refreshLoadedProjects() {
        Task { await runtimeManager.refreshAllLoaded() }
    }
}
