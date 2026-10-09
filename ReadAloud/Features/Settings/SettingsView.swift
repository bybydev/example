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
            } header: {
                Text("Speech Engine")
            } footer: {
                Text("ReadAloud includes its ONNX speech model, pronunciation assets and voices. All listening works offline, without downloads.")
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
            Picker(
                "Default Voice",
                selection:
                    defaultVoiceBinding
            ) {
                ForEach(
                    ReadAloudNarrationCatalog
                        .voices
                ) { voice in
                    HStack {
                        Text(voice.name)
                        if !ReadAloudAccessPolicy
                            .freeVoiceIDs
                            .contains(
                                voice.id
                            )
                        {
                            Text("Pro")
                        }
                    }
                    .tag(voice.id)
                }
            }

            Picker(
                "Default Speed",
                selection:
                    $defaultSpeed
            ) {
                ForEach(
                    ReadAloudNarrationCatalog
                        .synthesisSpeeds,
                    id: \.self
                ) { speed in
                    Text(
                        speedLabel(speed)
                    )
                    .tag(speed)
                }
            }
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

    @ViewBuilder
    private var generationSection:
        some View
    {
        Section {
            if purchases.hasPro {
                Picker(
                    "Prefetch",
                    selection:
                        $prefetchCount
                ) {
                    Text("Off").tag(0)
                    Text("Next Chapter")
                        .tag(1)
                    Text("Next 2 Chapters")
                        .tag(2)
                }

                Toggle(
                    "Generate While Listening",
                    isOn:
                        $generateWhileListening
                )
            } else {
                Button {
                    paywallPresented = true
                } label: {
                    proPreferenceRow(
                        title: "Automatic Prefetch",
                        detail:
                            "Generate upcoming chapters"
                    )
                }

                Button {
                    paywallPresented = true
                } label: {
                    proPreferenceRow(
                        title:
                            "Generate While Listening",
                        detail:
                            "Use idle model time during offline playback"
                    )
                }
            }
        } header: {
            Text("Generation")
        } footer: {
            Text(
                purchases.hasPro
                ? "Queued generation yields whenever foreground streaming needs the speech model."
                : "Single-chapter offline generation remains available on Free."
            )
        }
    }

    private var defaultVoiceBinding:
        Binding<String>
    {
        Binding(
            get: {
                defaultVoiceID
            },
            set: { value in
                guard ReadAloudAccessPolicy
                    .canUseVoice(
                        value,
                        hasPro:
                            purchases.hasPro
                    )
                else {
                    paywallPresented = true
                    return
                }

                defaultVoiceID = value
            }
        )
    }

    private func proPreferenceRow(
        title: String,
        detail: String
    ) -> some View {
        HStack {
            VStack(
                alignment: .leading,
                spacing: 2
            ) {
                Text(title)
                    .foregroundStyle(
                        .primary
                    )
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(
                        .secondary
                    )
            }

            Spacer()

            Text("Pro")
                .font(
                    .caption.weight(
                        .semibold
                    )
                )
                .foregroundStyle(
                    .secondary
                )
        }
    }

    private func speedLabel(
        _ speed: Double
    ) -> String {
        speed.formatted(
            .number.precision(
                .fractionLength(1)
            )
        ) + "×"
    }

    private func refreshLoadedProjects() {
        Task {
            await runtimeManager
                .refreshAllLoaded()
        }
    }
}
