import AppFoundation
import SwiftUI

/// Per-project accounting; cleanup only touches the rebuildable library thumbnail.
/// Originals, accepted captions, jobs and independent export files are never purged here.
struct ProjectStorageSection: View {
    @Environment(ProjectsModel.self) private var model
    let session: EditorSession
    @State private var usage: ProjectRepository.ProjectStorageDetails?
    @State private var error: String?
    @State private var loading = false
    @State private var clearing = false
    @State private var confirmCleanup = false
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project storage").font(.headline)
            if let usage {
                usageRow("Project files", usage.bytes.total)
                usageRow("Original media", usage.bytes.sources)
                usageRow("Captions and edits", usage.bytes.durableData)
                if usage.bytes.derivedCache > 0 { usageRow("Derived package cache", usage.bytes.derivedCache) }
                if usage.bytes.temporaryWork > 0 { usageRow("Temporary package work", usage.bytes.temporaryWork) }
                usageRow("Library thumbnail", usage.thumbnailBytes)
                Button("Clear library thumbnail", systemImage: "trash.slash") { confirmCleanup = true }
                    .frame(minHeight: 44)
                    .disabled(loading || clearing || usage.thumbnailBytes == 0)
            } else if loading { ProgressView("Calculating storage…") }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.orange)
                Button("Retry storage") { Task { await refresh() } }.disabled(loading || clearing)
            }
            Text("Clearing the thumbnail keeps your original media, captions and edits. A thumbnail is recreated when needed. Manage exported files in Export.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: session.document?.contentRevision) { await refresh() }
        .confirmationDialog("Clear this project’s library thumbnail?", isPresented: $confirmCleanup) {
            Button("Clear thumbnail", role: .destructive) {
                clearing = true
                Task {
                    defer { clearing = false }
                    do { try await model.clearProjectThumbnail(session.projectID); await refresh() }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("Original media, captions, edits and export files are kept.")
        }
    }

    private func usageRow(_ title: String, _ bytes: Int64) -> some View {
        LabeledContent(title, value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            .font(.subheadline)
    }

    private func refresh() async {
        let token = UUID()
        generation = token; loading = true
        defer { if generation == token { loading = false } }
        do {
            let value = try await ProjectRepository.shared.projectStorageDetails(session.projectID)
            guard !Task.isCancelled, generation == token else { return }
            usage = value; error = nil
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            self.error = error.localizedDescription
        }
    }
}
