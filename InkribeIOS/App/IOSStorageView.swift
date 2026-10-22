import SwiftUI

struct IOSStorageView: View {
    @Environment(IOSProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var clearCaches = false
    @State private var clearTrash = false
    @State private var selectedPending: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section("On-device usage") {
                    if let usage = model.storage {
                        usageRow("Projects and originals", usage.projectBytes)
                        usageRow("Rebuildable cache", usage.cacheBytes)
                        usageRow("Pending imports", usage.pendingBytes)
                        usageRow("Project Trash", usage.trashBytes)
                    } else {
                        ProgressView("Calculating storage…")
                    }
                }
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
                            HStack {
                                Text(item.title)
                                Spacer()
                                Button("Restore") {
                                    Task { await model.restore(item.id) }
                                }
                            }
                        }
                        Button("Empty Trash", role: .destructive) { clearTrash = true }
                    }
                }
            }
            .navigationTitle("Storage")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.refreshStorage() }
            .refreshable { await model.refreshStorage() }
            .alert("Storage problem", isPresented: Binding(
                get: { model.alertMessage != nil },
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
