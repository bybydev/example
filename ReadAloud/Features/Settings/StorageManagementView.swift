import Observation
import SwiftUI

@Observable
@MainActor
final class StorageManagementModel {
    private(set) var summary =
        ReadAloudStorageSummary.empty
    private(set) var isLoading = false
    private(set) var didLoad = false
    var errorMessage: String?

    private let store: ProjectStore?
    private let initializationError: String?

    init() {
        do {
            store = try ProjectStore()
            initializationError = nil
        } catch {
            store = nil
            initializationError =
                Self.message(for: error)
        }
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await refresh()
    }

    func refresh() async {
        guard let store else {
            errorMessage =
                initializationError
                ?? "Storage is unavailable."
            didLoad = true
            return
        }

        isLoading = true
        defer {
            isLoading = false
            didLoad = true
        }

        do {
            summary =
                try await store
                    .storageSummary()
            errorMessage = nil
        } catch {
            errorMessage =
                Self.message(for: error)
        }
    }

    func breakdown(
        projectID: UUID
    ) -> ProjectStorageBreakdown? {
        summary.projects.first {
            $0.projectID == projectID
        }
    }

    func clearTemporaryCache(
        projectID: UUID,
        runtimeManager:
            ProjectRuntimeManager
    ) async -> Bool {
        guard let store else {
            return false
        }

        do {
            if let runtime =
                runtimeManager
                    .runtimeIfLoaded(
                        projectID:
                            projectID
                    )
            {
                try await runtime
                    .clearTemporaryCache()
            } else {
                _ = try await store
                    .clearTemporaryCache(
                        projectID:
                            projectID
                    )
            }

            await refresh()
            return true
        } catch {
            errorMessage =
                Self.message(for: error)
            return false
        }
    }

    func clearAllTemporaryCache(
        runtimeManager:
            ProjectRuntimeManager
    ) async -> Bool {
        let projectIDs =
            summary.projects.map(
                \.projectID
            )

        for projectID in projectIDs {
            guard await clearTemporaryCache(
                projectID: projectID,
                runtimeManager:
                    runtimeManager
            ) else {
                return false
            }
        }

        return true
    }

    func clearGeneratedAudio(
        projectID: UUID,
        runtimeManager:
            ProjectRuntimeManager
    ) async -> Bool {
        guard let store else {
            return false
        }

        do {
            if let runtime =
                runtimeManager
                    .runtimeIfLoaded(
                        projectID:
                            projectID
                    )
            {
                try await runtime
                    .clearGeneratedAudio(
                        itemIDs:
                            Set(
                                runtime
                                    .itemStates
                                    .map(\.id)
                            )
                    )
            } else {
                let loaded =
                    try await store
                        .loadProject(
                            projectID:
                                projectID
                        )
                try await store
                    .clearGeneratedAudio(
                        projectID:
                            projectID,
                        itemIDs:
                            Set(
                                loaded.items
                                    .map(\.id)
                            )
                    )
            }

            await refresh()
            return true
        } catch {
            errorMessage =
                Self.message(for: error)
            return false
        }
    }

    nonisolated
    private static func message(
        for error: Error
    ) -> String {
        if let localized =
            error as? LocalizedError,
           let description =
            localized.errorDescription
        {
            return description
        }

        return String(
            describing: error
        )
    }
}

struct StorageManagementView: View {
    @Environment(ProjectRuntimeManager.self)
    private var runtimeManager

    @State private var model =
        StorageManagementModel()
    @State private var clearAllPresented =
        false

    var body: some View {
        ReadAloudThemedList {
            if model.isLoading
                && !model.didLoad
            {
                ProgressView(
                    "Calculating Storage…"
                )
            } else {
                summarySection
                projectsSection
                maintenanceSection
            }
        }
        .readAloudThemeSurface()
        .navigationTitle("Storage")
        .task {
            await model.loadIfNeeded()
        }
        .refreshable {
            await model.refresh()
        }
        .confirmationDialog(
            "Clear Temporary Cache?",
            isPresented:
                $clearAllPresented,
            titleVisibility: .visible
        ) {
            Button(
                "Clear Temporary Cache"
            ) {
                Task {
                    _ = await model
                        .clearAllTemporaryCache(
                            runtimeManager:
                                runtimeManager
                        )
                }
            }
            Button(
                "Cancel",
                role: .cancel
            ) {}
        } message: {
            Text(
                "This removes rebuildable paragraph audio cache across projects. Source files, project data, artwork, and finalized offline audio are kept."
            )
        }
        .alert(
            "Storage Error",
            isPresented: Binding(
                get: {
                    model.errorMessage
                        != nil
                },
                set: { presented in
                    if !presented {
                        model.errorMessage =
                            nil
                    }
                }
            )
        ) {
            Button(
                "OK",
                role: .cancel
            ) {
                model.errorMessage = nil
            }
        } message: {
            Text(
                model.errorMessage
                    ?? ""
            )
        }
    }

    private var summarySection:
        some View
    {
        Section("ReadAloud") {
            LabeledContent(
                "Total",
                value:
                    ReadAloudDisplay.byteCount(
                        model.summary
                            .totalBytes
                    )
            )

            if model.summary
                .unattributedBytes > 0
            {
                LabeledContent(
                    "Other",
                    value:
                        ReadAloudDisplay.byteCount(
                            model.summary
                                .unattributedBytes
                        )
                )
            }
        }
    }

    private var projectsSection:
        some View
    {
        Section("Projects") {
            if model.summary
                .projects.isEmpty
            {
                Text("No project storage yet.")
                    .foregroundStyle(
                        .secondary
                    )
            } else {
                ForEach(
                    model.summary.projects
                ) { project in
                    NavigationLink {
                        ProjectStorageManagementView(
                            projectID:
                                project.projectID,
                            model: model
                        )
                    } label: {
                        HStack {
                            Text(project.title)
                                .lineLimit(1)
                            Spacer()
                            Text(
                                ReadAloudDisplay.byteCount(
                                    project
                                        .totalBytes
                                )
                            )
                            .foregroundStyle(
                                .secondary
                            )
                        }
                    }
                }
            }
        }
    }

    private var maintenanceSection:
        some View
    {
        Section {
            Button(
                "Clear Temporary Cache"
            ) {
                clearAllPresented = true
            }
            .disabled(
                model.summary
                    .projects
                    .allSatisfy {
                        $0.temporaryCacheBytes
                            == 0
                    }
            )
        } footer: {
            Text(
                "Temporary cache is rebuildable paragraph audio. Clearing it does not remove documents or finalized offline audio."
            )
        }
    }

}

private struct ProjectStorageManagementView:
    View
{
    @Environment(ProjectRuntimeManager.self)
    private var runtimeManager

    let projectID: UUID
    let model: StorageManagementModel

    @State private var clearAudioPresented =
        false

    var body: some View {
        ReadAloudThemedList {
            if let storage =
                model.breakdown(
                    projectID: projectID
                )
            {
                ProjectStorageUsageSection(
                    storage: storage
                )

                Section {
                    Button(
                        "Clear Temporary Cache"
                    ) {
                        Task {
                            _ = await model
                                .clearTemporaryCache(
                                    projectID:
                                        projectID,
                                    runtimeManager:
                                        runtimeManager
                                )
                        }
                    }
                    .disabled(
                        storage
                            .temporaryCacheBytes
                            == 0
                    )

                    if storage
                        .generatedAudioBytes > 0
                    {
                        Button(
                            "Clear Generated Audio",
                            role: .destructive
                        ) {
                            clearAudioPresented =
                                true
                        }
                    }
                } footer: {
                    Text(
                        "Temporary cache can be rebuilt automatically. Generated audio is also recreatable, but clearing it removes Ready Offline audio until it is generated again."
                    )
                }
            } else if model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "Storage Unavailable",
                    systemImage:
                        "externaldrive.badge.exclamationmark"
                )
            }
        }
        .readAloudThemeSurface()
        .navigationTitle(
            model.breakdown(
                projectID: projectID
            )?.title ?? "Project Storage"
        )
        .navigationBarTitleDisplayMode(
            .inline
        )
        .task {
            await model.refresh()
        }
        .confirmationDialog(
            "Clear Generated Audio?",
            isPresented:
                $clearAudioPresented,
            titleVisibility: .visible
        ) {
            Button(
                "Clear Generated Audio",
                role: .destructive
            ) {
                Task {
                    _ = await model
                        .clearGeneratedAudio(
                            projectID:
                                projectID,
                            runtimeManager:
                                runtimeManager
                        )
                }
            }
            Button(
                "Cancel",
                role: .cancel
            ) {}
        } message: {
            Text(
                "Finalized offline audio for this project will be removed. The source document and reading progress remain."
            )
        }
    }

}
