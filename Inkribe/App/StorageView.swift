import AppFoundation
import SwiftUI

struct StorageView: View {
    @Environment(\.appFoundationTheme) private var theme
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var clearCaches = false
    @State private var clearTrash = false
    @State private var selectedPending: UUID?
    @State private var sheet: StorageSheet?

    var body: some View {
        NavigationStack {
            List {
                Group {
                    if let issue = model.storageError {
                        Section("Storage unavailable") {
                            Text(issue).foregroundStyle(.red).textSelection(.enabled)
                            Button("Retry storage") { Task { await model.refreshStorage() } }
                        }
                    }
                    Section("On-device usage") {
                        usageRow("Downloaded speech models", model.transcription.models.inventory.cachedBytes)
                        Button("Manage speech models") { sheet = .models }
                        if let usage = model.storage {
                            usageRow("Projects and originals", usage.projectBytes)
                            usageRow("Rebuildable cache", usage.cacheBytes)
                            usageRow("Pending imports", usage.pendingBytes)
                            usageRow("Project Trash", usage.trashBytes)
                            usageRow("Export requests and results", usage.exportBytes)
                            Button("Manage export files in Queue") { sheet = .queue }
                        } else if model.storageError == nil {
                            ProgressView("Calculating storage…")
                        }
                    }
                    projectStorageSection
                    projectStorageIssues
                    Section {
                        Button("Clear cached thumbnails", systemImage: "trash.slash") {
                            clearCaches = true
                        }
                        .disabled((model.storage?.cacheBytes ?? 0) == 0)
                    } header: {
                        Text("Safe cleanup")
                    } footer: {
                        Text("Clearing caches does not affect documents or original media.")
                    }
                    if !model.pendingStaging.isEmpty {
                        Section("Unfinished imports") {
                            ForEach(model.pendingStaging, id: \.self) { id in
                                HStack {
                                    Text(String(id.uuidString.prefix(8)))
                                        .font(.footnote.monospaced())
                                    Spacer()
                                    Button("Discard", role: .destructive) { selectedPending = id }
                                }
                            }
                        }
                    }
                    Section("Project Trash") {
                        if model.trashed.isEmpty {
                            Text("Nothing in Trash").foregroundStyle(.secondary)
                        } else {
                            ForEach(model.trashed) { item in
                                trashedProjectRow(item)
                            }
                            Button("Empty Trash", role: .destructive) { clearTrash = true }
                        }
                    }
                }
                .listRowBackground(theme.surfaceColor)
                .listRowSeparatorTint(theme.borderColor)
            }
            .navigationTitle("Storage")
            .themedSurface()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.refreshStorage(); await model.transcription.models.refresh() }
            .sheet(item: $sheet) { destination in
                switch destination {
                case .models: SpeechModelsView()
                case .queue: ProcessingQueueSheet()
                }
            }
            .refreshable { await model.refreshStorage(); await model.transcription.models.refresh() }
            .alert("Storage problem", isPresented: Binding(
                get: { sheet == nil && model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.alertMessage = nil }
            } message: {
                Text(model.alertMessage ?? "")
            }
            .confirmationDialog("Clear cached previews?", isPresented: $clearCaches) {
                Button("Clear cache", role: .destructive) {
                    Task { await model.purgeCache() }
                }
            }
            .confirmationDialog("Empty Project Trash?", isPresented: $clearTrash) {
                Button("Empty Trash", role: .destructive) {
                    Task { await model.emptyTrash() }
                }
            } message: {
                Text("Projects and original files in Trash will be permanently removed.")
            }
            .confirmationDialog("Discard unfinished import?", isPresented: Binding(
                get: { selectedPending != nil },
                set: { if !$0 { selectedPending = nil } }
            )) {
                Button("Discard", role: .destructive) {
                    guard let id = selectedPending else { return }
                    selectedPending = nil
                    Task { await model.discardPending(id) }
                }
            }
        }
    }

    @ViewBuilder
    private var projectStorageSection: some View {
        if let usage = model.storage, !usage.projects.isEmpty {
            Section {
                ForEach(usage.projects) { project in
                    DisclosureGroup {
                        usageRow("Original media", project.bytes.sources)
                        usageRow("Captions and edits", project.bytes.durableData)
                        usageRow("Derived package cache", project.bytes.derivedCache)
                        usageRow("Temporary package work", project.bytes.temporaryWork)
                    } label: {
                        HStack {
                            Text(project.title)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: project.bytes.total, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Projects")
            } footer: {
                Text("Projects keep your original media, captions, edits and transcription progress. Preview thumbnails and export files are counted separately above.")
            }
        }
    }

    private func trashedProjectRow(_ item: ProjectRepository.TrashedProject) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                if let issue = item.issue {
                    Text(issue).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Restore") {
                Task { await model.restore(item.id) }
            }
            .disabled(item.issue != nil)
        }
    }

    @ViewBuilder
    private var projectStorageIssues: some View {
        if let usage = model.storage, !usage.issues.isEmpty {
            Section("Project storage issues") {
                ForEach(usage.issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Project " + String(issue.id.uuidString.prefix(8))).font(.subheadline)
                        Text(issue.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func usageRow(_ name: String, _ bytes: Int64) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

private enum StorageSheet: String, Identifiable {
    case models, queue
    var id: Self { self }
}
