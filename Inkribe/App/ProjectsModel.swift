import CoreTransferable
import CoreMedia
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// PhotosPicker's URL transfers are not durable. Copy while its
/// FileRepresentation callback owns the security scope; never load movie Data.
struct PickedMovie: Transferable {
    let localURL: URL
    let displayName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("InkribePhotoTransfers", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = received.file.pathExtension
            let copy = directory.appendingPathComponent(UUID().uuidString
                + (ext.isEmpty ? ".mov" : "." + ext))
            do {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: received.file, to: copy)
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
            // The owned copy has an intentionally opaque name. Keep the
            // provider's display name separate from that storage identity.
            let name = received.file.lastPathComponent
            let stem = received.file.deletingPathExtension().lastPathComponent
            let displayName = name.isEmpty || UUID(uuidString: stem) != nil ? "Imported Video" : name
            return PickedMovie(localURL: copy, displayName: displayName)
        }
    }
}

struct PhotoPreparationFailure: Identifiable {
    let id: UUID
    let item: PhotosPickerItem
    let name: String
    var message: String
}

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
    var isLoading = false
    var isImporting = false
    private(set) var isPreparingPhotos = false
    var alertMessage: String?
    var importMessage: String?
    private(set) var selectedSources: [ImportInput] = []
    private(set) var sourceReviews: [UUID: ImportSourceReview] = [:]
    private(set) var reviewingSources: Set<UUID> = []
    private(set) var photoFailures: [PhotoPreparationFailure] = []
    private let reviewer = ImportMediaReviewer()
    private var reviewTask: Task<Void, Never>?
    private var creationID = UUID()
    private var selectionOrder: [UUID] = []
    var canCreateProject: Bool {
        !selectedSources.isEmpty && !isImporting && !isPreparingPhotos && photoFailures.isEmpty &&
            reviewingSources.isEmpty && selectedSources.allSatisfy { sourceReviews[$0.id]?.metadata != nil }
    }
    var storage: ProjectRepository.StorageUsage?
    var trashed: [ProjectRepository.TrashedProject] = []
    var pendingStaging: [UUID] = []
    private var ownedPhotoURLs: Set<URL> = []
    private var selectionSession = UUID()
    var importSelectionID: UUID { selectionSession }
    private var importTask: Task<Void, Never>?
    private var importedInSession: [UUID] = []
    private var photoTask: Task<Void, Never>?
    private var libraryGeneration = 0
    private var storageGeneration = 0
    private var thumbnailJobs: Set<UUID> = []

    init() {
        let access = ProAccess()
        self.access = access
        processing = ProcessingCoordinator(access: access)
        editors = EditorSessions(access: access)
        // These ingress copies have no durable authority: committed projects
        // own their originals in the repository. Safe once, before new picks.
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
        isLoading = true
        defer { if generation == libraryGeneration { isLoading = false } }
        do {
            let snapshot = try await repository.list()
            guard generation == libraryGeneration else { return }
            allProjects = snapshot.projects
            libraryIssues = snapshot.issues
            libraryError = nil
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
        importedInSession = []
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
                let review = await reviewer.review(source)
                guard session == selectionSession, !Task.isCancelled else { return }
                if selectedSources.contains(where: { $0.id == source.id }) { sourceReviews[source.id] = review }
                reviewingSources.remove(source.id)
            }
        }
    }

    func beginPhotoPreparation(_ items: [PhotosPickerItem]) {
        guard !isImporting, !isPreparingPhotos, !items.isEmpty else { return }
        let additions = items.enumerated().map { index, item in
            PhotoPreparationFailure(id: UUID(), item: item, name: "Selected video \(index + 1)", message: "Not prepared yet")
        }
        photoFailures.append(contentsOf: additions)
        selectionOrder += additions.map(\.id)
        preparePhotos(additions)
    }

    func retryPhotoPreparation(_ id: UUID) {
        guard !isImporting, !isPreparingPhotos, let failure = photoFailures.first(where: { $0.id == id }) else { return }
        preparePhotos([failure])
    }

    func removePhotoFailure(_ id: UUID) {
        guard !isImporting, !isPreparingPhotos else { return }
        photoFailures.removeAll { $0.id == id }
    }

    private func preparePhotos(_ items: [PhotoPreparationFailure]) {
        isPreparingPhotos = true
        let session = selectionSession
        photoTask = Task {
            defer { if session == selectionSession { isPreparingPhotos = false; photoTask = nil; reviewSources() } }
            for failure in items {
                do {
                    try Task.checkCancellation()
                    guard session == selectionSession else { return }
                    guard let file = try await failure.item.loadTransferable(type: PickedMovie.self) else {
                        throw ProjectStoreError.unsupportedMedia
                    }
                    guard session == selectionSession, !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: file.localURL)
                        return
                    }
                    ownedPhotoURLs.insert(file.localURL)
                    selectedSources.append(ImportInput(id: failure.id, localURL: file.localURL, origin: .photos, displayName: file.displayName))
                    let positions = Dictionary(uniqueKeysWithValues: selectionOrder.enumerated().map { ($0.element, $0.offset) })
                    selectedSources.sort { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
                    photoFailures.removeAll { $0.id == failure.id }
                } catch is CancellationError { return }
                catch {
                    guard session == selectionSession else { return }
                    if let index = photoFailures.firstIndex(where: { $0.id == failure.id }) {
                        photoFailures[index].message = error.localizedDescription
                    }
                }
            }
        }
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
        photoTask?.cancel(); photoTask = nil
        selectionSession = UUID()
        isPreparingPhotos = false
        reviewSources()
    }

    func clearSelection() {
        cancelPhotoPreparation()
        for url in ownedPhotoURLs { try? FileManager.default.removeItem(at: url) }
        ownedPhotoURLs.removeAll()
        selectedSources.removeAll()
        sourceReviews.removeAll(); photoFailures.removeAll(); reviewingSources.removeAll(); selectionOrder.removeAll()
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
                importedInSession = [document.id]
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

    func beginURLImport(text: String, rightsConfirmed: Bool,
                        preset: CanvasPreset, canvas: ProjectCanvas? = nil, title: String) {
        guard !isImporting, !isPreparingPhotos else { return }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else {
            alertMessage = "Enter a valid HTTPS media URL."
            return
        }
        isImporting = true
        importMessage = nil
        importCompletion = nil
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            do {
                let document = try await importer.importDirectURL(
                    url, rightsConfirmed: rightsConfirmed, preset: preset, customCanvas: canvas, title: title, projectID: creationID
                )
                importMessage = "Imported " + document.title
                clearSelection()
                await refreshLibrary()
                if Task.isCancelled { importMessage = "Import stopped. The saved project is available." }
                if !importedInSession.contains(document.id) { importedInSession.append(document.id) }
                importCompletion = ImportCompletion(projectIDs: importedInSession, hasFailures: Task.isCancelled)
                Task { await generateMissingThumbnails(for: [document]); await refreshStorage() }
            } catch is CancellationError {
                importMessage = "Download cancelled."
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private func makeThumbnail(_ id: UUID) async -> Bool {
        guard thumbnailJobs.insert(id).inserted else { return false }
        defer { thumbnailJobs.remove(id) }
        do { _ = try await thumbnails.regenerate(projectID: id); return true }
        catch { return false } // Derived images never turn a committed import into a failure.
    }

    func generateMissingThumbnails(for documents: [ProjectDocument]) async {
        for document in documents { _ = await makeThumbnail(document.id) }
        await refreshLibrary()
    }

    func regenerateThumbnail(_ id: UUID) async {
        if await makeThumbnail(id) { await refreshLibrary() }
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


