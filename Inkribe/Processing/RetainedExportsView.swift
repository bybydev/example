import AppFoundation
import SwiftUI

/// Retained requests/results remain accessible independently of queue records
/// and project lifetime. Recovery/deletion/delivery stay in the live job detail.
struct RetainedExportsView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.appFoundationTheme) private var theme
    @Environment(\.queueProjectNavigation) private var openProject
    @State private var details: ProcessingJobKey?
    @State private var isOpeningProject = false
    private var artifacts: [ExportArtifact] {
        model.exports.artifacts.values.sorted {
            let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }
    }

    var body: some View {
        List {
            if let issue = model.exports.inventoryError {
                Section {
                    Text(issue).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    Button("Refresh files") { Task { await model.exports.refreshArtifacts() } }
                }
            }
            Section {
                if artifacts.isEmpty {
                    ContentUnavailableView("No Retained Exports", systemImage: "archivebox",
                        description: Text("Saved export requests and completed files appear here."))
                        .listRowSeparator(.hidden)
                }
                ForEach(artifacts) { artifact in
                    let key = ProcessingJobKey(kind: .export, jobID: artifact.id)
                    Button { open(key) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: artifact.profile?.format == .srt ? "doc.text" : "film")
                                .foregroundStyle(theme.accentColor).frame(width: 24)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(artifact.title).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                                Text(artifact.profile?.format.title ?? "Export").font(.subheadline).foregroundStyle(.secondary)
                                Text(artifact.issue ?? (artifact.outputURL == nil ? "Saved request" : "Completed file"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isOpeningProject || model.exports.hasUserDelivery)
                    .contextMenu { Button("Job Details", systemImage: "info.circle") { details = key } }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(theme.borderColor)
                }
            } footer: {
                Text("Removing a queue record keeps its export files here. Local storage holds up to 100 exports; save the files you need before deleting old exports.")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Retained Exports")
        .navigationBarTitleDisplayMode(.inline)
        .themedSurface()
        .queueJobDetails($details)
        .onAppear { isOpeningProject = false }
        .task { await model.exports.start(); await model.exports.refreshArtifacts() }
        .refreshable { await model.exports.refreshArtifacts() }
    }

    private func open(_ key: ProcessingJobKey) {
        guard !isOpeningProject, !model.exports.hasUserDelivery else { return }
        if let route = model.queueProjectRoute(for: key) {
            isOpeningProject = true
            openProject(route)
        }
        else { details = key }
    }
}
