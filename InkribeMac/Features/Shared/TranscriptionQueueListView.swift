import InkribeCore
import InkribeTranscription
import SwiftUI

struct TranscriptionQueueListView: View {
    let items: [TranscriptionQueueItem]
    let isPaused: Bool
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: (UUID) -> Void
    let onRetry: (UUID) -> Void
    let onOpenTranscript: (TranscriptID) -> Void

    private var hasActiveItems: Bool {
        items.contains { item in
            switch item.state {
            case .waiting, .transcribing, .pausing, .cancelling:
                true
            case .complete, .failed, .cancelled, .needsAttention:
                false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Transcription Queue")
                    .font(.headline)
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if hasActiveItems {
                    Button(isPaused ? "Resume" : "Pause") {
                        isPaused ? onResume() : onPause()
                    }
                    .buttonStyle(.borderless)
                }
            }

            if isPaused, hasActiveItems {
                Label("Queue paused", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                ContentUnavailableView(
                    "No queued files",
                    systemImage: "text.badge.checkmark",
                    description: Text("Imported files and recordings appear here while they are processed locally.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ item: TranscriptionQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon(for: item.state))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.transcriptID.map(shortTranscriptName) ?? "Transcription")
                        .font(.system(size: 13, weight: .medium))
                    Text(label(for: item.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                actions(for: item)
            }

            if let fraction = item.fractionCompleted,
               item.state == .transcribing || item.state == .pausing || item.state == .cancelling {
                ProgressView(value: fraction)
            }

            if let message = item.progressMessage,
               !message.isEmpty,
               item.state == .transcribing {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = item.errorDescription,
               item.state == .failed || item.state == .needsAttention {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func actions(for item: TranscriptionQueueItem) -> some View {
        switch item.state {
        case .waiting, .transcribing, .pausing:
            Button("Cancel") { onCancel(item.id) }
                .buttonStyle(.borderless)
        case .failed, .cancelled:
            Button("Retry") { onRetry(item.id) }
                .buttonStyle(.borderless)
        case .complete:
            if let transcriptID = item.transcriptID {
                Button("Open") { onOpenTranscript(transcriptID) }
                    .buttonStyle(.borderless)
            }
        case .cancelling, .needsAttention:
            EmptyView()
        }
    }

    private func shortTranscriptName(_ id: TranscriptID) -> String {
        "Transcript \(id.rawValue.uuidString.prefix(8))"
    }

    private func label(for state: TranscriptionQueueItemState) -> String {
        switch state {
        case .waiting: "Waiting"
        case .transcribing: "Transcribing"
        case .cancelling: "Cancelling"
        case .pausing: "Pausing"
        case .complete: "Complete"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .needsAttention: "Needs attention"
        }
    }

    private func icon(for state: TranscriptionQueueItemState) -> String {
        switch state {
        case .waiting: "clock"
        case .transcribing: "waveform"
        case .cancelling: "xmark.circle"
        case .pausing: "pause.circle"
        case .complete: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        case .needsAttention: "exclamationmark.triangle"
        }
    }
}
