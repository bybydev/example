import AppFoundation
import JobQueue
import SwiftUI

/// Compact Spokio-style status row. The enclosing row owns navigation/actions.
struct ProcessingQueueRow: View {
    @Environment(\.appFoundationTheme) private var theme
    let entry: ProcessingEntry
    let title: String
    let detail: String
    let paused: Bool

    private var timestamp: Date {
        if entry.record.status.isTerminal {
            return entry.record.completedAt ?? entry.record.updatedAt
        }
        if entry.processing {
            return entry.record.startedAt ?? entry.record.createdAt
        }
        return entry.record.createdAt
    }

    private var tint: Color {
        if paused && !entry.record.status.isTerminal { return .orange }
        switch entry.record.status {
        case .completed: return .green
        case .failed, .unrecoverable: return .red
        case .cancelled, .pausing, .cancelling: return .orange
        case .pending: return .secondary
        case .processing: return theme.accentColor
        }
    }
    private var icon: String {
        if paused && !entry.record.status.isTerminal { return "pause.circle.fill" }
        switch entry.record.status {
        case .pending: return "clock"
        case .processing: return "waveform"
        case .completed: return "checkmark.circle.fill"
        case .failed, .unrecoverable: return "exclamationmark.circle.fill"
        case .cancelled, .cancelling: return "xmark.circle"
        case .pausing: return "pause.circle"
        }
    }
    private var status: String {
        if paused && !entry.record.status.isTerminal { return "Paused" }
        if entry.record.status == .processing { return "Processing" }
        return entry.statusTitle
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.body.weight(.semibold))
                .foregroundStyle(tint).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    Text(status).font(.caption.weight(.semibold)).foregroundStyle(tint)
                    Text("·").foregroundStyle(.tertiary)
                    Text(timestamp, style: .relative)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                progress
                if let error = entry.record.error,
                   entry.record.status == .failed || entry.record.status == .unrecoverable {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var progress: some View {
        if let fraction = entry.fraction {
            HStack(spacing: 8) {
                ProgressView(value: fraction).accessibilityLabel("Job progress")
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            if let message = entry.progress?.message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        } else if entry.processing && !paused {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(entry.progress?.message ?? entry.statusTitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        } else if entry.pending {
            Capsule().fill(Color.primary.opacity(0.06)).frame(height: 4)
        }
    }
}
