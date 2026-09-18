import InkribeAudio
import InkribeTranscription
import MacAppFoundation
import SwiftUI

struct InkribeTranscriptionSettingsPane: View {
    let recorder: MicrophoneRecorder
    @Bindable var preferences: InkribePreferences
    @Environment(\.macAppTheme) private var theme

    private var savedMicrophoneIsUnavailable: Bool {
        guard let saved = preferences.defaultMicrophoneDeviceID else { return false }
        return !recorder.availableDevices.contains(where: { $0.id == saved })
    }

    var body: some View {
        InkribeSettingsSupport.scroll {
            GroupBox("Defaults") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Language", selection: $preferences.defaultTranscriptionLanguage) {
                        ForEach(TranscriptionLanguageCatalog.options) { option in
                            Text(option.displayName).tag(option.code)
                        }
                    }
                    .frame(maxWidth: 320)

                    Picker("Microphone", selection: $preferences.defaultMicrophoneDeviceID) {
                        Text("System Default")
                            .tag(Optional<String>.none)

                        if let saved = preferences.defaultMicrophoneDeviceID,
                           savedMicrophoneIsUnavailable {
                            Text("Saved Microphone — Unavailable")
                                .tag(Optional(saved))
                        }

                        ForEach(recorder.availableDevices) { device in
                            Text(device.isDefault ? "\(device.name) — Current System Default" : device.name)
                                .tag(Optional(device.id))
                        }
                    }
                    .frame(maxWidth: 420)

                    HStack {
                        Text("System Default follows the current macOS input device. A specifically selected microphone is remembered by device ID.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") {
                            recorder.refreshInputDevices()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Performance") {
                Text("Inkribe selects its transcription backend and worker count automatically for the current Mac. Low-level GPU and thread controls are intentionally not exposed as user settings.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .background(theme.canvas)
        .task {
            recorder.refreshInputDevices()
        }
    }
}
