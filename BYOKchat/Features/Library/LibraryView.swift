import AppFoundation
import BYOKchatProviderCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// First-class library of explicitly saved files. Entries live independently
/// of chats; provenance rows offer a jump back to their source message.
struct LibraryView: View {
  let library: LibraryManagementModel
  let chats: ChatManagementModel
  var openSidebar: () -> Void = {}
  /// Opens the conversation an entry was saved from.
  var openSourceChat: (LibraryEntry) -> Void = { _ in }

  @Environment(\.appFoundationTheme) private var theme
  @Environment(BYOKToastCenter.self) private var toastCenter
  @State private var viewerPresentation: LibraryViewerPresentation?
  @State private var activeViewerTempDirectory: URL?
  @State private var quickLookPresentation: LibraryQuickLookPresentation?
  @State private var loadingEntryID: LibraryEntryID?
  @State private var openRequestID = UUID()
  @State private var renameTarget: LibraryEntry?
  @State private var renameText = ""
  @State private var deleteTargets: Set<LibraryEntryID> = []
  @State private var photoPickerItems: [PhotosPickerItem] = []
  @State private var isPhotoPickerPresented = false
  @State private var isFileImporterPresented = false
  @State private var activeImportCount = 0
  @State private var searchText = ""
  @State private var kindFilter: KindFilter = .all
  @State private var sourceFilter: SourceFilter = .all
  @State private var isInSelectMode = false
  @State private var selectedEntryIDs: Set<LibraryEntryID> = []
  @State private var sharePayload: LibrarySharePayload?
  @State private var activeShareTempDirectory: URL?

  private enum KindFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case images = "Images"
    case files = "Files"

    var id: String { rawValue }

    func matches(_ entry: LibraryEntry) -> Bool {
      switch self {
      case .all: true
      case .images: entry.isImage
      case .files: !entry.isImage
      }
    }
  }

  /// Entries are references; their source says which view saved them here.
  private enum SourceFilter: String, CaseIterable, Identifiable {
    case all = "All Sources"
    case manual = "Saved"
    case chats = "From Chats"
    case projects = "Project Files"

    var id: String { rawValue }

    func matches(_ entry: LibraryEntry) -> Bool {
      switch self {
      case .all:
        return true
      case .manual:
        return entry.source == .manual
      case .chats:
        if case .chat = entry.source { return true }
        return false
      case .projects:
        if case .project = entry.source { return true }
        return false
      }
    }
  }

  var body: some View {
    contentWithSheets
      .alert("Rename File", isPresented: isRenameAlertPresented) {
        TextField("Filename", text: $renameText)
        Button("Cancel", role: .cancel) { renameTarget = nil }
        Button("Save") {
          guard let target = renameTarget, canSaveRename else { return }
          let updatedName = trimmedRenameText
          renameTarget = nil
          Task { await library.rename(target.id, filename: updatedName) }
        }
        .disabled(!canSaveRename)
      } message: {
        if let message = renameAlertMessage {
          Text(message)
        }
      }
      .confirmationDialog(
        deleteTargets.count == 1 ? "Delete file?" : "Delete \(deleteTargets.count) files?",
        isPresented: isDeleteConfirmationPresented,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          let targets = deleteTargets
          deleteTargets = []
          if isInSelectMode { exitSelectMode() }
          Task { await library.deleteEntries(targets) }
        }
        Button("Cancel", role: .cancel) { deleteTargets = [] }
      } message: {
        Text(deleteMessage)
      }
      .alert("Library Error", isPresented: isErrorAlertPresented) {
        Button("OK") { library.errorMessage = nil }
      } message: {
        Text(library.errorMessage ?? "Unknown error")
      }
  }

  private var mainContent: some View {
    Group {
      if library.entries.isEmpty {
        emptyState
      } else if visibleEntries.isEmpty {
        noResultsState
      } else {
        entryList
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle(navigationTitleText)
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search files")
    .toolbar { libraryToolbar }
  }

  private var contentWithImportersAndObservers: some View {
    mainContent
      .photosPicker(
        isPresented: $isPhotoPickerPresented,
        selection: $photoPickerItems,
        matching: .images
      )
      .fileImporter(
        isPresented: $isFileImporterPresented,
        allowedContentTypes: [.item],
        allowsMultipleSelection: true
      ) { result in
        handleFileImport(result)
      }
      .onChange(of: photoPickerItems) { _, items in
        importPhotos(items)
      }
      .onChange(of: visibleEntryIDs) { _, ids in
        selectedEntryIDs.formIntersection(ids)
      }
      .onChange(of: library.entries.isEmpty) { _, isEmpty in
        handleEntriesEmptyChange(isEmpty)
      }
      .onChange(of: hasProjectEntries) { _, hasProjects in
        handleHasProjectEntriesChange(hasProjects)
      }
      .onDisappear {
        if viewerPresentation == nil {
          cleanupViewerTempDirectory()
        }
        if sharePayload == nil {
          cleanupShareTempDirectory()
        }
      }
  }

  private var contentWithSheets: some View {
    contentWithImportersAndObservers
      .sheet(item: $viewerPresentation, onDismiss: {
        cleanupViewerTempDirectory()
      }) { presentation in
        LibraryImageViewerView(
          entry: presentation.entry,
          image: presentation.image,
          shareFileURL: presentation.shareFileURL,
          onSaveToPhotos: {
            do {
              try await LibraryPhotoWriter.save(presentation.image)
            } catch {
              BYOKAppAnalytics.reportError("library_export_failed", component: "library")
              throw error
            }
          }
        )
      }
      .sheet(item: $quickLookPresentation) { presentation in
        LibraryQuickLookView(files: presentation.files) {
          quickLookPresentation = nil
        }
      }
      .sheet(item: $sharePayload, onDismiss: {
        cleanupShareTempDirectory()
      }) { payload in
        ActivityShareSheet(items: [payload.fileURL])
          .ignoresSafeArea()
      }
  }

  @ToolbarContentBuilder
  private var libraryToolbar: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      if isInSelectMode {
        Button("Cancel") { exitSelectMode() }
      } else {
        Button("Open Sidebar", systemImage: "text.alignleft", action: openSidebar)
          .labelStyle(.iconOnly)
          .accessibilityLabel("Open sidebar")
      }
    }
    ToolbarItemGroup(placement: .primaryAction) {
      if isInSelectMode {
        Button(allSelected ? "Deselect All" : "Select All") { toggleSelectAll() }
          .disabled(visibleEntries.isEmpty)

        Button("Delete", systemImage: "trash", role: .destructive) {
          requestDelete(selectedEntryIDs)
        }
        .disabled(selectedEntryIDs.isEmpty)
      } else {
        if !visibleEntries.isEmpty {
          Button("Select") { enterSelectMode() }
        }

        if !library.entries.isEmpty {
          kindFilterMenu
        }

        if activeImportCount > 0 {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Importing files")
        } else {
          Menu {
            Button("Photo", systemImage: "photo") { isPhotoPickerPresented = true }
            Button("File", systemImage: "doc") { isFileImporterPresented = true }
          } label: {
            Image(systemName: "plus")
              .font(.system(size: 17, weight: .semibold))
          }
          .accessibilityLabel("Save a file to the library")
        }
      }
    }
  }

  private var isRenameAlertPresented: Binding<Bool> {
    Binding(
      get: { renameTarget != nil },
      set: { if !$0 { renameTarget = nil } }
    )
  }

  private var isDeleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { !deleteTargets.isEmpty },
      set: { if !$0 { deleteTargets = [] } }
    )
  }

  private var isErrorAlertPresented: Binding<Bool> {
    Binding(
      get: { library.errorMessage != nil },
      set: { if !$0 { library.errorMessage = nil } }
    )
  }

  private func handleEntriesEmptyChange(_ isEmpty: Bool) {
    guard isEmpty else { return }
    if isInSelectMode { exitSelectMode() }
    kindFilter = .all
    sourceFilter = .all
  }

  private func handleHasProjectEntriesChange(_ hasProjects: Bool) {
    if !hasProjects && sourceFilter == .projects {
      sourceFilter = .all
    }
  }

  private var navigationTitleText: String {
    guard isInSelectMode else { return "Library" }
    return selectedEntryIDs.isEmpty ? "Select Items" : "\(selectedEntryIDs.count) Selected"
  }

  private var trimmedSearchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var hasActiveFilters: Bool {
    kindFilter != .all || sourceFilter != .all
  }

  private var isFilteredOrSearching: Bool {
    hasActiveFilters || !trimmedSearchQuery.isEmpty
  }

  private var hasProjectEntries: Bool {
    library.entries.contains {
      if case .project = $0.source { return true }
      return false
    }
  }

  private var availableSourceFilters: [SourceFilter] {
    SourceFilter.allCases.filter { filter in
      filter != .projects || hasProjectEntries || sourceFilter == .projects
    }
  }

  private var activeFilterDescription: String {
    var parts: [String] = []
    if kindFilter != .all { parts.append(kindFilter.rawValue) }
    if sourceFilter != .all { parts.append(sourceFilter.rawValue) }
    return parts.isEmpty ? "All items" : parts.joined(separator: ", ")
  }

  private var trimmedRenameText: String {
    renameText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSaveRename: Bool {
    guard let target = renameTarget else { return false }
    let trimmed = trimmedRenameText
    guard !trimmed.isEmpty, trimmed != target.filename else { return false }
    return !trimmed.contains("/") && !trimmed.contains("\0") && trimmed != "." && trimmed != ".."
  }

  private var renameAlertMessage: String? {
    guard let target = renameTarget else { return nil }
    let trimmed = trimmedRenameText
    if trimmed.contains("/") || trimmed == "." || trimmed == ".." {
      return "Filenames cannot contain '/'."
    }
    let originalExt = (target.filename as NSString).pathExtension
    let newExt = (trimmed as NSString).pathExtension
    if !trimmed.isEmpty && !originalExt.isEmpty && newExt.isEmpty {
      return "Removing the .\(originalExt) extension may prevent previews from opening."
    }
    return nil
  }

  private var deleteMessage: String {
    if deleteTargets.count == 1,
      let target = library.entries.first(where: { $0.id == deleteTargets.first })
    {
      return "\(target.filename) will be removed from your library. Chats are unaffected."
    }
    return "\(deleteTargets.count) files will be removed from your library. Chats are unaffected."
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "Library is Empty",
      systemImage: "books.vertical",
      description: Text("Save images and documents from chats, or add them with +.")
    )
  }

  private var noResultsDescriptor: (title: String, systemImage: String, description: String) {
    if !trimmedSearchQuery.isEmpty {
      return (
        "No Matches",
        "magnifyingglass",
        hasActiveFilters
          ? "Try a different search or clear the active filter."
          : "Try a different filename or chat title."
      )
    }
    switch (kindFilter, sourceFilter) {
    case (.images, .all):
      return ("No Images", "photo", "Save images from chats or add them with +.")
    case (.images, .manual):
      return ("No Saved Images", "photo", "No images added directly to the library yet.")
    case (.images, .chats):
      return ("No Chat Images", "photo", "No images saved from chats yet.")
    case (.images, .projects):
      return ("No Project Images", "photo", "No images from projects in the library.")
    case (.files, .all):
      return ("No Files", "doc", "Save documents from chats or add them with +.")
    case (.files, .manual):
      return ("No Saved Files", "doc", "No files added directly to the library yet.")
    case (.files, .chats):
      return ("No Chat Files", "doc", "No files saved from chats yet.")
    case (.files, .projects):
      return ("No Project Files", "doc", "No project files in the library.")
    case (.all, .manual):
      return ("No Saved Items", "books.vertical", "Add photos or files directly with +.")
    case (.all, .chats):
      return ("No Items from Chats", "bubble.left", "Save attachments or responses from a chat to see them here.")
    case (.all, .projects):
      return ("No Project Files", "folder", "No project files in the library.")
    case (.all, .all):
      return ("No Matches", "magnifyingglass", "Nothing matches the current filter.")
    }
  }

  private var noResultsState: some View {
    let descriptor = noResultsDescriptor
    return ContentUnavailableView {
      Label(descriptor.title, systemImage: descriptor.systemImage)
    } description: {
      Text(descriptor.description)
    } actions: {
      if isFilteredOrSearching {
        Button(hasActiveFilters && !trimmedSearchQuery.isEmpty ? "Clear Search & Filters" : hasActiveFilters ? "Clear Filters" : "Clear Search") {
          clearSearchAndFilters()
        }
        .buttonStyle(.bordered)
      }
    }
  }

  private func clearSearchAndFilters() {
    searchText = ""
    kindFilter = .all
    sourceFilter = .all
  }

  private var kindFilterMenu: some View {
    Menu {
      Picker("Kind", selection: $kindFilter) {
        ForEach(KindFilter.allCases) { filter in
          Text(filter.rawValue).tag(filter)
        }
      }
      Picker("Source", selection: $sourceFilter) {
        ForEach(availableSourceFilters) { filter in
          Text(filter.rawValue).tag(filter)
        }
      }
      if hasActiveFilters {
        Divider()
        Button("Reset Filters", role: .destructive) {
          kindFilter = .all
          sourceFilter = .all
        }
      }
    } label: {
      Image(
        systemName: hasActiveFilters
          ? "line.3.horizontal.decrease.circle.fill"
          : "line.3.horizontal.decrease.circle"
      )
      .font(.system(size: 17, weight: .semibold))
    }
    .accessibilityLabel("Filter files")
    .accessibilityValue(activeFilterDescription)
  }

  /// Entries surviving both filters and search; drives sections, select-all,
  /// and the no-results branch.
  private var visibleEntries: [LibraryEntry] {
    var result = library.entries
    if kindFilter != .all {
      result = result.filter { kindFilter.matches($0) }
    }
    if sourceFilter != .all {
      result = result.filter { sourceFilter.matches($0) }
    }
    let query = trimmedSearchQuery
    guard !query.isEmpty else { return result }
    return result.filter { entry in
      entry.filename.localizedCaseInsensitiveContains(query)
        || sourceChatTitle(for: entry)?.localizedCaseInsensitiveContains(query) == true
    }
  }

  private var visibleEntryIDs: Set<LibraryEntryID> {
    Set(visibleEntries.map(\.id))
  }

  private func hasSourceChat(for entry: LibraryEntry) -> Bool {
    guard case .chat(let conversationID, _) = entry.source else { return false }
    return chats.hasConversation(conversationID)
  }

  private func sourceChatTitle(for entry: LibraryEntry) -> String? {
    guard case .chat(let conversationID, _) = entry.source else { return nil }
    return chats.summary(conversationID)?.title
  }

  private var allSelected: Bool {
    !visibleEntries.isEmpty && visibleEntries.allSatisfy { selectedEntryIDs.contains($0.id) }
  }

  // MARK: - Selection

  private func enterSelectMode() {
    isInSelectMode = true
    selectedEntryIDs = []
  }

  private func exitSelectMode() {
    isInSelectMode = false
    selectedEntryIDs = []
  }

  private func toggleSelection(_ id: LibraryEntryID) {
    if !selectedEntryIDs.insert(id).inserted {
      selectedEntryIDs.remove(id)
    }
  }

  private func toggleSelectAll() {
    if allSelected {
      selectedEntryIDs.removeAll()
    } else {
      selectedEntryIDs = Set(visibleEntries.map(\.id))
    }
  }

  private func requestDelete(_ ids: Set<LibraryEntryID>) {
    let valid = ids.intersection(Set(library.entries.map(\.id)))
    guard !valid.isEmpty else { return }
    deleteTargets = valid
  }

  private var storageSummary: some View {
    let displayed = visibleEntries
    let totalBytes = displayed.reduce(0) { $0 + $1.byteCount }
    let formattedBytes = ByteCountFormatter.string(
      fromByteCount: Int64(totalBytes),
      countStyle: .file
    )
    let summaryText: String
    if isFilteredOrSearching {
      let totalCount = library.entries.count
      summaryText = "\(displayed.count) of \(totalCount) item\(totalCount == 1 ? "" : "s") · \(formattedBytes)"
    } else {
      let count = displayed.count
      summaryText = "\(count) item\(count == 1 ? "" : "s") · \(formattedBytes)"
    }
    return HStack(spacing: 8) {
      Text(summaryText)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.secondaryForegroundColor)
        .lineLimit(1)

      if isFilteredOrSearching {
        Spacer(minLength: 8)
        Button("Clear") {
          clearSearchAndFilters()
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.accentColor)
        .buttonStyle(.plain)
      }
    }
  }

  private var entryList: some View {
    List {
      storageSummary
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)

      ForEach(LibraryDateGrouper.sections(for: visibleEntries), id: \.title) { section in
        Section(section.title) {
          ForEach(section.entries) { entry in
            row(entry)
          }
        }
      }
    }
    .listStyle(.plain)
    .listRowSeparatorTint(theme.borderColor)
  }

  /// Select mode swaps open-for-tap into toggle-selection and drops the
  /// context menu and swipe actions.
  private func row(_ entry: LibraryEntry) -> some View {
    Group {
      if isInSelectMode {
        let isSelected = selectedEntryIDs.contains(entry.id)
        Button {
          toggleSelection(entry.id)
        } label: {
          rowContent(entry, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
      } else {
        Button {
          open(entry)
        } label: {
          rowContent(entry, isSelected: nil)
        }
        .buttonStyle(.plain)
        .contextMenu { contextActions(entry) }
        .swipeActions(edge: .trailing) {
          Button("Delete", systemImage: "trash", role: .destructive) {
            requestDelete([entry.id])
          }
        }
      }
    }
    .listRowBackground(Color.clear)
  }

  @ViewBuilder
  private func rowContent(_ entry: LibraryEntry, isSelected: Bool?) -> some View {
    HStack(spacing: 12) {
      if let isSelected {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 20))
          .foregroundStyle(isSelected ? theme.accentColor : theme.secondaryForegroundColor)
          .symbolRenderingMode(.hierarchical)
      }

      LibraryEntryThumbnailView(entry: entry, library: library)

      VStack(alignment: .leading, spacing: 3) {
        Text(entry.filename)
          .font(.body.weight(.medium))
          .foregroundStyle(theme.primaryForegroundColor)
          .lineLimit(1)
        Text(subtitle(for: entry))
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      if loadingEntryID == entry.id {
        ProgressView()
          .controlSize(.small)
      } else {
        Text(entry.createdAt, format: .dateTime.month(.abbreviated).day())
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private func contextActions(_ entry: LibraryEntry) -> some View {
    Button {
      Task { await share(entry) }
    } label: {
      Label("Share", systemImage: "square.and.arrow.up")
    }
    Button("Preview", systemImage: "eye") { open(entry) }
    if entry.isImage {
      Button("Save Image", systemImage: "square.and.arrow.down") {
        saveImageToPhotos(entry)
      }
    }
    if hasSourceChat(for: entry) {
      Button("Open Source Chat", systemImage: "bubble.left") {
        openSourceChat(entry)
      }
    }
    Button("Rename", systemImage: "pencil") {
      renameTarget = entry
      renameText = entry.filename
    }
    Button("Delete", systemImage: "trash", role: .destructive) {
      requestDelete([entry.id])
    }
  }

  private func subtitle(for entry: LibraryEntry) -> String {
    switch entry.source {
    case .chat:
      if let title = sourceChatTitle(for: entry) {
        return "\(title) · \(entry.byteCountText)"
      }
      return "Deleted Chat · \(entry.byteCountText)"
    case .project:
      return entry.byteCountText
    case .manual:
      return entry.byteCountText
    }
  }

  // MARK: - Actions

  private func open(_ entry: LibraryEntry) {
    let requestID = UUID()
    openRequestID = requestID
    loadingEntryID = entry.id

    Task { @MainActor in
      defer {
        if openRequestID == requestID {
          loadingEntryID = nil
        }
      }
      guard let data = await library.data(for: entry), !data.isEmpty else {
        guard openRequestID == requestID else { return }
        library.errorMessage = "This file could not be loaded."
        return
      }
      guard openRequestID == requestID else { return }

      if entry.isImage {
        let decodedImage = await Task.detached(priority: .userInitiated) {
          UIImage(data: data)
        }.value
        guard openRequestID == requestID else { return }
        if let decodedImage {
          let filename = entry.filename
          let materialized = await Task.detached(priority: .userInitiated) {
            try? LibraryTempFileSupport.materializeTempFile(
              directoryPrefix: "LibraryViewer",
              filename: filename,
              data: data
            )
          }.value
          guard openRequestID == requestID else {
            if let directory = materialized?.directory {
              LibraryTempFileSupport.cleanupDirectory(directory)
            }
            return
          }
          cleanupViewerTempDirectory()
          activeViewerTempDirectory = materialized?.directory
          viewerPresentation = LibraryViewerPresentation(
            entry: entry,
            image: decodedImage,
            shareFileURL: materialized?.fileURL
          )
          return
        }
      }

      quickLookPresentation = LibraryQuickLookPresentation(
        files: [LibraryQuickLookItem(id: entry.id.rawValue, filename: entry.filename, data: data)]
      )
    }
  }

  private func saveImageToPhotos(_ entry: LibraryEntry) {
    Task { @MainActor in
      guard let data = await library.data(for: entry), !data.isEmpty else {
        library.errorMessage = "This image could not be read."
        return
      }
      let decodedImage = await Task.detached(priority: .userInitiated) {
        UIImage(data: data)
      }.value
      guard let decodedImage else {
        library.errorMessage = "This image could not be read."
        return
      }
      do {
        try await LibraryPhotoWriter.save(decodedImage)
        toastCenter.success("Saved to Photos")
      } catch {
        BYOKAppAnalytics.reportError("library_export_failed", component: "library")
        toastCenter.dismiss()
        library.errorMessage = error.localizedDescription
      }
    }
  }

  private func share(_ entry: LibraryEntry) async {
    guard let data = await library.data(for: entry), !data.isEmpty else {
      library.errorMessage = "This file could not be loaded."
      return
    }
    let filename = entry.filename
    do {
      let materialized = try await Task.detached(priority: .userInitiated) {
        try LibraryTempFileSupport.materializeTempFile(
          directoryPrefix: "LibraryShares",
          filename: filename,
          data: data
        )
      }.value
      cleanupShareTempDirectory()
      activeShareTempDirectory = materialized.directory
      sharePayload = LibrarySharePayload(entryID: entry.id, fileURL: materialized.fileURL)
    } catch {
      BYOKAppAnalytics.reportError("library_share_failed", component: "library")
      library.errorMessage = "This file could not be prepared for sharing."
    }
  }

  private func cleanupViewerTempDirectory() {
    if let directory = activeViewerTempDirectory {
      LibraryTempFileSupport.cleanupDirectory(directory)
      activeViewerTempDirectory = nil
    }
  }

  private func cleanupShareTempDirectory() {
    if let directory = activeShareTempDirectory {
      LibraryTempFileSupport.cleanupDirectory(directory)
      activeShareTempDirectory = nil
    }
  }

  private func importPhotos(_ items: [PhotosPickerItem]) {
    guard !items.isEmpty else { return }
    photoPickerItems = []

    Task { @MainActor in
      activeImportCount += 1
      defer { activeImportCount -= 1 }

      let stamp = LibraryImportSupport.importStamp()
      var batchIndex = 0
      var addedEntries: [LibraryEntry] = []
      var failures: [String] = []

      for item in items {
        do {
          guard let rawData = try await item.loadTransferable(type: Data.self), !rawData.isEmpty else {
            failures.append("One of the selected photos could not be read.")
            continue
          }
          let prepared = await Task.detached(priority: .userInitiated) {
            LibraryImportSupport.preparedPhotoPayload(from: rawData)
          }.value
          guard let prepared else {
            failures.append("One of the selected photos could not be decoded.")
            continue
          }
          batchIndex += 1
          let filename = LibraryImportSupport.importFilename(
            stamp: stamp,
            index: batchIndex,
            fileExtension: prepared.fileExtension
          )
          if let entry = await library.add(
            filename: filename,
            mimeType: prepared.mimeType,
            data: prepared.data,
            onError: { error in
              failures.append(error.localizedDescription)
            }
          ) {
            addedEntries.append(entry)
          }
        } catch {
          failures.append(error.localizedDescription)
        }
      }

      finishImportBatch(addedEntries: addedEntries, failures: failures, itemLabel: "photo")
    }
  }

  private func handleFileImport(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      BYOKAppAnalytics.reportError("library_import_failed", component: "library")
      library.errorMessage = error.localizedDescription
    case .success(let urls):
      guard !urls.isEmpty else { return }
      Task { @MainActor in
        activeImportCount += 1
        defer { activeImportCount -= 1 }

        var addedEntries: [LibraryEntry] = []
        var failures: [String] = []

        for url in urls {
          do {
            let prepared = try await Task.detached(priority: .userInitiated) {
              try LibraryImportSupport.readImportedFile(at: url)
            }.value
            if let entry = await library.add(
              filename: prepared.filename,
              mimeType: prepared.mimeType,
              data: prepared.data,
              onError: { error in
                failures.append("\(prepared.filename): \(error.localizedDescription)")
              }
            ) {
              addedEntries.append(entry)
            }
          } catch {
            failures.append(error.localizedDescription)
          }
        }

        finishImportBatch(addedEntries: addedEntries, failures: failures, itemLabel: "file")
      }
    }
  }

  private func finishImportBatch(
    addedEntries: [LibraryEntry],
    failures: [String],
    itemLabel: String
  ) {
    if !failures.isEmpty {
      BYOKAppAnalytics.reportError("library_import_failed", component: "library")
      library.errorMessage = LibraryImportSupport.formattedBatchErrors(failures)
    }
    guard !addedEntries.isEmpty else { return }
    let visibleIDs = visibleEntryIDs
    let hiddenByFilter = isFilteredOrSearching
      && addedEntries.allSatisfy { !visibleIDs.contains($0.id) }
    let count = addedEntries.count
    let baseMessage = count == 1
      ? "Added to Library"
      : "Added \(count) \(itemLabel)s to Library"
    toastCenter.success(hiddenByFilter ? "\(baseMessage) (hidden by filter)" : baseMessage)
  }
}

/// Nonisolated helpers for off-main-thread photo/file import processing.
enum LibraryImportSupport {
  struct PreparedPhoto: Sendable {
    let data: Data
    let mimeType: String
    let fileExtension: String
  }

  struct PreparedFile: Sendable {
    let filename: String
    let mimeType: String
    let data: Data
    let isImage: Bool
  }

  /// Preserves PNG/JPEG bytes when already in a universally supported format
  /// within the size cap; normalizes HEIC/TIFF/other formats to JPEG.
  static func preparedPhotoPayload(from rawData: Data) -> PreparedPhoto? {
    if rawData.count <= LibraryStore.maxByteCount {
      if isPNG(rawData) {
        return PreparedPhoto(data: rawData, mimeType: "image/png", fileExtension: "png")
      }
      if isJPEG(rawData) {
        return PreparedPhoto(data: rawData, mimeType: "image/jpeg", fileExtension: "jpg")
      }
    }
    guard let jpeg = normalizedJPEG(from: rawData) else { return nil }
    return PreparedPhoto(data: jpeg, mimeType: "image/jpeg", fileExtension: "jpg")
  }

  /// Reads a security-scoped file off the main thread, rejecting directories,
  /// empty files (when requested), and oversized payloads.
  static func readImportedFile(
    at url: URL,
    folderErrorMessage: String = "Folders cannot be added to the Library.",
    rejectEmptyFiles: Bool = false
  ) throws -> PreparedFile {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }

    let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey])
    if values.isDirectory == true {
      throw ProviderError.invalidRequest(folderErrorMessage)
    }
    if let fileSize = values.fileSize, fileSize > LibraryStore.maxByteCount {
      throw ProviderError.invalidRequest(
        "\(url.lastPathComponent) is larger than 20 MB."
      )
    }

    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    if rejectEmptyFiles, data.isEmpty {
      throw ProviderError.invalidRequest(
        "\(url.lastPathComponent) is empty and cannot be attached."
      )
    }
    if data.count > LibraryStore.maxByteCount {
      throw ProviderError.invalidRequest(
        "\(url.lastPathComponent) is larger than 20 MB."
      )
    }

    let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
    if type.conforms(to: .image) {
      let preservesOriginal = (type == .png || type == .jpeg || type == .gif || type == .webP)
        && data.count <= LibraryStore.maxByteCount
      if preservesOriginal {
        return PreparedFile(
          filename: url.lastPathComponent,
          mimeType: type.preferredMIMEType ?? "image/jpeg",
          data: data,
          isImage: true
        )
      }
      guard let jpeg = normalizedJPEG(from: data) else {
        throw ProviderError.invalidRequest(
          "The selected image '\(url.lastPathComponent)' could not be read."
        )
      }
      if jpeg.count > LibraryStore.maxByteCount {
        throw ProviderError.invalidRequest(
          "\(url.lastPathComponent) is larger than 20 MB."
        )
      }
      let stem = url.deletingPathExtension().lastPathComponent
      let base = stem.isEmpty ? "image" : stem
      return PreparedFile(
        filename: base + ".jpg",
        mimeType: "image/jpeg",
        data: jpeg,
        isImage: true
      )
    }
    return PreparedFile(
      filename: url.lastPathComponent,
      mimeType: type.preferredMIMEType ?? "application/octet-stream",
      data: data,
      isImage: false
    )
  }

  static func normalizedJPEG(from data: Data) -> Data? {
    guard let image = UIImage(data: data) else { return nil }
    return image.jpegData(compressionQuality: 0.9)
  }

  static func isPNG(_ data: Data) -> Bool {
    data.count >= 8 && data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  }

  static func isJPEG(_ data: Data) -> Bool {
    data.count >= 3 && data.prefix(3) == Data([0xFF, 0xD8, 0xFF])
  }

  /// Locale-independent timestamp keeps generated photo names unique after
  /// deletions and sortable.
  static func importStamp(date: Date = .now) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
    return formatter.string(from: date)
  }

  static func importFilename(stamp: String, index: Int, fileExtension: String = "jpg") -> String {
    index == 1
      ? "image-\(stamp).\(fileExtension)"
      : "image-\(stamp)-\(index).\(fileExtension)"
  }

  static func formattedBatchErrors(_ errors: [String]) -> String {
    var unique: [String] = []
    for error in errors where !unique.contains(error) {
      unique.append(error)
    }
    if unique.count <= 3 {
      return unique.joined(separator: "\n")
    }
    let head = unique.prefix(3).joined(separator: "\n")
    return "\(head)\nAnd \(unique.count - 3) more error\(unique.count - 3 == 1 ? "" : "s")."
  }
}

/// Identifiable wrappers so `sheet(item:)` can drive the viewer previews.
private struct LibrarySharePayload: Identifiable {
  let id = UUID()
  let entryID: LibraryEntryID
  let fileURL: URL
}

/// System share sheet; used instead of `ShareLink` because row sharing loads
/// bytes async before anything can be handed to the share sheet.
private struct ActivityShareSheet: UIViewControllerRepresentable {
  let items: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct LibraryViewerPresentation: Identifiable {
  let id = UUID()
  let entry: LibraryEntry
  let image: UIImage
  let shareFileURL: URL?
}

private struct LibraryQuickLookPresentation: Identifiable {
  let id = UUID()
  let files: [LibraryQuickLookItem]
}

enum LibraryDateGrouper {
  struct Section {
    let title: String
    let entries: [LibraryEntry]
  }

  static func sections(
    for entries: [LibraryEntry],
    now: Date = .now,
    calendar: Calendar = .current
  ) -> [Section] {
    var buckets: [(title: String, entries: [LibraryEntry])] = []
    var titleToIndex: [String: Int] = [:]
    let startOfToday = calendar.startOfDay(for: now)
    let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
    let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)
    let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday)

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")

    func bucketTitle(for date: Date) -> String {
      if let startOfTomorrow, date >= startOfTomorrow { return "Upcoming" }
      if calendar.isDate(date, inSameDayAs: now) { return "Today" }
      if let startOfYesterday, date >= startOfYesterday { return "Yesterday" }
      if let weekAgo, date >= weekAgo { return "Previous 7 Days" }
      return formatter.string(from: date)
    }

    for entry in entries {
      let title = bucketTitle(for: entry.createdAt)
      if let existingIndex = titleToIndex[title] {
        buckets[existingIndex].entries.append(entry)
      } else {
        titleToIndex[title] = buckets.count
        buckets.append((title, [entry]))
      }
    }
    return buckets.map { Section(title: $0.title, entries: $0.entries) }
  }
}

/// Retained across the UIKit completion callback so success is shown only
/// after Photos finishes writing, and denied access/storage failures surface.
@MainActor
private final class LibraryPhotoWriter: NSObject {
  private var continuation: CheckedContinuation<Void, any Error>?

  static func save(_ image: UIImage) async throws {
    let writer = LibraryPhotoWriter()
    defer { withExtendedLifetime(writer) {} }
    try await writer.write(image)
  }

  private func write(_ image: UIImage) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      self.continuation = continuation
      UIImageWriteToSavedPhotosAlbum(
        image,
        self,
        #selector(didSave(_:didFinishSavingWithError:contextInfo:)),
        nil
      )
    }
  }

  @objc private func didSave(
    _ image: UIImage,
    didFinishSavingWithError error: NSError?,
    contextInfo: UnsafeMutableRawPointer?
  ) {
    guard let continuation else { return }
    self.continuation = nil
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }
}
