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
  @Environment(PurchaseManager.self) private var purchaseManager
  @State private var viewerEntry: LibraryEntry?
  @State private var viewerImage: UIImage?
  @State private var viewerShareData: Data?
  @State private var quickLookFiles: [(filename: String, data: Data)]?
  @State private var renameTarget: LibraryEntry?
  @State private var renameText = ""
  @State private var deleteTargets: Set<LibraryEntryID> = []
  @State private var photoPickerItems: [PhotosPickerItem] = []
  @State private var isPhotoPickerPresented = false
  @State private var isFileImporterPresented = false
  @State private var searchText = ""
  @State private var kindFilter: KindFilter = .all
  @State private var sourceFilter: SourceFilter = .all
  @State private var isInSelectMode = false
  @State private var selectedEntryIDs: Set<LibraryEntryID> = []
  @State private var sharePayload: LibrarySharePayload?
  @State private var showProUpsell = false

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
    .navigationTitle("Library")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search files")
    .toolbar {
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

          Button("Delete", systemImage: "trash", role: .destructive) {
            requestDelete(selectedEntryIDs)
          }
          .disabled(selectedEntryIDs.isEmpty)
        } else {
          if !library.entries.isEmpty {
            Button("Select") { enterSelectMode() }
          }

          kindFilterMenu

          Menu {
            Button("Photo", systemImage: "photo") { isPhotoPickerPresented = true }
            Button("File", systemImage: "doc") { isFileImporterPresented = true }
          } label: {
            Image(systemName: "plus")
              .font(.system(size: 17, weight: .semibold))
              .labelStyle(.iconOnly)
          }
          .accessibilityLabel("Save a file to the library")
        }
      }
    }
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
    .sheet(item: Binding(
      get: { viewerEntry.map { LibraryViewerPresentation(entry: $0) } },
      set: { presentation in
        if presentation == nil {
          viewerEntry = nil
          viewerImage = nil
          viewerShareData = nil
        }
      }
    )) { presentation in
      if let image = viewerImage {
        LibraryImageViewerView(
          entry: presentation.entry,
          image: image,
          shareData: { viewerShareData }
        )
      } else {
        ProgressView()
          .presentationBackground(.thinMaterial)
      }
    }
    .sheet(item: Binding(
      get: { quickLookFiles.map(LibraryQuickLookPresentation.init) },
      set: { quickLookFiles = $0?.files }
    )) { presentation in
      LibraryQuickLookView(files: presentation.files)
        .ignoresSafeArea()
    }
    .alert("Rename File", isPresented: Binding(
      get: { renameTarget != nil },
      set: { if !$0 { renameTarget = nil } }
    )) {
      TextField("Filename", text: $renameText)
      Button("Cancel", role: .cancel) { renameTarget = nil }
      Button("Save") {
        guard let target = renameTarget else { return }
        Task { await library.rename(target.id, filename: renameText) }
        renameTarget = nil
      }
    }
    .confirmationDialog(
      deleteTargets.count == 1 ? "Delete file?" : "Delete \(deleteTargets.count) files?",
      isPresented: Binding(
        get: { !deleteTargets.isEmpty },
        set: { if !$0 { deleteTargets = [] } }
      ),
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
    .sheet(item: $sharePayload) { payload in
      ActivityShareSheet(items: [Self.shareURL(for: payload)])
        .ignoresSafeArea()
    }
    .sheet(isPresented: $showProUpsell) {
      BYOKProUpsellFlow(feature: .libraryItems)
    }
    .alert(
      "Library Error",
      isPresented: Binding(
        get: { library.errorMessage != nil },
        set: { if !$0 { library.errorMessage = nil } }
      )
    ) {
      Button("OK") { library.errorMessage = nil }
    } message: {
      Text(library.errorMessage ?? "Unknown error")
    }
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

  private var noResultsState: some View {
    ContentUnavailableView {
      if searchText.isEmpty {
        Label("No \(kindFilter.rawValue)", systemImage: kindFilter == .images ? "photo" : "doc")
      } else {
        Label("No Matches", systemImage: "magnifyingglass")
      }
    } description: {
      if searchText.isEmpty {
        Text("Nothing matches the current filter.")
      } else {
        Text("Try a different name or clear the filter.")
      }
    }
  }

  private var kindFilterMenu: some View {
    Menu {
      Picker("Kind", selection: $kindFilter) {
        ForEach(KindFilter.allCases) { filter in
          Text(filter.rawValue).tag(filter)
        }
      }
      Picker("Source", selection: $sourceFilter) {
        ForEach(SourceFilter.allCases) { filter in
          Text(filter.rawValue).tag(filter)
        }
      }
    } label: {
      Image(
        systemName: kindFilter == .all && sourceFilter == .all
          ? "line.3.horizontal.decrease.circle"
          : "line.3.horizontal.decrease.circle.fill"
      )
      .font(.system(size: 17, weight: .semibold))
      .labelStyle(.iconOnly)
    }
    .accessibilityLabel("Filter files")
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
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return result }
    return result.filter { entry in
      entry.filename.localizedCaseInsensitiveContains(query)
        || sourceChatTitle(for: entry)?.localizedCaseInsensitiveContains(query) == true
    }
  }

  private func sourceChatTitle(for entry: LibraryEntry) -> String? {
    guard case .chat(let conversationID, _) = entry.source else { return nil }
    return chats.summary(conversationID)?.title ?? "Chat"
  }

  private var allSelected: Bool {
    !visibleEntries.isEmpty && selectedEntryIDs.count >= visibleEntries.count
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
    deleteTargets = ids
  }

  private var storageSummary: some View {
    let totalBytes = library.entries.reduce(0) { $0 + $1.byteCount }
    let count = library.entries.count
    return Text(
      "\(count) item\(count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))"
    )
    .font(.system(size: 13, weight: .semibold))
    .foregroundStyle(theme.secondaryForegroundColor)
  }

  private var entryList: some View {
    List {
      if searchText.isEmpty {
        storageSummary
          .frame(maxWidth: .infinity, alignment: .leading)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      }

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
        Button {
          toggleSelection(entry.id)
        } label: {
          rowContent(entry, isSelected: selectedEntryIDs.contains(entry.id))
        }
        .buttonStyle(.plain)
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

      Text(entry.createdAt, format: .dateTime.month(.abbreviated).day())
        .font(.caption2)
        .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
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
    if case .chat = entry.source {
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
      let title = sourceChatTitle(for: entry) ?? "Chat"
      return "\(title) · \(entry.byteCountText)"
    case .project:
      return entry.byteCountText
    case .manual:
      return entry.byteCountText
    }
  }

  // MARK: - Actions

  private func open(_ entry: LibraryEntry) {
    Task { @MainActor in
      guard let data = await library.data(for: entry) else { return }
      if entry.isImage, let image = UIImage(data: data) {
        viewerImage = image
        viewerShareData = data
        viewerEntry = entry
      } else {
        quickLookFiles = [(filename: entry.filename, data: data)]
      }
    }
  }

  private func saveImageToPhotos(_ entry: LibraryEntry) {
    Task { @MainActor in
      guard let data = await library.data(for: entry),
        let image = UIImage(data: data)
      else { return }
      UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }
  }

  private func share(_ entry: LibraryEntry) async {
    guard let data = await library.data(for: entry) else { return }
    sharePayload = LibrarySharePayload(entry: entry, data: data)
  }

  private func importPhotos(_ items: [PhotosPickerItem]) {
    guard !items.isEmpty else { return }
    Task { @MainActor in
      defer { photoPickerItems = [] }
      let stamp = Self.importStamp()
      var batchIndex = 0
      for item in items {
        // Free tier: fill the remaining slots, then surface the upsell once.
        guard BYOKProAccess.canCreateLibraryItem(
          currentCount: library.entries.count,
          hasPro: purchaseManager.hasPro
        ) else {
          showProUpsell = true
          break
        }
        do {
          guard let data = try await item.loadTransferable(type: Data.self),
            let jpeg = Self.normalizedJPEG(from: data)
          else { continue }
          batchIndex += 1
          _ = await library.add(
            filename: Self.importFilename(stamp: stamp, index: batchIndex),
            mimeType: "image/jpeg",
            data: jpeg,
            hasPro: purchaseManager.hasPro,
            onError: handleSaveError
          )
        } catch {
          library.errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func handleFileImport(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      library.errorMessage = error.localizedDescription
    case .success(let urls):
      Task { @MainActor in
        for url in urls {
          // Free tier: fill the remaining slots, then surface the upsell once.
          guard BYOKProAccess.canCreateLibraryItem(
            currentCount: library.entries.count,
            hasPro: purchaseManager.hasPro
          ) else {
            showProUpsell = true
            break
          }
          do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
            if let fileSize = values.fileSize, fileSize > LibraryStore.maxByteCount {
              throw ProviderError.invalidRequest(
                "\(url.lastPathComponent) is larger than 20 MB."
              )
            }
            let data = try Data(contentsOf: url)
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
            if type.conforms(to: .image),
              let jpeg = Self.normalizedJPEG(from: data)
            {
              _ = await library.add(
                filename: url.deletingPathExtension().lastPathComponent + ".jpg",
                mimeType: "image/jpeg",
                data: jpeg,
                hasPro: purchaseManager.hasPro,
                onError: handleSaveError
              )
            } else {
              _ = await library.add(
                filename: url.lastPathComponent,
                mimeType: type.preferredMIMEType ?? "application/octet-stream",
                data: data,
                hasPro: purchaseManager.hasPro,
                onError: handleSaveError
              )
            }
          } catch {
            library.errorMessage = error.localizedDescription
          }
        }
      }
    }
  }

  private func handleSaveError(_ error: Error) {
    if error is LibraryCapacityError {
      showProUpsell = true
    } else {
      library.errorMessage = error.localizedDescription
    }
  }

  /// Matches the chat composer's pick pipeline: images become JPEG so every
  /// provider adapter receives a supported encoding.
  private static func normalizedJPEG(from data: Data) -> Data? {
    guard let image = UIImage(data: data) else { return nil }
    return image.jpegData(compressionQuality: 0.9)
  }

  /// Locale-independent timestamp keeps generated photo names unique after
  /// deletions (the old entries-count scheme collided) and sortable.
  private static func importStamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
    return formatter.string(from: .now)
  }

  private static func importFilename(stamp: String, index: Int) -> String {
    index == 1 ? "image-\(stamp).jpg" : "image-\(stamp)-\(index).jpg"
  }

  /// Shares go through a temp file so the payload carries its real filename;
  /// raw `Data` items would arrive in the share sheet nameless.
  private static func shareURL(for payload: LibrarySharePayload) -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(payload.entry.id.rawValue, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(payload.entry.filename)
    try? payload.data.write(to: url, options: .atomic)
    return url
  }
}

/// Identifiable wrappers so `sheet(item:)` can drive the viewer previews.
private struct LibrarySharePayload: Identifiable {
  let entry: LibraryEntry
  let data: Data

  var id: String { entry.id.rawValue }
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

private struct LibraryViewerPresentation: Identifiable, Equatable {
  let entry: LibraryEntry
  var id: String { entry.id.rawValue }
}

private struct LibraryQuickLookPresentation: Identifiable {
  let files: [(filename: String, data: Data)]
  var id: String { files.first?.filename ?? "" }
}

enum LibraryDateGrouper {
  struct Section {
    let title: String
    let entries: [LibraryEntry]
  }

  static func sections(for entries: [LibraryEntry]) -> [Section] {
    let calendar = Calendar.current
    var buckets: [(title: String, entries: [LibraryEntry])] = []
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM yyyy"

    func bucketTitle(for date: Date) -> String? {
      if calendar.isDateInToday(date) { return "Today" }
      if calendar.isDateInYesterday(date) { return "Yesterday" }
      if let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now),
        date > weekAgo
      {
        return "Previous 7 Days"
      }
      return formatter.string(from: date)
    }

    for entry in entries {
      let title = bucketTitle(for: entry.createdAt) ?? "Earlier"
      if let lastIndex = buckets.indices.last, buckets[lastIndex].title == title {
        buckets[lastIndex].entries.append(entry)
      } else {
        buckets.append((title, [entry]))
      }
    }
    return buckets.map { Section(title: $0.title, entries: $0.entries) }
  }
}
