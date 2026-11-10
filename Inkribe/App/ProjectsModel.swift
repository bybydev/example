import CoreMedia
import Foundation
import Observation
import Photos
import SwiftUI

struct ImportCompletion: Identifiable, Sendable {
    let id = UUID()
    let projectIDs: [UUID]
    let hasFailures: Bool
}

/// Main-actor UI state only. One ProjectRepository actor owns every project
/// transaction; this model is shared by all P1 navigation and sheets.
@MainActor
@Observable
final class ProjectsModel {
    let repository = ProjectRepository.shared
    let access: ProAccess
    let processing: ProcessingCoordinator
    let editors: EditorSessions
    var transcription: TranscriptionController { processing.transcription }
    var exports: ExportController { processing.exports }
    private let importer = MediaImporter(repository: .shared)
    private let thumbnails = ProjectThumbnails(repository: .shared)

    private(set) var allProjects: [ProjectSummary] = []
    private(set) var mutatingProjectIDs: Set<UUID> = []
    private(set) var importCompletion: ImportCompletion?
    private(set) var folders: [LibraryFolder] = []
    private(set) var placements: [UUID: LibraryProjectPlacement] = [:]
    private(set) var organizationError: String?
    private(set) var trashError: String?
    private(set) var isLoadingTrash = false
    private(set) var isUpdatingOrganization = false
    private(set) var didLoadOrganization = false
    private var organizationGeneration = 0
    private var trashGeneration = 0
    var organizationReady: Bool { didLoadOrganization && organizationError == nil && !isUpdatingOrganization }
    var isFiltering: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scope != .all }
    var selectedFolder: LibraryFolder? {
        guard case .folder(let id) = scope else { return nil }
        return folders.first { $0.id == id }
    }
    func isFavorite(_ id: UUID) -> Bool { placements[id]?.isFavorite == true }
    func folderID(for id: UUID) -> UUID? { placements[id]?.folderID }
    func projectCount(in scope: LibraryScope) -> Int {
        switch scope {
        case .all: return allProjects.count
        case .favorites: return allProjects.filter { isFavorite($0.id) }.count
        case .folder(let id): return allProjects.filter { folderID(for: $0.id) == id }.count
        case .trash: return trashed.count
        }
    }
    var projects: [ProjectSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return allProjects.filter { project in
            let matches: Bool
            switch scope {
            case .all: matches = true
            case .favorites: matches = isFavorite(project.id)
            case .folder(let id): matches = folderID(for: project.id) == id
            case .trash: matches = false
            }
            return matches && (query.isEmpty || project.title.localizedStandardContains(query))
        }.sorted { a, b in
            switch sort {
            case .dateCreated:
                if let result = sortsBefore(a.createdAt, b.createdAt) { return result }
            case .dateUpdated:
                if let result = sortsBefore(a.updatedAt, b.updatedAt) { return result }
            case .name:
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return isSortAscending ? order == .orderedAscending : order == .orderedDescending }
            case .duration:
                if let result = durationsBefore(a.duration, b.duration) { return result }
            }
            return a.id.uuidString < b.id.uuidString
        }
    }
    var visibleTrashed: [ProjectRepository.TrashedProject] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return trashed.filter { query.isEmpty || $0.title.localizedStandardContains(query) }.sorted { a, b in
            switch sort {
            case .dateCreated:
                if let result = sortsBefore(a.createdAt, b.createdAt) { return result }
            case .dateUpdated:
                if let result = sortsBefore(a.updatedAt, b.updatedAt) { return result }
            case .name:
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return isSortAscending ? order == .orderedAscending : order == .orderedDescending }
            case .duration:
                if let result = durationsBefore(a.duration, b.duration) { return result }
            }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Missing metadata sorts last in both directions; nil means a tied field.
    private func sortsBefore<Value: Comparable>(_ a: Value?, _ b: Value?) -> Bool? {
        switch (a, b) {
        case let (a?, b?): return a == b ? nil : (isSortAscending ? a < b : a > b)
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return nil
        }
    }

    private func durationsBefore(_ a: MediaTime?, _ b: MediaTime?) -> Bool? {
        switch (a, b) {
        case let (a?, b?):
            let order = CMTimeCompare(a.cmTime, b.cmTime)
            return order == 0 ? nil : (isSortAscending ? order < 0 : order > 0)
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return nil
        }
    }
    var libraryIssues: [LibraryIssue] = []
    private(set) var libraryError: String?
    private(set) var storageError: String?
    private(set) var recoveryIssue: String?
    var pendingEdits: [ProjectSaveItem] {
        editors.pending.filter { $0.saveError != nil }.map { session in
            let title = session.document?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProjectSaveItem(id: session.projectID,
                title: title?.isEmpty == false ? title! : "Untitled project",
                detail: "Couldn’t save changes. Open to try again.")
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var search = ""
    var sort = ProjectSortField(rawValue: UserDefaults.standard.string(forKey: "com.hoangbkit.inkribe.ios.library.sort") ?? "") ?? .dateUpdated {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "com.hoangbkit.inkribe.ios.library.sort") }
    }
    var isSortAscending = UserDefaults.standard.bool(forKey: "com.hoangbkit.inkribe.ios.library.sortAscending") {
        didSet { UserDefaults.standard.set(isSortAscending, forKey: "com.hoangbkit.inkribe.ios.library.sortAscending") }
    }
    var scope: LibraryScope = .all
    var cacheGeneration = 0
    private(set) var hasLoadedLibrary = false
    var isImporting = false
    private(set) var isPreparingPhotos = false
    var alertMessage: String?
    var importMessage: String?
    private(set) var selectedSources: [ImportInput] = []
    private(set) var sourceReviews: [UUID: ImportSourceReview] = [:]
    private(set) var reviewingSources: Set<UUID> = []
    var photoFailures: [PhotoMovieSelection] {
        let positions = Dictionary(uniqueKeysWithValues: selectionOrder.enumerated().map { ($0.element, $0.offset) })
        return photoEntries.values
            .filter { $0.isFailed }
            .sorted { positions[$0.id, default: Int.max] < positions[$1.id, default: Int.max] }
    }

    /// Registration order of every Files and Photos selection; drives row order.
    var sourceOrder: [UUID] { selectionOrder }
    private(set) var photoEntries: [UUID: PhotoMovieSelection] = [:]
    /// Native Photos picker presentation request for the current selection session.
    var photoPicker: PhotoPickerRequest?
    private let reviewer = ImportMediaReviewer()
    private var reviewTask: Task<Void, Never>?
    private var creationID = UUID()
    private var selectionOrder: [UUID] = []
    private var photoGeneration = UUID()
    /// Sequential materialization: parallel provider file requests contend for
    /// the Photos helper and the shared copy path, so even benign attempts
    /// cross the per-attempt watchdogs and get generation-killed mid-transfer.
    /// One video at a time keeps the full attempt budget and a high success
    /// rate; total time stays bounded because each video has its own ladder.
    private let photoLoadWindow = 1
    var canCreateProject: Bool {
        !selectedSources.isEmpty && !isImporting && !isPreparingPhotos && photoFailures.isEmpty &&
            reviewingSources.isEmpty && selectedSources.allSatisfy {
                sourceReviews[$0.id]?.kind == .video && sourceReviews[$0.id]?.metadata != nil
            }
    }
    var storage: ProjectRepository.StorageUsage?
    var trashed: [ProjectRepository.TrashedProject] = []
    var pendingStaging: [UUID] = []
    private var ownedPhotoURLs: Set<URL> = []
    private var selectionSession = UUID()
    var importSelectionID: UUID { selectionSession }
    private var importTask: Task<Void, Never>?
    private var photoTask: Task<Void, Never>?
    private var libraryGeneration = 0
    private var storageGeneration = 0
    private var thumbnailJobs: Set<UUID> = []

    init() {
        let access = ProAccess()
        self.access = access
        let coordinator = ProcessingCoordinator(access: access)
        processing = coordinator
        editors = EditorSessions(access: access, transcription: coordinator.transcription)
        // These ingress copies have no durable authority after the session
        // ends: committed projects own their originals in the repository.
        // Safe once, before new picks. Photos staging itself moved to durable
        // Application Support; sweep leftovers and the legacy tmp directory.
        PhotoMovieRequest.sweepStaleStaging()
        for name in ["InkribePhotoTransfers", "InkribeURLImports"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { alertMessage = "Temporary import files could not be cleaned up: " + error.localizedDescription }
            }
        }
    }

    func refresh() async {
        do {
            _ = try await repository.recoverCommittedStaging()
            recoveryIssue = nil
        } catch {
            recoveryIssue = "An unfinished import needs attention: " + error.localizedDescription
        }
        await refreshLibrary()
        await refreshStorage()
    }

    /// Disk snapshots refresh on actual library events. Query/filter/sort are
    /// pure projections of this cache and cannot enqueue filesystem scans.
    func refreshLibrary() async {
        libraryGeneration += 1
        let generation = libraryGeneration
        do {
            let snapshot = try await repository.list()
            guard generation == libraryGeneration else { return }
            allProjects = snapshot.projects
            libraryIssues = snapshot.issues
            libraryError = nil
            hasLoadedLibrary = true
        } catch {
            if generation == libraryGeneration { libraryError = error.localizedDescription }
        }
        await refreshOrganization()
    }

    func clearLibraryFilters() { search = ""; scope = .all }

    private func applyOrganization(_ value: LibraryOrganization) {
        folders = value.folders.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        placements = Dictionary(uniqueKeysWithValues: value.projects.map { ($0.id, $0) })
        if case .folder(let id) = scope, !folders.contains(where: { $0.id == id }) { scope = .all }
        didLoadOrganization = true
        organizationError = nil
    }

    func refreshOrganization() async {
        guard !isUpdatingOrganization else { return }
        organizationGeneration += 1
        let generation = organizationGeneration
        do {
            let value = try await repository.libraryOrganization()
            guard generation == organizationGeneration else { return }
            applyOrganization(value)
        } catch {
            if generation == organizationGeneration { organizationError = error.localizedDescription }
        }
    }

    private func updateOrganization(_ operation: () async throws -> LibraryOrganization) async -> Bool {
        guard organizationReady else {
            alertMessage = "Folders and favorites are unavailable. Your projects are kept in All. Retry loading the library."
            return false
        }
        isUpdatingOrganization = true
        organizationGeneration += 1
        defer { isUpdatingOrganization = false }
        do { applyOrganization(try await operation()); return true }
        catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func createFolder(name: String) async -> Bool {
        let id = UUID()
        let saved = await updateOrganization { try await repository.createLibraryFolder(name: name, id: id) }
        if saved { scope = .folder(id); search = "" }
        return saved
    }

    func renameFolder(_ id: UUID, to name: String) async -> Bool {
        await updateOrganization { try await repository.renameLibraryFolder(id, to: name) }
    }

    func deleteFolder(_ id: UUID) async {
        _ = await updateOrganization { try await repository.deleteLibraryFolder(id) }
    }

    func moveProjects(_ ids: [UUID], to folderID: UUID?) async -> Bool {
        guard !ids.contains(where: { mutatingProjectIDs.contains($0) }) else { return false }
        return await updateOrganization { try await repository.moveLibraryProjects(ids, to: folderID) }
    }

    func toggleFavorite(_ id: UUID) async {
        let favorite = !isFavorite(id)
        guard !mutatingProjectIDs.contains(id) else { return }
        _ = await updateOrganization { try await repository.setLibraryFavorite(id, isFavorite: favorite) }
    }

    func refreshTrash() async {
        trashGeneration += 1
        let generation = trashGeneration
        isLoadingTrash = true
        defer { if generation == trashGeneration { isLoadingTrash = false } }
        do {
            let value = try await repository.trashedProjects()
            guard generation == trashGeneration else { return }
            trashed = value; trashError = nil
        } catch {
            if generation == trashGeneration { trashError = error.localizedDescription }
        }
    }

    func prepareImport() {
        guard !isImporting, !isPreparingPhotos else { return }
        importCompletion = nil
        importMessage = nil
        creationID = UUID()
        clearSelection()
    }

    func refreshStorage() async {
        storageGeneration += 1
        let generation = storageGeneration
        do {
            let usage = try await repository.storageUsage()
            let pending = try await repository.pendingStagingIDs()
            guard generation == storageGeneration else { return }
            storage = usage; pendingStaging = pending
            storageError = nil
        } catch {
            if generation == storageGeneration { storageError = error.localizedDescription }
        }
        await refreshTrash()
    }

    func addFiles(_ urls: [URL], selectionID: UUID) {
        guard selectionID == selectionSession, !isImporting, !isPreparingPhotos else { return }
        let additions = urls.map { ImportInput(localURL: $0, origin: .files, displayName: $0.lastPathComponent) }
        selectedSources += additions
        selectionOrder += additions.map(\.id)
        reviewSources()
    }

    func moveSource(_ id: UUID, offset: Int) {
        guard !isImporting, !isPreparingPhotos, let index = selectedSources.firstIndex(where: { $0.id == id }),
              selectedSources.indices.contains(index + offset) else { return }
        selectedSources.swapAt(index, index + offset)
        selectionOrder = selectedSources.map(\.id)
    }

    func reviewSources(retry id: UUID? = nil) {
        if let id { sourceReviews.removeValue(forKey: id) }
        reviewTask?.cancel()
        let session = selectionSession
        let sources = selectedSources.filter { sourceReviews[$0.id] == nil }
        reviewingSources = Set(sources.map(\.id))
        reviewTask = Task {
            for source in sources {
                guard session == selectionSession, !Task.isCancelled else { return }
                // New Project shows bounded per-row artwork separately; AVAsset
                // thumbnail generation must never pin a review that gates Create.
                let review = await reviewer.review(source, requireVideo: true, includeThumbnail: false)
                guard session == selectionSession, !Task.isCancelled else { return }
                if selectedSources.contains(where: { $0.id == source.id }) { sourceReviews[source.id] = review }
                reviewingSources.remove(source.id)
            }
        }
    }

    func openPhotos() {
        guard !isImporting, !isPreparingPhotos, photoPicker == nil else { return }
        // Ask for library access while nothing is presented: the system dialog
        // cannot reliably come up over a dismissing full-screen picker, and the
        // loader reads the cached status afterwards.
        Task { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        photoPicker = PhotoPickerRequest(selectionID: selectionSession)
    }

    func receivePhotos(_ picks: [PhotoPick], request: PhotoPickerRequest) {
        guard photoPicker?.id == request.id else { return }
        // Retain providers in the model before dismissing the native picker.
        photoPicker = nil
        guard !isImporting, !isPreparingPhotos, selectionSession == request.selectionID else { return }
        let selections = picks.enumerated().map { index, pick in
            PhotoMovieSelection(provider: pick.provider, assetID: pick.assetID,
                name: pick.provider.suggestedName ?? "Selected video \(index + 1)")
        }
        preparePhotos(selections, selectionID: request.selectionID)
    }

    func retryPhotoPreparation(_ id: UUID) {
        guard !isImporting, !isPreparingPhotos, let entry = photoEntries[id], entry.isFailed else { return }
        preparePhotos([entry], selectionID: selectionSession)
    }

    func removePhotoFailure(_ id: UUID) {
        guard !isImporting, !isPreparingPhotos else { return }
        photoEntries[id] = nil
        selectionOrder.removeAll { $0 == id }
        reviewSources()
    }

    /// Concurrent provider loads are windowed so several originals cannot surge
    /// library reads and storage writes at once. Rows surface per-video stages,
    /// like Add clips, and each bounded request ends at loading, copying,
    /// retrying or a retryable failure instead of waiting forever.
    func preparePhotos(_ selections: [PhotoMovieSelection], selectionID: UUID) {
        guard !isImporting, !isPreparingPhotos, selectionSession == selectionID, !selections.isEmpty else { return }
        reviewTask?.cancel(); reviewTask = nil; reviewingSources = []
        let session = selectionSession
        let token = UUID(); photoGeneration = token
        isPreparingPhotos = true
        // Register every selection first so rows appear immediately, like Files,
        // and cancellation leaves unfinished selections retryable.
        for selection in selections {
            var entry = photoEntries[selection.id] ?? selection
            entry.stage = .waiting
            photoEntries[entry.id] = entry
            if !selectionOrder.contains(entry.id) { selectionOrder.append(entry.id) }
        }
        photoTask = Task {
            defer {
                if photoGeneration == token {
                    isPreparingPhotos = false; photoTask = nil
                    // A finished batch cannot leave a loading/copying row behind;
                    // finalize any leftover deterministically as retryable.
                    let leftoverIDs = photoEntries.filter { !$0.value.isFailed }.map(\.key)
                    for id in leftoverIDs {
                        photoEntries[id]?.stage = .failed("Loading did not finish. Retry or remove this video.")
                    }
                    reviewSources()
                }
            }
            var index = 0
            while index < selections.count {
                guard !Task.isCancelled, session == selectionSession, photoGeneration == token else { return }
                let chunk = Array(selections[index..<min(index + photoLoadWindow, selections.count)])
                // Its turn now: promote the queued rows this chunk will load.
                for selection in chunk { photoEntries[selection.id]?.stage = .loading }
                await withTaskGroup(of: Void.self) { group in
                    for selection in chunk {
                        // Strict Sendability bounds: only this Sendable box crosses
                        // into the child task; the provider itself stays there.
                        let load = PhotoLoad(provider: selection.provider, id: selection.id,
                            name: selection.name, assetID: selection.assetID)
                        group.addTask { await self.materialize(load, token: token) }
                    }
                }
                index += chunk.count
            }
        }
    }

    private func materialize(_ load: PhotoLoad, token: UUID) async {
        guard !Task.isCancelled, photoGeneration == token else { return }
        do {
            let file = try await PhotoMovieLoader.load(load) { [self] stage in
                guard photoGeneration == token else { return }
                advancePhotoStage(load.id, stage)
            }
            guard !Task.isCancelled, photoGeneration == token else {
                try? FileManager.default.removeItem(at: file.localURL)
                return
            }
            ownedPhotoURLs.insert(file.localURL)
            selectedSources.append(ImportInput(id: load.id, localURL: file.localURL, origin: .photos, displayName: file.displayName))
            photoEntries[load.id] = nil
            let positions = Dictionary(uniqueKeysWithValues: selectionOrder.enumerated().map { ($0.element, $0.offset) })
            selectedSources.sort { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
            // This source's duration/review starts immediately; its row draws
            // its own artwork. Later selections keep loading silently.
            reviewSources()
        } catch {
            guard photoGeneration == token else { return }
            advancePhotoStage(load.id, .failed(error.localizedDescription))
        }
    }

    private func advancePhotoStage(_ id: UUID, _ stage: PhotoMovieSelection.Stage) {
        guard var entry = photoEntries[id] else { return }
        entry.stage = stage
        photoEntries[id] = entry
    }

    func removeSource(_ id: UUID) {
        guard !isImporting, !isPreparingPhotos else { return }
        for source in selectedSources where source.id == id {
            if ownedPhotoURLs.remove(source.localURL) != nil {
                try? FileManager.default.removeItem(at: source.localURL)
            }
        }
        selectedSources.removeAll { $0.id == id }
        sourceReviews.removeValue(forKey: id)
        reviewSources()
    }

    func cancelPhotoPreparation() {
        photoGeneration = UUID()
        photoTask?.cancel(); photoTask = nil
        isPreparingPhotos = false
        for id in Array(photoEntries.keys) {
            guard var entry = photoEntries[id], !entry.isFailed else { continue }
            entry.stage = .failed("Preparation cancelled. Retry or remove this video.")
            photoEntries[id] = entry
        }
        reviewSources()
    }

    func clearSelection() {
        cancelPhotoPreparation()
        photoPicker = nil
        photoGeneration = UUID()
        photoEntries = [:]
        for url in ownedPhotoURLs { try? FileManager.default.removeItem(at: url) }
        ownedPhotoURLs.removeAll()
        selectedSources.removeAll()
        sourceReviews.removeAll(); reviewingSources.removeAll(); selectionOrder.removeAll()
        selectionSession = UUID()
        reviewTask?.cancel(); reviewTask = nil
    }

    func beginImport(preset: CanvasPreset, canvas: ProjectCanvas? = nil, title: String) {
        guard canCreateProject else { return }
        let sources = selectedSources
        let projectID = creationID
        isImporting = true; importMessage = nil; importCompletion = nil
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            do {
                let document = try await importer.importFiles(sources, projectID: projectID,
                    preset: preset, customCanvas: canvas, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title)
                let stopped = Task.isCancelled
                clearSelection()
                await refreshLibrary()
                importMessage = stopped ? "Your project was saved before cancellation. Open it below." : "Project saved."
                importCompletion = ImportCompletion(projectIDs: [document.id], hasFailures: stopped)
                Task { await generateMissingThumbnails(for: [document]); await refreshStorage() }
            } catch is CancellationError {
                importMessage = "Creation cancelled. Your selected files are kept for another attempt."
                await refresh()
            } catch {
                importMessage = error.localizedDescription
                await refresh()
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private enum ThumbnailUpdate: Equatable {
        case generated, noFrame, unchanged
    }

    private func makeThumbnail(_ id: UUID) async -> ThumbnailUpdate {
        guard thumbnailJobs.insert(id).inserted else { return .unchanged }
        defer { thumbnailJobs.remove(id) }
        do {
            let url = try await thumbnails.regenerate(projectID: id)
            return url == nil ? .noFrame : .generated
        } catch {
            return .unchanged // Derived images never turn a committed import into a failure.
        }
    }

    func generateMissingThumbnails(for documents: [ProjectDocument]) async {
        for document in documents { _ = await makeThumbnail(document.id) }
        await refreshLibrary()
    }

    func refreshAfterClipEdit(_ id: UUID) async {
        cacheGeneration += 1
        await refreshLibrary()
        await regenerateThumbnail(id)
        await refreshStorage()
    }

    func regenerateMissingThumbnail(_ id: UUID) async {
        // Publishing a missing image changes its URL in the library snapshot.
        // Keep other rows' thumbnail tasks running with their existing identities.
        guard await makeThumbnail(id) == .generated else { return }
        await refreshLibrary()
    }

    func regenerateThumbnail(_ id: UUID) async {
        guard await makeThumbnail(id) != .unchanged else { return }
        cacheGeneration += 1
        await refreshLibrary()
    }

    func rename(_ summary: ProjectSummary, to title: String) async throws {
        guard !editors.hasPending(summary.id) else { throw CaptionEditError.unsavedChanges }
        guard !transcription.isActive(summary.id), !mutatingProjectIDs.contains(summary.id) else { throw SpeechError.busy }
        mutatingProjectIDs.insert(summary.id)
        defer { mutatingProjectIDs.remove(summary.id) }
        do {
            _ = try await repository.rename(summary.id, title: title, expectedRevision: summary.contentRevision)
            await refreshLibrary()
        } catch {
            await refreshLibrary()
            throw error
        }
    }

    func duplicate(_ id: UUID) async {
        guard mutatingProjectIDs.insert(id).inserted else { return }
        defer { mutatingProjectIDs.remove(id) }
        do {
            guard !editors.hasPending(id) else { throw CaptionEditError.unsavedChanges }
            let copied = try await repository.duplicate(id)
            if organizationReady, let folder = folderID(for: id) {
                _ = await moveProjects([copied.id], to: folder)
            }
            await refresh()
            await generateMissingThumbnails(for: [copied])
        } catch { alertMessage = error.localizedDescription }
    }

    func trash(_ id: UUID) async {
        guard mutatingProjectIDs.insert(id).inserted else { return }
        defer { mutatingProjectIDs.remove(id) }
        guard transcription.persistenceError == nil else {
            alertMessage = "Resolve the transcription storage problem before moving projects to Trash."
            return
        }
        guard !editors.hasPending(id) else {
            alertMessage = "This project has changes that couldn’t be saved. Open it and try saving again before moving it to Trash."
            return
        }
        guard !transcription.isActive(id) else {
            alertMessage = "Cancel this project's transcription before moving it to Trash."
            return
        }
        do { try await repository.moveToTrash(id); await refresh() }
        catch { alertMessage = error.localizedDescription }
    }

    func restore(_ id: UUID) async {
        guard mutatingProjectIDs.insert(id).inserted else { return }
        defer { mutatingProjectIDs.remove(id) }
        do {
            try await repository.restoreFromTrash(id)
            cacheGeneration += 1
            await refresh()
        }
        catch { alertMessage = error.localizedDescription }
    }

    func permanentlyDelete(_ id: UUID) async {
        guard mutatingProjectIDs.insert(id).inserted else { return }
        defer { mutatingProjectIDs.remove(id) }
        guard transcription.persistenceError == nil, !transcription.isActive(id), !editors.hasPending(id) else {
            alertMessage = "Resolve this project's pending changes or transcription before deleting it permanently."
            return
        }
        do { try await repository.permanentlyDeleteProject(id); await refresh() }
        catch { alertMessage = error.localizedDescription; await refreshTrash() }
    }

    func clearProjectThumbnail(_ id: UUID) async throws {
        try await repository.purgeThumbnail(projectID: id)
        cacheGeneration += 1
    }

    func purgeCache() async {
        do {
            try await repository.purgeDerivedCache()
            cacheGeneration += 1
            await refresh()
        }
        catch { alertMessage = error.localizedDescription }
    }

    func emptyTrash() async {
        guard transcription.persistenceError == nil else {
            alertMessage = "Resolve the transcription storage problem before emptying Trash."
            return
        }
        do { try await repository.emptyTrash(); await refresh() }
        catch { alertMessage = error.localizedDescription }
    }

    func discardPending(_ id: UUID) async {
        do { try await repository.discardPendingImport(id: id); await refresh() }
        catch { alertMessage = error.localizedDescription }
    }

    func relink(projectID: UUID, assetID: UUID, from url: URL) async {
        do {
            try await repository.restoreMissingOriginal(projectID: projectID,
                                                       assetID: assetID, from: url)
            await refresh()
            await regenerateThumbnail(projectID)
        } catch { alertMessage = error.localizedDescription }
    }
}

struct ProjectSaveItem: Identifiable {
    let id: UUID
    let title: String
    let detail: String
}


