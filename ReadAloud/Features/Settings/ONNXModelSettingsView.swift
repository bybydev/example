import AVFoundation
import SwiftUI

/// Optional offline diagnostic screen; models always ship inside the app.
struct ONNXModelSettingsView: View {
    @Environment(ProjectRuntimeManager.self) private var runtimeManager

    @State private var statuses: [ONNXResource: ONNXResourceStatus] = [:]
    @State private var checking = true
    @State private var voiceID = SpeechVoice.heart.id
    @State private var testText =
        "‘What is a Caucus-Race?’ asked Alice. ‘I’ll explain,’ replied the Dodo."
    @State private var testTask: Task<Void, Never>?
    @State private var player: AVAudioPlayer?
    @State private var message: String?
    @State private var errorMessage: String?

    private var ready: Bool {
        ONNXResource.allCases.allSatisfy { statuses[$0] == .ready }
    }

    private var readyVoiceCount: Int {
        SpeechVoice.all.filter { statuses[.voiceStyle($0.id)] == .ready }.count
    }

    private var unavailableVoices: [ONNXResource] {
        SpeechVoice.all.map { ONNXResource.voiceStyle($0.id) }.filter {
            statuses[$0] == .missing || statuses[$0] == .invalid
        }
    }

    var body: some View {
        ReadAloudThemedList {
            Section {
                if checking {
                    ProgressView("Checking bundled models…")
                } else {
                    Label(
                        ready ? "Ready for offline listening" : "Some bundled resources are unavailable",
                        systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(ready ? Color.primary : Color.red)
                }
                ForEach(ONNXResource.coreResources) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        switch statuses[item] {
                        case .ready:
                            Label("Bundled", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        case .missing:
                            Text("Missing").foregroundStyle(.red)
                        case .invalid:
                            Text("Invalid").foregroundStyle(.red)
                        case nil:
                            ProgressView()
                        }
                    }
                }
                HStack {
                    Text("Kokoro Voices")
                    Spacer()
                    Text("\(readyVoiceCount)/\(SpeechVoice.all.count) bundled")
                        .foregroundStyle(.secondary)
                }
                ForEach(unavailableVoices) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Text(statuses[item] == .missing ? "Missing" : "Invalid")
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Kokoro ONNX INT8")
            } footer: {
                Text("All speech and pronunciation models and voices are included with ReadAloud. No download or internet connection is required.")
            }

            Section {
                Picker("Voice", selection: $voiceID) {
                    ForEach(SpeechVoice.all) { voice in
                        Text("\(voice.name) · \(voice.locale)").tag(voice.id)
                    }
                }
                TextField("Test text", text: $testText, axis: .vertical)
                    .lineLimit(2...4)
                Button {
                    startTest()
                } label: {
                    Label("Test Model & Play Sample", systemImage: "play.circle")
                }
                .disabled(!ready || checking || testTask != nil ||
                          runtimeManager.hasActiveAudioWork ||
                          testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if testTask != nil {
                    ProgressView("Generating test audio…")
                    Button("Cancel Test", role: .cancel) { testTask?.cancel() }
                }
            } header: {
                Text("Offline Speech Test")
            } footer: {
                Text("Runs the English ONNX G2P and Kokoro synthesis path. Stop other playback and generation before testing.")
            }

            if let message {
                Section { Label(message, systemImage: "checkmark.circle") }
            }
            if let errorMessage {
                Section("Error") { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .readAloudThemeSurface()
        .navigationTitle("ONNX Model")
        .task { await checkAssets() }
        .onDisappear {
            testTask?.cancel()
            player?.stop()
        }
    }

    @MainActor
    private func checkAssets() async {
        checking = true
        defer { checking = false }
        for item in ONNXResource.allCases {
            do {
                statuses[item] = try await ONNXResourceStore.shared.status(item)
            } catch {
                statuses[item] = .invalid
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func startTest() {
        guard ready, testTask == nil, !runtimeManager.hasActiveAudioWork,
              let voice = SpeechVoice.all.first(where: { $0.id == voiceID }) else { return }
        player?.stop()
        player = nil
        message = nil
        errorMessage = nil
        let text = testText
        testTask = Task { @MainActor in
            defer { testTask = nil }
            let engine = KokoroONNXEngine.shared
            do {
                let result = try await engine.synthesize(
                    text: text, voice: voice, speed: 1, maxChunkSeconds: 15
                )
                try Task.checkCancellation()
                await engine.unload()
                let wav = try ProjectWAVCodec.encode(
                    samples: result.audio.samples,
                    sampleRate: result.audio.sampleRate
                )
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                let testPlayer = try AVAudioPlayer(data: wav)
                guard testPlayer.prepareToPlay(), testPlayer.play() else {
                    throw SpeechEngineError.synthesisFailed("Test audio could not start.")
                }
                player = testPlayer
                message = String(format: "Playing %.1f s · RTF %.2f",
                                 result.durationSeconds, result.realTimeFactor)
            } catch is CancellationError {
                await engine.unload()
            } catch {
                await engine.unload()
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            }
        }
    }
}
