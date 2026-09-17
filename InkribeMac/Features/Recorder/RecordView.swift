import InkribeAudio
import InkribeCore
import InkribeTranscription
import SwiftUI

@MainActor
struct RecordView: View {
    let appState: InkribeAppState
    let onOpenTranscript: (TranscriptID) -> Void

    @State private var selectedDeviceID: String?
    @State private var language = "auto"
    @State private var pendingTranscriptID: TranscriptID?
    @State private var errorDescription: String?
    @State private var isFinishing = false

    private var recorder: MicrophoneRecorder { appState.microphoneRecorder }
    private var queueItems: [TranscriptionQueueItem] {
        appState.transcriptionQueue?.items ?? []
    }

    private var pendingState: TranscriptionQueueItemState? {
        guard let pendingTranscriptID else { return nil }
        return queueItems.first(where: { $0.transcriptID == pendingTranscriptID })?.state
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 24) {
                Spacer(minLength: 28)

                Text(Self.formatDuration(recorder.recordedDuration))
                    .font(.system(size: 46, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                meter
                    .frame(maxWidth: 520)

                VStack(spacing: 12) {
                    devicePicker
                    TranscriptionLanguagePicker(selection: $language)
                        .disabled(recorder.state != .idle)
                }
                .frame(maxWidth: 420)

                controls

                if recorder.state == .paused {
                    Label("Recording paused", systemImage: "pause.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorDescription = errorDescription ?? recorder.lastErrorDescription {
                    Text(errorDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 480)
                }

                Spacer(minLength: 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)

            Divider()

            TranscriptionQueueListView(
                items: queueItems,
                isPaused: appState.transcriptionQueue?.isPaused ?? false,
                onPause: pauseQueue,
                onResume: resumeQueue,
                onCancel: cancelJob,
                onRetry: retryJob,
                onOpenTranscript: onOpenTranscript
            )
            .frame(width: 340)
            .padding(20)
        }
        .task {
            recorder.refreshInputDevices()
            selectDefaultDeviceIfNeeded()
        }
        .onChange(of: recorder.availableDevices) { _, _ in
            selectDefaultDeviceIfNeeded()
        }
        .onChange(of: pendingState) { _, newState in
            guard newState == .complete, let pendingTranscriptID else { return }
            self.pendingTranscriptID = nil
            recorder.resetDuration()
            onOpenTranscript(pendingTranscriptID)
        }
    }

    private var meter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(.primary.opacity(0.75))
                    .frame(width: max(4, proxy.size.width * recorder.level))
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(recorder.level * 100)) percent")
    }

    @ViewBuilder
    private var devicePicker: some View {
        if recorder.availableDevices.isEmpty {
            Text("No microphone input found")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Microphone", selection: $selectedDeviceID) {
                ForEach(recorder.availableDevices) { device in
                    Text(device.isDefault ? "\(device.name) — Default" : device.name)
                        .tag(Optional(device.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(recorder.state != .idle)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .idle:
            Button {
                Task { await startRecording() }
            } label: {
                Label("Record", systemImage: "record.circle")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isFinishing || recorder.availableDevices.isEmpty)

        case .recording:
            HStack(spacing: 12) {
                Button {
                    appState.pauseRecording()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await finishRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)

                Button("Discard", role: .destructive) {
                    Task { await discardRecording() }
                }
                .buttonStyle(.borderless)
            }
            .controlSize(.large)

        case .paused:
            HStack(spacing: 12) {
                Button {
                    appState.resumeRecording()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await finishRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)

                Button("Discard", role: .destructive) {
                    Task { await discardRecording() }
                }
                .buttonStyle(.borderless)
            }
            .controlSize(.large)
        }
    }

    private func selectDefaultDeviceIfNeeded() {
        if let selectedDeviceID,
           recorder.availableDevices.contains(where: { $0.id == selectedDeviceID }) {
            return
        }
        selectedDeviceID = recorder.availableDevices.first(where: \.isDefault)?.id
            ?? recorder.availableDevices.first?.id
    }

    private func startRecording() async {
        errorDescription = nil
        pendingTranscriptID = nil
        recorder.resetDuration()
        do {
            try await appState.startRecording(deviceID: selectedDeviceID)
        } catch {
            errorDescription = String(describing: error)
        }
    }

    private func finishRecording() async {
        guard !isFinishing else { return }
        isFinishing = true
        errorDescription = nil
        defer { isFinishing = false }

        do {
            let title = "Recording \(Date().formatted(date: .abbreviated, time: .shortened))"
            let transcriptID = try await appState.finishRecording(
                title: title,
                requestedLanguage: TranscriptionLanguagePicker.requestedLanguage(for: language)
            )
            pendingTranscriptID = transcriptID
        } catch {
            errorDescription = String(describing: error)
        }
    }

    private func discardRecording() async {
        await appState.cancelRecording()
        recorder.resetDuration()
        errorDescription = nil
    }

    private func pauseQueue() {
        do {
            try appState.transcriptionQueue?.pause()
        } catch {
            errorDescription = String(describing: error)
        }
    }

    private func resumeQueue() {
        do {
            try appState.transcriptionQueue?.resume()
        } catch {
            errorDescription = String(describing: error)
        }
    }

    private func cancelJob(_ id: UUID) {
        do {
            try appState.transcriptionQueue?.cancel(id: id)
        } catch {
            errorDescription = String(describing: error)
        }
    }

    private func retryJob(_ id: UUID) {
        do {
            try appState.transcriptionQueue?.retry(id: id)
        } catch {
            errorDescription = String(describing: error)
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
