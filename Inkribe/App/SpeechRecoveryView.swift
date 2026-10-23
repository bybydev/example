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
                Label("Saved transcription progress", systemImage: "externaldrive.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                Text("\(summary.resolved) of \(summary.total) windows saved · \(summary.words) timed text units retained")
                    .font(.caption)
                Text(modelName(summary.modelID) + " · " + SpeechLanguage.name(summary.language ?? "auto"))
                    .font(.caption).foregroundStyle(.secondary)
                if !summary.reusableRevision {
                    Text("The project changed. Retry will start fresh for the current revision.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !summary.compatibleRuntime {
                    Text("The speech model or runtime version changed. Retry will start fresh.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Retry with the same model and language to reuse saved windows. Available captions appear as windows finish, even when other ranges need retry. Incomplete work does not use your allowance.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if summary.words == 0 {
                    Text("Empty model responses will be checked again on retry; they do not prove the audio has no speech.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                unresolved(summary)
                discardButton
            }
        } else if let error {
            Text(error).font(.footnote).foregroundStyle(.red)
            discardButton
        }
    }

    @ViewBuilder
    private func unresolved(_ summary: SpeechRecoverySummary) -> some View {
        if !summary.unresolved.isEmpty {
            DisclosureGroup("\(summary.unresolved.count) unresolved source ranges") {
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
        Button("Discard saved progress", role: .destructive, action: onDiscard)
            .font(.footnote).disabled(!canDiscard)
    }

    private func modelName(_ id: String) -> String {
        (try? SpeechModelCatalog.descriptor(id).displayName) ?? id
    }

    private func seconds(_ time: MediaTime) -> String {
        String(format: "%.2f", CMTimeGetSeconds(time.cmTime))
    }
}
