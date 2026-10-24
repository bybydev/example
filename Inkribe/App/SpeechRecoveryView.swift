import CoreMedia
import SwiftUI

/// Pre-caption recovery status. Once words publish, the transcript owns gap UI.
struct SpeechRecoveryView: View {
    let summary: SpeechRecoverySummary?
    let error: String?
    let canDiscard: Bool
    let onDiscard: () -> Void

    var body: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 8) {
                Label("Continue transcription", systemImage: "externaldrive.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                Text("\(summary.resolved) of \(summary.total) sections processed")
                    .font(.caption)
                Text(modelName(summary.modelID) + " · " + SpeechLanguage.name(summary.language ?? "auto"))
                    .font(.caption).foregroundStyle(.secondary)
                if !summary.reusableRevision {
                    Text("The project changed. The next attempt will process the full clip.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !summary.compatibleRuntime {
                    Text("The speech model changed. The next attempt will process the full clip.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Use the same model and language to continue where you left off. Captions appear as they’re ready. Your allowance is used only when transcription completes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if summary.words == 0 {
                    Text("No captions are ready yet. Try again to continue processing the audio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                unresolved(summary)
                discardButton
            }
        } else if error != nil {
            Text("Couldn’t resume transcription. Start over to try the full clip again.").font(.footnote).foregroundStyle(.secondary)
            discardButton
        }
    }

    @ViewBuilder
    private func unresolved(_ summary: SpeechRecoverySummary) -> some View {
        if !summary.unresolved.isEmpty {
            DisclosureGroup("\(summary.unresolved.count) sections to retry") {
                ForEach(summary.unresolved.prefix(20)) { range in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clip \(range.clipNumber) · \(seconds(range.source.start))–\(seconds(range.source.end)) s")
                            .monospacedDigit()
                        Text(range.reason).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if summary.unresolved.count > 20 {
                    Text("\(summary.unresolved.count - 20) additional ranges will also be retried.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
        }
    }

    private var discardButton: some View {
        Button("Start over", role: .destructive, action: onDiscard)
            .font(.footnote).disabled(!canDiscard)
    }

    private func modelName(_ id: String) -> String {
        (try? SpeechModelCatalog.descriptor(id).displayName) ?? id
    }

    private func seconds(_ time: MediaTime) -> String {
        String(format: "%.2f", CMTimeGetSeconds(time.cmTime))
    }
}
