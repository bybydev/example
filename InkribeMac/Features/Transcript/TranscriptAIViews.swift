import InkribeAI
import InkribeCore
import SwiftUI

extension TranscriptAIAction {
    var displayName: String {
        switch self {
        case .clean: "Clean"
        case .polish: "Polish"
        case .summarize: "Summarize"
        case .notes: "Notes"
        case .actionItems: "Action Items"
        }
    }

    var systemImage: String {
        switch self {
        case .clean: "wand.and.stars"
        case .polish: "textformat"
        case .summarize: "text.alignleft"
        case .notes: "list.bullet.rectangle"
        case .actionItems: "checklist"
        }
    }
}

extension DerivedDocumentKind {
    var displayName: String {
        switch self {
        case .summary: "Summary"
        case .notes: "Notes"
        case .actionItems: "Action Items"
        case .cleanedCopy: "Cleaned Copy"
        case .polishedCopy: "Polished Copy"
        }
    }
}

struct TranscriptAIResultSheet: View {
    let result: TranscriptAIResult
    let onApply: (TranscriptAIApplyMode) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isApplying = false
    @State private var errorDescription: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: result.action.systemImage)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.action.displayName)
                        .font(.headline)
                    Text("Generated from revision \(result.sourceRevision)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isApplying {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(18)

            Divider()

            ScrollView {
                Text(result.content)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
            }
            .frame(minHeight: 300)

            if let errorDescription {
                Divider()
                Label(errorDescription, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }

            Divider()

            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isApplying)

                Spacer()

                if result.action.supportsEditedTextReplacement {
                    Button("Save Copy") {
                        apply(.saveDerivedDocument)
                    }
                    .disabled(isApplying)

                    Button("Replace Edited Text") {
                        apply(.replaceEditedText)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying)
                } else {
                    Button("Save to Transcript") {
                        apply(.saveDerivedDocument)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying)
                }
            }
            .padding(18)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 560)
    }

    private func apply(_ mode: TranscriptAIApplyMode) {
        guard !isApplying else { return }
        isApplying = true
        errorDescription = nil
        Task { @MainActor in
            do {
                try await onApply(mode)
                dismiss()
            } catch {
                errorDescription = error.localizedDescription
                isApplying = false
            }
        }
    }
}

struct TranscriptDerivedDocumentsSheet: View {
    let documents: [DerivedDocument]
    let currentRevision: Int

    @Environment(\.dismiss) private var dismiss

    private var orderedDocuments: [DerivedDocument] {
        documents.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Saved AI Results")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            if orderedDocuments.isEmpty {
                ContentUnavailableView(
                    "No Saved AI Results",
                    systemImage: "sparkles",
                    description: Text("Generate a summary, notes, action items, or save a Clean/Polish copy.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(orderedDocuments) { document in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Text(document.kind.displayName)
                                        .font(.headline)
                                    if document.sourceRevision != currentRevision {
                                        Text("Older revision")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    Spacer()
                                    Text(document.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text(document.content)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)

                                Text("Source revision \(document.sourceRevision)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(14)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 440, idealHeight: 560)
    }
}

func transcriptAIProgressLabel(_ progress: TranscriptAIProgress?) -> String {
    guard let progress else { return "Preparing…" }
    switch progress.phase {
    case .preparing:
        return "Preparing…"
    case .transforming(let chunk, let totalChunks):
        return totalChunks == 1 ? "Generating…" : "Chunk \(chunk)/\(totalChunks)"
    case .merging(let pass, let chunk, let totalChunks):
        return totalChunks == 1
            ? "Merging pass \(pass)…"
            : "Merging \(chunk)/\(totalChunks) · pass \(pass)"
    case .finishing:
        return "Finishing…"
    }
}
