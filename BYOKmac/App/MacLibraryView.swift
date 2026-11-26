import AppKit
import BYOKchatProviderCore
import ImageIO
import QuickLook
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

enum MacLibraryKindFilter: String, CaseIterable, Identifiable {
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

enum MacLibrarySourceFilter: String, CaseIterable, Identifiable {
  case all = "All Sources"
  case saved = "Saved"
  case chats = "From Chats"
  case projects = "Project Files"

  var id: String { rawValue }

  var compactTitle: String {
    switch self {
    case .all: "All"
    case .saved: "Saved"
    case .chats: "Chats"
    case .projects: "Projects"
    }
  }

  func matches(_ entry: LibraryEntry) -> Bool {
    switch self {
    case .all:
      true
    case .saved:
      entry.source == .manual
    case .chats:
      if case .chat = entry.source { true } else { false }
    case .projects:
      if case .project = entry.source { true } else { false }
    }
  }
}

enum MacLibraryViewMode: String, CaseIterable, Identifiable {
  case gallery
  case list

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .gallery: "square.grid.2x2"
    case .list: "list.bullet"
    }
  }

  var title: String {
    switch self {
    case .gallery: "Gallery"
    case .list: "List"
    }
  }
}

enum MacLibraryDateGrouper {
  struct Section {
    let title: String
    let entries: [LibraryEntry]
  }

  static func sections(for entries: [LibraryEntry], now: Date = .now) -> [Section] {
    let calendar = Calendar.current
    let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
    let sorted = entries.sorted { lhs, rhs in
      if lhs.createdAt == rhs.createdAt { return lhs.filename < rhs.filename }
      return lhs.createdAt > rhs.createdAt
    }

    func title(for date: Date) -> String {
      if calendar.isDate(date, inSameDayAs: now) { return "Today" }
      if let yesterday, calendar.isDate(date, inSameDayAs: yesterday) {
        return "Yesterday"
      }
      if let weekAgo, date > weekAgo { return "Previous 7 Days" }
      return date.formatted(.dateTime.month(.wide).year())
    }

    var buckets: [(String, [LibraryEntry])] = []
    for entry in sorted {
      let bucketTitle = title(for: entry.createdAt)
      if let last = buckets.indices.last, buckets[last].0 == bucketTitle {
        buckets[last].1.append(entry)
      } else {
        buckets.append((bucketTitle, [entry]))
      }
    }
    return buckets.map { Section(title: $0.0, entries: $0.1) }
  }
}

/// Imports files and dropped images directly into the Library while preserving
/// original image formats (PNG, WebP, GIF, JPEG, HEIC, etc.) and filenames,
/// rejecting folders cleanly, and skipping invalid items without aborting valid ones.
enum MacLibraryFileImporter {
  struct ImportResult: Sendable {
    let attachments: [ChatAttachment]
    let skippedMessages: [String]
  }

  static func importURLs(
    _ urls: [URL],
    maxByteCount: Int = LibraryStore.maxByteCount
  ) async -> ImportResult {
    await Task.detached(priority: .userInitiated) {
      var attachments: [ChatAttachment] = []
      var skippedMessages: [String] = []
      attachments.reserveCapacity(urls.count)

      for url in urls {
        let access = url.startAccessingSecurityScopedResource()
        defer {
          if access { url.stopAccessingSecurityScopedResource() }
        }

        let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        do {
          let values = try url.resourceValues(
            forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey, .isRegularFileKey]
          )
          if values.isDirectory == true {
            skippedMessages.append("\(name): folders cannot be imported.")
            continue
          }
          if values.isRegularFile == false {
            skippedMessages.append("\(name): not a readable file.")
            continue
          }
          if let fileSize = values.fileSize, fileSize > maxByteCount {
            skippedMessages.append("\(name): exceeds the 20 MB limit.")
            continue
          }

          let data = try Data(contentsOf: url, options: [.mappedIfSafe])
          guard !data.isEmpty else {
            skippedMessages.append("\(name): file is empty.")
            continue
          }
          guard data.count <= maxByteCount else {
            skippedMessages.append("\(name): exceeds the 20 MB limit.")
            continue
          }

          let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
          let isImage = type.conforms(to: .image)
          let mimeType: String
          if isImage {
            mimeType = type.preferredMIMEType
              ?? MacResponseImageScanner.mimeType(for: data, filename: name)
          } else {
            mimeType = type.preferredMIMEType ?? "application/octet-stream"
          }

          attachments.append(
            ChatAttachment(
              kind: isImage ? .image : .file,
              filename: name,
              mimeType: mimeType,
              data: data
            )
          )
        } catch {
          skippedMessages.append("\(name): \(error.localizedDescription)")
        }
      }

      return ImportResult(attachments: attachments, skippedMessages: skippedMessages)
    }.value
  }

  static func importDroppedImages(
    _ images: [MacDroppedImage],
    maxByteCount: Int = LibraryStore.maxByteCount
  ) async -> ImportResult {
    await Task.detached(priority: .userInitiated) {
      var attachments: [ChatAttachment] = []
      var skippedMessages: [String] = []
      attachments.reserveCapacity(images.count)

      for (index, dropped) in images.enumerated() {
        let data = dropped.data
        let fallbackLabel = "image-\(index + 1)"
        guard !data.isEmpty else {
          skippedMessages.append("\(fallbackLabel): image is empty.")
          continue
        }
        guard data.count <= maxByteCount else {
          skippedMessages.append("\(fallbackLabel): exceeds the 20 MB limit.")
          continue
        }
        guard MacResponseImageScanner.isValidImageData(data) else {
          skippedMessages.append("\(fallbackLabel): unsupported or invalid image data.")
          continue
        }
        let mimeType = MacResponseImageScanner.mimeType(for: data, filename: "\(fallbackLabel).png")
        let ext = preferredExtension(forImageMIMEType: mimeType)
        attachments.append(
          ChatAttachment(
            kind: .image,
            filename: "\(fallbackLabel).\(ext)",
            mimeType: mimeType,
            data: data
          )
        )
      }

      return ImportResult(attachments: attachments, skippedMessages: skippedMessages)
    }.value
  }

  private static func preferredExtension(forImageMIMEType mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "image/png": "png"
    case "image/jpeg": "jpg"
    case "image/gif": "gif"
    case "image/webp": "webp"
    case "image/heic": "heic"
    case "image/tiff": "tiff"
    default: UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png"
    }
  }
}

struct MacLibraryDecodedBitmap: @unchecked Sendable {
  let cgImage: CGImage
  let pointSize: NSSize
  let byteCost: Int
}

@MainActor
final class MacLibraryThumbnailCache {
  static let shared = MacLibraryThumbnailCache()

  private let storage: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 200
    cache.totalCostLimit = 64 * 1_024 * 1_024
    return cache
  }()

  func image(forKey key: String) -> NSImage? {
    storage.object(forKey: key as NSString)
  }

  func insert(_ image: NSImage, forKey key: String, byteCost: Int) {
    storage.setObject(image, forKey: key as NSString, cost: max(1, byteCost))
  }

  nonisolated static func decodeBitmap(
    from data: Data,
    maxPixelSize: CGFloat
  ) -> MacLibraryDecodedBitmap? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let directOptions: [CFString: Any] = [
      kCGImageSourceShouldCacheImmediately: true,
    ]
    let cgImage: CGImage?
    if let direct = CGImageSourceCreateImageAtIndex(source, 0, directOptions as CFDictionary),
      CGFloat(max(direct.width, direct.height)) <= max(64, maxPixelSize * 1.5)
    {
      cgImage = direct
    } else {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maxPixelSize.rounded())),
        kCGImageSourceShouldCacheImmediately: true,
      ]
      cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        ?? CGImageSourceCreateImageAtIndex(source, 0, directOptions as CFDictionary)
    }
    guard let cgImage else { return nil }
    let byteCost = max(1, cgImage.bytesPerRow * cgImage.height)
    return MacLibraryDecodedBitmap(
      cgImage: cgImage,
      pointSize: NSSize(width: cgImage.width, height: cgImage.height),
      byteCost: byteCost
    )
  }

  nonisolated static func decodeFullImage(from data: Data) -> MacLibraryDecodedBitmap? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let maxPixelSize = max(64, min(8_192, max(width, height, 4_096)))
    let orientedOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    let fallbackOptions: [CFString: Any] = [
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, orientedOptions as CFDictionary)
        ?? CGImageSourceCreateImageAtIndex(source, 0, fallbackOptions as CFDictionary)
    else {
      return nil
    }
    let byteCost = max(1, cgImage.bytesPerRow * cgImage.height)
    return MacLibraryDecodedBitmap(
      cgImage: cgImage,
      pointSize: NSSize(width: cgImage.width, height: cgImage.height),
      byteCost: byteCost
    )
  }

  nonisolated static func imageDimensions(from data: Data) -> (width: Int, height: Int)? {
    MacResponseImageScanner.validateImageData(data)
  }

  static func fileSymbol(mimeType: String, isImage: Bool) -> String {
    if isImage { return "photo" }
    let mime = mimeType.lowercased()
    if mime.contains("pdf") { return "doc.richtext" }
    if mime.contains("json") || mime.contains("javascript") {
      return "curlybraces.square"
    }
    if mime.hasPrefix("text/") { return "doc.text" }
    return "doc"
  }
}

struct MacLibraryView: View {
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var chats: MacChatSessionModel
  let openSourceChat: (ConversationID, ChatMessageID?) -> Void
  var openSourceProject: (ProjectID) -> Void = { _ in }

  @Environment(\.macToastCenter) private var toastCenter
  @FocusState private var isSearchFocused: Bool

  @State private var selection: Set<LibraryEntryID> = []
  @State private var lastSelectedID: LibraryEntryID?
  @State private var searchText = ""
  @State private var kindFilter: MacLibraryKindFilter = .all
  @State private var sourceFilter: MacLibrarySourceFilter = .all
  @State private var viewMode: MacLibraryViewMode = .gallery
  @State private var showingInspector = false
  @State private var showingImporter = false
  @State private var renameTarget: LibraryEntry?
  @State private var deleteTargets: Set<LibraryEntryID> = []
  @State private var previewEntry: LibraryEntry?
  @State private var previewURL: URL?
  @State private var previewImage: NSImage?
  @State private var previewZoomScale: CGFloat = 1.0
  @State private var previewLoadingID: LibraryEntryID?
  @State private var showingPreview = false
  @State private var isWorking = false
  @State private var isDropTargeted = false
  @State private var shareTempDirectories: [URL] = []
  @State private var inspectorDimensions: (width: Int, height: Int)?

  private static let minPreviewZoom: CGFloat = 1.0
  private static let maxPreviewZoom: CGFloat = 5.0

  private var visibleEntries: [LibraryEntry] {
    var result = workspace.libraryEntries.filter {
      kindFilter.matches($0) && sourceFilter.matches($0)
    }
    let query = trimmedSearchQuery
    if !query.isEmpty {
      result = result.filter { entry in
        entry.filename.localizedCaseInsensitiveContains(query)
          || entry.mimeType.localizedCaseInsensitiveContains(query)
          || sourceTitle(for: entry).localizedCaseInsensitiveContains(query)
      }
    }
    return result.sorted { lhs, rhs in
      if lhs.createdAt == rhs.createdAt { return lhs.filename < rhs.filename }
      return lhs.createdAt > rhs.createdAt
    }
  }

  private var selectedEntries: [LibraryEntry] {
    workspace.libraryEntries
      .filter { selection.contains($0.id) }
      .sorted { $0.createdAt > $1.createdAt }
  }

  private var selectedEntry: LibraryEntry? {
    selectedEntries.count == 1 ? selectedEntries[0] : nil
  }

  private var selectedTotalBytes: Int {
    selectedEntries.reduce(0) { $0 + $1.byteCount }
  }

  private var totalBytes: Int {
    workspace.libraryEntries.reduce(0) { $0 + $1.byteCount }
  }

  private var trimmedSearchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var filtersAreActive: Bool {
    kindFilter != .all || sourceFilter != .all
  }

  private var shortcutsEnabled: Bool {
    !isSearchFocused && !showingPreview && renameTarget == nil && deleteTargets.isEmpty
  }

  private func clearSearchAndFilters() {
    searchText = ""
    kindFilter = .all
    sourceFilter = .all
  }

  var body: some View {
    VStack(spacing: 0) {
      browserControls
      Divider()

      if !selection.isEmpty {
        selectionBar
        Divider()
      }

      HStack(spacing: 0) {
        browserContent
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        if showingInspector {
          Divider()
          inspector
            .frame(width: 260)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(MacDesignTokens.Colors.canvas)
    .background { keyboardShortcutTriggers }
    .overlay {
      if isDropTargeted {
        dropOverlay
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard !urls.isEmpty, !isWorking else { return false }
      importFiles(urls)
      return true
    } isTargeted: { targeted in
      isDropTargeted = targeted
    }
    .dropDestination(for: MacDroppedImage.self) { images, _ in
      guard !images.isEmpty, !isWorking else { return false }
      importDroppedImages(images)
      return true
    } isTargeted: { targeted in
      isDropTargeted = targeted
    }
    .onAppear {
      normalizeSelection()
    }
    .onChange(of: visibleEntries.map(\.id)) { _, _ in
      normalizeSelection()
    }
    .task(id: selectedEntry?.id) {
      await loadInspectorDimensions(for: selectedEntry)
    }
    .onDisappear {
      cleanupPreview()
      cleanupShareTempDirectories()
    }
    .fileImporter(
      isPresented: $showingImporter,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .failure(let error):
        MacAppAnalytics.reportError("library_picker_failed", component: "library")
        workspace.errorMessage = error.localizedDescription
      case .success(let urls):
        importFiles(urls)
      }
    }
    .sheet(item: $renameTarget) { entry in
      MacLibraryRenameSheet(entry: entry) { filename in
        let ok = await workspace.renameLibraryEntry(entry.id, filename: filename)
        if ok { return nil }
        return workspace.consumeErrorMessage() ?? "Could not rename item."
      }
    }
    .sheet(
      isPresented: $showingPreview,
      onDismiss: {
        cleanupPreview()
        previewEntry = nil
      }
    ) {
      previewSheet
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
        isWorking = true
        Task { @MainActor in
          defer { isWorking = false }
          if await workspace.deleteLibraryEntries(targets) {
            selection.subtract(targets)
            normalizeSelection()
          }
        }
      }
      Button("Cancel", role: .cancel) { deleteTargets = [] }
    } message: {
      Text(
        deleteTargets.count == 1
          ? "The file will be removed from Library. Chats and projects are unaffected."
          : "The selected files will be removed from Library. Chats and projects are unaffected."
      )
    }
    .alert(
      "Library Error",
      isPresented: Binding(
        get: { workspace.errorMessage != nil && renameTarget == nil },
        set: { if !$0 { workspace.errorMessage = nil } }
      )
    ) {
      Button("OK") { workspace.errorMessage = nil }
    } message: {
      Text(workspace.errorMessage ?? "Unknown error")
    }
  }

  @ViewBuilder
  private var keyboardShortcutTriggers: some View {
    if shortcutsEnabled {
      ZStack {
        if let selectedEntry {
          Button("Quick Look") {
            preview(selectedEntry)
          }
          .keyboardShortcut(.space, modifiers: [])
          .disabled(previewLoadingID != nil || isWorking)
        }

        if !visibleEntries.isEmpty {
          Button("Select All") {
            selection = Set(visibleEntries.map(\.id))
            lastSelectedID = visibleEntries.last?.id
          }
          .keyboardShortcut("a", modifiers: .command)
        }

        if !selection.isEmpty, !isWorking {
          Button("Delete Selected") {
            deleteTargets = selection
          }
          .keyboardShortcut(.delete, modifiers: .command)
        }
      }
      .frame(width: 0, height: 0)
      .opacity(0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  private var dropOverlay: some View {
    ZStack {
      MacDesignTokens.Colors.accent.opacity(0.08)
      VStack(spacing: 8) {
        Image(systemName: "arrow.down.doc.fill")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.accent)
        Text("Drop files to import into Library")
          .font(.headline)
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(
            MacDesignTokens.Colors.accent,
            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
          )
      }
    }
    .padding(10)
    .allowsHitTesting(false)
  }

  private var browserControls: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        searchField

        MacSegmentedControl(
          options: MacLibrarySourceFilter.allCases,
          selection: $sourceFilter,
          title: \.compactTitle
        )
        .frame(width: 310)

        Spacer(minLength: 8)

        Button("Import", systemImage: "plus") {
          showingImporter = true
        }
        .buttonStyle(MacActionButtonStyle(.primary))
        .disabled(isWorking)
      }

      HStack(spacing: 10) {
        Text(storageSummary)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

        if visibleEntries.count != workspace.libraryEntries.count {
          Text("· \(visibleEntries.count) shown")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        Spacer()

        let kindFilterActive = kindFilter != .all
        Menu {
          Picker("Type", selection: $kindFilter) {
            ForEach(MacLibraryKindFilter.allCases) { filter in
              Text(filter.rawValue).tag(filter)
            }
          }
          if filtersAreActive {
            Divider()
            Button("Clear Filters") {
              kindFilter = .all
              sourceFilter = .all
            }
          }
        } label: {
          MacMenuButtonLabel(
            title: kindFilter == .all ? "Type" : kindFilter.rawValue,
            systemImage: kindFilterActive
              ? "line.3.horizontal.decrease.circle.fill"
              : "line.3.horizontal.decrease.circle",
            size: .small,
            isAccentIcon: kindFilterActive
          )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by file type")

        viewModeControl

        MacLibraryInspectorToggleButton(isActive: showingInspector) {
          showingInspector.toggle()
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var searchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Search files", text: $searchText)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)

      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear Library search")
      }
    }
    .padding(.horizontal, 10)
    .frame(width: 260, height: 30)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
  }

  private var viewModeControl: some View {
    HStack(spacing: 2) {
      ForEach(MacLibraryViewMode.allCases) { mode in
        MacLibraryViewModeButton(
          mode: mode,
          isSelected: viewMode == mode
        ) {
          viewMode = mode
        }
      }
    }
    .padding(2)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.65), lineWidth: 0.5)
    }
  }

  private var selectionBar: some View {
    HStack(spacing: 8) {
      Text(selection.count == 1 ? "1 selected" : "\(selection.count) selected")
        .font(.caption.weight(.medium))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)

      Spacer()

      if let selectedEntry {
        Button("Quick Look", systemImage: "eye") {
          preview(selectedEntry)
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        .disabled(previewLoadingID != nil || isWorking)
        .help("Quick Look (Space)")
      }

      Button("Export", systemImage: "square.and.arrow.down") {
        export(selectedEntries)
      }
      .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
      .disabled(isWorking)

      Button("Share", systemImage: "square.and.arrow.up") {
        share(selectedEntries)
      }
      .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
      .disabled(isWorking)

      if let selectedEntry {
        Button("Rename", systemImage: "pencil") {
          renameTarget = selectedEntry
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        .disabled(isWorking)
      }

      Button("Delete", systemImage: "trash", role: .destructive) {
        deleteTargets = selection
      }
      .buttonStyle(MacActionButtonStyle(.destructive, size: .small))
      .disabled(isWorking)

      Button {
        selection = []
        lastSelectedID = nil
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(MacIconButtonStyle())
      .help("Clear selection")
    }
    .padding(.horizontal, 16)
    .frame(height: 44)
    .background(MacDesignTokens.Colors.surface.opacity(0.62))
  }

  @ViewBuilder
  private var browserContent: some View {
    if workspace.libraryEntries.isEmpty {
      ContentUnavailableView {
        Label("Library is Empty", systemImage: "books.vertical")
      } description: {
        Text("Import or drop files here, or save attachments, responses, and project files.")
      } actions: {
        Button("Import Files…", systemImage: "plus") {
          showingImporter = true
        }
        .buttonStyle(MacActionButtonStyle(.primary))
        .disabled(isWorking)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if visibleEntries.isEmpty {
      ContentUnavailableView {
        Label(
          trimmedSearchQuery.isEmpty ? "No Files" : "No Matches",
          systemImage: trimmedSearchQuery.isEmpty
            ? "line.3.horizontal.decrease.circle"
            : "magnifyingglass"
        )
      } description: {
        Text(
          trimmedSearchQuery.isEmpty
            ? "Nothing matches the current filters."
            : "Try a different name or clear the filters."
        )
      } actions: {
        if filtersAreActive || !trimmedSearchQuery.isEmpty {
          Button("Clear Search & Filters") {
            clearSearchAndFilters()
          }
          .buttonStyle(MacActionButtonStyle(.secondary))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      switch viewMode {
      case .gallery:
        galleryContent
      case .list:
        listContent
      }
    }
  }

  private var galleryContent: some View {
    let entries = visibleEntries
    let sections = MacLibraryDateGrouper.sections(for: entries)
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        ForEach(sections, id: \.title) { section in
          VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section.title)

            LazyVGrid(
              columns: [
                GridItem(.adaptive(minimum: 176, maximum: 224), spacing: 14, alignment: .top)
              ],
              alignment: .leading,
              spacing: 14
            ) {
              ForEach(section.entries) { entry in
                MacLibraryGalleryCard(
                  entry: entry,
                  workspace: workspace,
                  sourceTitle: sourceTitle(for: entry),
                  isSelected: selection.contains(entry.id),
                  onClick: { handleRowClick(entry, orderedEntries: entries) }
                )
                .contextMenu { contextActions(entry) }
              }
            }
          }
        }
      }
      .padding(16)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private var listContent: some View {
    let entries = visibleEntries
    let sections = MacLibraryDateGrouper.sections(for: entries)
    return VStack(spacing: 0) {
      listColumnHeader

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
          ForEach(sections, id: \.title) { section in
            Section {
              ForEach(section.entries) { entry in
                MacLibraryListRow(
                  entry: entry,
                  workspace: workspace,
                  sourceTitle: sourceTitle(for: entry),
                  fileTypeTitle: fileTypeTitle(for: entry),
                  isSelected: selection.contains(entry.id),
                  onClick: { handleRowClick(entry, orderedEntries: entries) }
                )
                .contextMenu { contextActions(entry) }

                Divider()
                  .padding(.leading, 58)
              }
            } header: {
              sectionHeader(section.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .background(MacDesignTokens.Colors.canvas)
            }
          }
        }
        .padding(.bottom, 16)
      }
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private var listColumnHeader: some View {
    HStack(spacing: 12) {
      Text("Name")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Source")
        .frame(width: 170, alignment: .leading)
      Text("Type")
        .frame(width: 72, alignment: .leading)
      Text("Size")
        .frame(width: 72, alignment: .trailing)
      Text("Added")
        .frame(width: 88, alignment: .trailing)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(MacDesignTokens.Colors.textMuted)
    .padding(.horizontal, 16)
    .frame(height: 34)
    .background(MacDesignTokens.Colors.surface.opacity(0.72))
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.caption2.weight(.semibold))
      .tracking(0.5)
      .foregroundStyle(MacDesignTokens.Colors.textMuted)
  }

  @ViewBuilder
  private var inspector: some View {
    if selectedEntries.count > 1 {
      VStack(spacing: 14) {
        Spacer()
        Image(systemName: "checkmark.circle")
          .font(.system(size: 28))
          .foregroundStyle(MacDesignTokens.Colors.accent)
        Text("\(selectedEntries.count) Files Selected")
          .font(.headline)
        Text(
          ByteCountFormatter.string(
            fromByteCount: Int64(selectedTotalBytes),
            countStyle: .file
          )
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)

        VStack(spacing: 8) {
          Button("Export Selected…", systemImage: "square.and.arrow.down") {
            export(selectedEntries)
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          .disabled(isWorking)

          Button("Share Selected…", systemImage: "square.and.arrow.up") {
            share(selectedEntries)
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          .disabled(isWorking)

          Button("Delete Selected", systemImage: "trash", role: .destructive) {
            deleteTargets = selection
          }
          .buttonStyle(MacActionButtonStyle(.destructive, size: .small))
          .disabled(isWorking)
        }
        .padding(.top, 4)

        Spacer()
      }
      .padding(22)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(MacDesignTokens.Colors.surface.opacity(0.32))
    } else if let entry = selectedEntry {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          MacLibraryThumbnailView(
            entry: entry,
            workspace: workspace,
            size: 180,
            cornerRadius: 12,
            symbolSize: 36
          )
          .frame(maxWidth: .infinity)

          VStack(alignment: .leading, spacing: 5) {
            Text(entry.filename)
              .font(.headline)
              .textSelection(.enabled)
            Text(fileTypeTitle(for: entry))
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }

          Divider()

          inspectorField("Source", value: sourceTitle(for: entry))
          inspectorField("Size", value: entry.byteCountText)
          if let dimensions = inspectorDimensions {
            inspectorField("Dimensions", value: "\(dimensions.width) × \(dimensions.height)")
          }
          inspectorField("MIME Type", value: entry.mimeType)
          inspectorField(
            "Added",
            value: entry.createdAt.formatted(date: .abbreviated, time: .shortened)
          )

          if let source = sourceChat(for: entry) {
            Divider()
            if chats.summary(source.conversationID) != nil {
              Button("Open Source Message", systemImage: "bubble.left") {
                openSourceChat(source.conversationID, source.messageID)
              }
              .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
            } else {
              Label(
                "Source Chat Deleted",
                systemImage: "bubble.left.and.exclamationmark.bubble.right"
              )
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
          } else if let projectID = sourceProjectID(for: entry) {
            Divider()
            if workspace.project(projectID) != nil {
              Button("Open Source Project", systemImage: "folder") {
                openSourceProject(projectID)
              }
              .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
            } else {
              Label("Source Project Deleted", systemImage: "folder.badge.questionmark")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
          }

          Divider()

          HStack(spacing: 8) {
            Button("Quick Look", systemImage: "eye") {
              preview(entry)
            }
            .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
            .disabled(previewLoadingID != nil || isWorking)

            Menu {
              Button("Export…", systemImage: "square.and.arrow.down") {
                export([entry])
              }
              Button("Share…", systemImage: "square.and.arrow.up") {
                share([entry])
              }
              Button("Rename", systemImage: "pencil") {
                renameTarget = entry
              }
              Divider()
              Button("Delete", systemImage: "trash", role: .destructive) {
                deleteTargets = [entry.id]
              }
            } label: {
              MacIconMenuLabel(systemImage: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isWorking)
          }
        }
        .padding(16)
      }
      .background(MacDesignTokens.Colors.surface.opacity(0.32))
    } else {
      ContentUnavailableView(
        "No Selection",
        systemImage: "info.circle",
        description: Text("Select a file to see its details.")
      )
      .padding(18)
      .background(MacDesignTokens.Colors.surface.opacity(0.32))
    }
  }

  private func inspectorField(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption2.weight(.medium))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      Text(value)
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .textSelection(.enabled)
    }
  }

  @ViewBuilder
  private var previewSheet: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(previewEntry?.filename ?? "Preview")
            .font(.headline)
            .lineLimit(1)
          if let previewEntry {
            Text("\(sourceTitle(for: previewEntry)) · \(previewEntry.byteCountText)")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 8)

        if previewImage != nil {
          HStack(spacing: 4) {
            Button {
              withAnimation(.easeOut(duration: 0.15)) {
                previewZoomScale = max(Self.minPreviewZoom, previewZoomScale - 0.5)
              }
            } label: {
              Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(MacIconButtonStyle())
            .disabled(previewZoomScale <= Self.minPreviewZoom + 0.01)
            .help("Zoom Out")

            Button {
              withAnimation(.easeOut(duration: 0.15)) {
                previewZoomScale = Self.minPreviewZoom
              }
            } label: {
              Text("\(Int((previewZoomScale * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 42)
            }
            .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
            .disabled(abs(previewZoomScale - Self.minPreviewZoom) < 0.01)
            .help("Reset Zoom")

            Button {
              withAnimation(.easeOut(duration: 0.15)) {
                previewZoomScale = min(Self.maxPreviewZoom, previewZoomScale + 0.5)
              }
            } label: {
              Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(MacIconButtonStyle())
            .disabled(previewZoomScale >= Self.maxPreviewZoom - 0.01)
            .help("Zoom In")
          }
        }

        if let entry = previewEntry {
          if let source = sourceChat(for: entry), chats.summary(source.conversationID) != nil {
            Button("Open Source", systemImage: "bubble.left") {
              showingPreview = false
              openSourceChat(source.conversationID, source.messageID)
            }
            .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          } else if let projectID = sourceProjectID(for: entry), workspace.project(projectID) != nil {
            Button("Open Project", systemImage: "folder") {
              showingPreview = false
              openSourceProject(projectID)
            }
            .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          }

          Button("Export…", systemImage: "square.and.arrow.down") {
            export([entry])
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          .disabled(isWorking)

          Button("Share…", systemImage: "square.and.arrow.up") {
            share([entry])
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          .disabled(isWorking)
        }

        Button("Done") {
          showingPreview = false
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 16)
      .frame(height: 54)
      .background(MacDesignTokens.Colors.surface)

      Divider()

      if let previewImage {
        MacZoomableImageView(
          image: previewImage,
          scale: $previewZoomScale,
          minScale: Self.minPreviewZoom,
          maxScale: Self.maxPreviewZoom
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let previewURL {
        MacLibraryQuickLookView(url: previewURL)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView()
          .controlSize(.large)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(
      minWidth: MacDesignTokens.Sheet.previewMinWidth,
      idealWidth: MacDesignTokens.Sheet.previewIdealWidth,
      minHeight: MacDesignTokens.Sheet.previewMinHeight,
      idealHeight: MacDesignTokens.Sheet.previewIdealHeight
    )
    .background(MacDesignTokens.Colors.canvas)
  }

  @ViewBuilder
  private func contextActions(_ entry: LibraryEntry) -> some View {
    Button("Quick Look", systemImage: "eye") {
      preview(entry)
    }
    Button("Export…", systemImage: "square.and.arrow.down") {
      export([entry])
    }
    Button("Share…", systemImage: "square.and.arrow.up") {
      share([entry])
    }

    if let source = sourceChat(for: entry) {
      Divider()
      if chats.summary(source.conversationID) != nil {
        Button("Open Source Message", systemImage: "bubble.left") {
          openSourceChat(source.conversationID, source.messageID)
        }
      } else {
        Button("Source Chat Deleted", systemImage: "bubble.left.and.exclamationmark.bubble.right") {}
          .disabled(true)
      }
    } else if let projectID = sourceProjectID(for: entry) {
      Divider()
      if workspace.project(projectID) != nil {
        Button("Open Source Project", systemImage: "folder") {
          openSourceProject(projectID)
        }
      } else {
        Button("Source Project Deleted", systemImage: "folder.badge.questionmark") {}
          .disabled(true)
      }
    }

    Divider()
    Button("Rename", systemImage: "pencil") {
      renameTarget = entry
    }
    Button("Delete", systemImage: "trash", role: .destructive) {
      deleteTargets = [entry.id]
    }
  }

  private var storageSummary: String {
    let count = workspace.libraryEntries.count
    let bytes = ByteCountFormatter.string(
      fromByteCount: Int64(totalBytes),
      countStyle: .file
    )
    return "\(count) item\(count == 1 ? "" : "s") · \(bytes)"
  }

  private func sourceTitle(for entry: LibraryEntry) -> String {
    switch entry.source {
    case .manual:
      return "Saved"
    case .chat(let conversationID, _):
      guard let summary = chats.summary(conversationID) else { return "Deleted Chat" }
      let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
      return title.isEmpty ? "Chat" : title
    case .project(let projectID):
      return workspace.project(projectID)?.name ?? "Deleted Project"
    }
  }

  private func sourceChat(
    for entry: LibraryEntry
  ) -> (conversationID: ConversationID, messageID: ChatMessageID)? {
    if case .chat(let conversationID, let messageID) = entry.source {
      return (conversationID, messageID)
    }
    return nil
  }

  private func sourceProjectID(for entry: LibraryEntry) -> ProjectID? {
    if case .project(let projectID) = entry.source {
      return projectID
    }
    return nil
  }

  private func fileTypeTitle(for entry: LibraryEntry) -> String {
    if entry.isImage { return "Image" }
    if entry.mimeType.lowercased().contains("pdf") { return "PDF" }

    let ext = (entry.filename as NSString).pathExtension
    if !ext.isEmpty {
      return ext.uppercased()
    }

    if entry.mimeType.hasPrefix("text/") { return "Text" }
    return "File"
  }

  private func handleRowClick(_ entry: LibraryEntry, orderedEntries: [LibraryEntry]) {
    let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let clickCount = NSApp.currentEvent?.clickCount ?? 1

    if modifiers.contains(.shift),
      let anchor = lastSelectedID,
      let startIndex = orderedEntries.firstIndex(where: { $0.id == anchor }),
      let endIndex = orderedEntries.firstIndex(where: { $0.id == entry.id })
    {
      let lower = min(startIndex, endIndex)
      let upper = max(startIndex, endIndex)
      selection = Set(orderedEntries[lower...upper].map(\.id))
      return
    }

    if modifiers.contains(.command) {
      if selection.contains(entry.id) {
        selection.remove(entry.id)
      } else {
        selection.insert(entry.id)
      }
      lastSelectedID = entry.id
      return
    }

    selection = [entry.id]
    lastSelectedID = entry.id
    if clickCount >= 2 {
      preview(entry)
    }
  }

  private func normalizeSelection() {
    let visibleIDs = Set(visibleEntries.map(\.id))
    selection.formIntersection(visibleIDs)
    if let lastSelectedID, !visibleIDs.contains(lastSelectedID) {
      self.lastSelectedID = nil
    }
  }

  private func loadInspectorDimensions(for entry: LibraryEntry?) async {
    guard let entry, entry.isImage else {
      inspectorDimensions = nil
      return
    }
    let entryID = entry.id
    guard let data = await workspace.libraryData(entry), !data.isEmpty else {
      if selectedEntry?.id == entryID { inspectorDimensions = nil }
      return
    }
    let dims = await Task.detached(priority: .utility) {
      MacLibraryThumbnailCache.imageDimensions(from: data)
    }.value
    guard !Task.isCancelled, selectedEntry?.id == entryID else { return }
    inspectorDimensions = dims
  }

  private func importFiles(_ urls: [URL]) {
    guard !urls.isEmpty, !isWorking else { return }
    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }
      let result = await MacLibraryFileImporter.importURLs(urls)
      await finishImport(result)
    }
  }

  private func importDroppedImages(_ images: [MacDroppedImage]) {
    guard !images.isEmpty, !isWorking else { return }
    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }
      let result = await MacLibraryFileImporter.importDroppedImages(images)
      await finishImport(result)
    }
  }

  private func finishImport(_ result: MacLibraryFileImporter.ImportResult) async {
    let attachments = result.attachments
    if !attachments.isEmpty {
      let before = Set(workspace.libraryEntries.map(\.id))
      let added = await workspace.addLibraryAttachments(attachments)
      if added {
        let addedEntries = workspace.libraryEntries.filter { !before.contains($0.id) }
        if !addedEntries.isEmpty {
          // Ensure newly imported items aren't immediately hidden behind incompatible filters.
          if sourceFilter != .all && sourceFilter != .saved {
            sourceFilter = .all
          }
          if kindFilter != .all && !addedEntries.contains(where: { kindFilter.matches($0) }) {
            kindFilter = .all
          }
          if !trimmedSearchQuery.isEmpty {
            searchText = ""
          }
          selection = Set(addedEntries.map(\.id))
          lastSelectedID = addedEntries.first?.id
        } else {
          normalizeSelection()
        }
      } else {
        normalizeSelection()
      }
    } else {
      normalizeSelection()
    }

    if !result.skippedMessages.isEmpty {
      MacAppAnalytics.reportError("library_import_failed", component: "library")
      let summary = result.skippedMessages.prefix(5).joined(separator: "\n")
      let remaining = result.skippedMessages.count - 5
      let suffix = remaining > 0 ? "\n…and \(remaining) more." : ""
      if attachments.isEmpty {
        workspace.errorMessage = summary + suffix
      } else {
        workspace.errorMessage = "Imported \(attachments.count) item\(attachments.count == 1 ? "" : "s"), but skipped:\n\(summary)\(suffix)"
      }
    }
  }

  private func preview(_ entry: LibraryEntry) {
    guard previewLoadingID == nil else { return }

    cleanupPreview()
    previewEntry = entry
    previewZoomScale = Self.minPreviewZoom
    previewLoadingID = entry.id
    let requestedID = entry.id
    let filename = Self.safeFilename(entry.filename)

    Task { @MainActor in
      guard let data = await workspace.libraryData(entry), !data.isEmpty else {
        if previewLoadingID == requestedID {
          previewLoadingID = nil
          workspace.errorMessage = "The saved bytes for \(entry.filename) are unavailable."
        }
        return
      }

      let isGIF = entry.mimeType.lowercased() == "image/gif"
        || entry.filename.lowercased().hasSuffix(".gif")
      if entry.isImage && !isGIF {
        let bitmap = await Task.detached(priority: .userInitiated) {
          MacLibraryThumbnailCache.decodeFullImage(from: data)
        }.value

        guard previewLoadingID == requestedID else { return }
        if let bitmap {
          previewImage = NSImage(cgImage: bitmap.cgImage, size: bitmap.pointSize)
          previewLoadingID = nil
          showingPreview = true
          return
        }
      }

      do {
        let url = try await Task.detached(priority: .userInitiated) {
          let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
              "BYOKchat-library-preview-\(requestedID.rawValue)",
              isDirectory: true
            )
          try? FileManager.default.removeItem(at: directory)
          try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
          )
          let destination = directory.appendingPathComponent(filename, isDirectory: false)
          try data.write(to: destination, options: .atomic)
          return destination
        }.value

        guard previewLoadingID == requestedID else {
          try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
          return
        }

        previewURL = url
        previewLoadingID = nil
        showingPreview = true
      } catch {
        if previewLoadingID == requestedID {
          previewLoadingID = nil
          MacAppAnalytics.reportError("library_preview_failed", component: "library")
          workspace.errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func cleanupPreview() {
    if let previewURL {
      try? FileManager.default.removeItem(
        at: previewURL.deletingLastPathComponent()
      )
    }
    self.previewURL = nil
    previewImage = nil
    previewZoomScale = Self.minPreviewZoom
    previewLoadingID = nil
  }

  private func cleanupShareTempDirectories() {
    for directory in shareTempDirectories {
      try? FileManager.default.removeItem(at: directory)
    }
    shareTempDirectories.removeAll()
  }

  private func export(_ entries: [LibraryEntry]) {
    guard !entries.isEmpty, !isWorking else { return }

    Task { @MainActor in
      if entries.count == 1, let entry = entries.first {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.filename
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
          response = await panel.beginSheetModal(for: window)
        } else {
          response = panel.runModal()
        }
        guard response == .OK, let destination = panel.url else { return }
        await write(entry, to: destination)
        return
      }

      let panel = NSOpenPanel()
      panel.title = "Export Library Files"
      panel.prompt = "Export"
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.allowsMultipleSelection = false
      let response: NSApplication.ModalResponse
      if let window = NSApp.keyWindow {
        response = await panel.beginSheetModal(for: window)
      } else {
        response = panel.runModal()
      }
      guard response == .OK, let directory = panel.url else { return }

      isWorking = true
      defer { isWorking = false }

      var payloads: [(filename: String, data: Data)] = []
      var missing: [String] = []
      for entry in entries {
        if let data = await workspace.libraryData(entry), !data.isEmpty {
          payloads.append((filename: Self.safeFilename(entry.filename), data: data))
        } else {
          missing.append(entry.filename)
        }
      }

      do {
        let exportedCount = try await Task.detached(priority: .userInitiated) {
          var count = 0
          for payload in payloads {
            let destination = Self.uniqueDestinationURL(
              in: directory,
              filename: payload.filename
            )
            try payload.data.write(to: destination, options: .atomic)
            count += 1
          }
          return count
        }.value

        if exportedCount > 0 {
          toastCenter?.success(
            exportedCount == 1
              ? "Exported 1 file"
              : "Exported \(exportedCount) files"
          )
        }
        if !missing.isEmpty {
          MacAppAnalytics.reportError("library_export_failed", component: "library")
          workspace.errorMessage = "Saved bytes were unavailable for: \(missing.joined(separator: ", "))."
        }
      } catch {
        MacAppAnalytics.reportError("library_export_failed", component: "library")
        workspace.errorMessage = error.localizedDescription
      }
    }
  }

  private func write(_ entry: LibraryEntry, to destination: URL) async {
    isWorking = true
    defer { isWorking = false }

    guard let data = await workspace.libraryData(entry), !data.isEmpty else {
      workspace.errorMessage = "The saved bytes for \(entry.filename) are unavailable."
      return
    }

    do {
      try await Task.detached(priority: .userInitiated) {
        try data.write(to: destination, options: .atomic)
      }.value
      toastCenter?.success("Exported \"\(destination.lastPathComponent)\"")
    } catch {
      MacAppAnalytics.reportError("library_export_failed", component: "library")
      workspace.errorMessage = error.localizedDescription
    }
  }

  private func share(_ entries: [LibraryEntry]) {
    guard !entries.isEmpty, !isWorking else { return }

    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }

      // Clean any previous share temp directories before staging a new batch.
      cleanupShareTempDirectories()

      var payloads: [(filename: String, data: Data)] = []
      for entry in entries {
        guard let data = await workspace.libraryData(entry), !data.isEmpty else {
          MacAppAnalytics.reportError("library_share_failed", component: "library")
          workspace.errorMessage = "The saved bytes for \(entry.filename) are unavailable."
          return
        }
        payloads.append((filename: Self.safeFilename(entry.filename), data: data))
      }

      var createdFolder: URL?
      do {
        let (folder, urls) = try await Task.detached(priority: .userInitiated) {
          let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
              "BYOKchat-share-\(UUID().uuidString)",
              isDirectory: true
            )
          try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
          )
          var urls: [URL] = []
          urls.reserveCapacity(payloads.count)
          for payload in payloads {
            let url = Self.uniqueDestinationURL(in: folder, filename: payload.filename)
            try payload.data.write(to: url, options: .atomic)
            urls.append(url)
          }
          return (folder, urls)
        }.value
        createdFolder = folder

        guard let window = NSApp.keyWindow, let view = window.contentView else {
          try? FileManager.default.removeItem(at: folder)
          throw CocoaError(
            .featureUnsupported,
            userInfo: [
              NSLocalizedDescriptionKey: "The share sheet could not be presented."
            ]
          )
        }

        shareTempDirectories.append(folder)
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInView = view.convert(mouseInWindow, from: nil)
        let anchorRect: NSRect
        if view.bounds.contains(mouseInView) {
          anchorRect = NSRect(x: mouseInView.x - 1, y: mouseInView.y - 1, width: 2, height: 2)
        } else {
          anchorRect = NSRect(x: view.bounds.midX - 1, y: view.bounds.maxY - 60, width: 2, height: 2)
        }

        NSSharingServicePicker(items: urls)
          .show(relativeTo: anchorRect, of: view, preferredEdge: .minY)
      } catch {
        if let createdFolder {
          try? FileManager.default.removeItem(at: createdFolder)
        }
        MacAppAnalytics.reportError("library_share_failed", component: "library")
        workspace.errorMessage = error.localizedDescription
      }
    }
  }

  private nonisolated static func safeFilename(_ filename: String) -> String {
    let value = filename
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: "\0", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty || value == "." || value == ".." { return "file" }
    return value
  }

  private nonisolated static func uniqueDestinationURL(
    in directory: URL,
    filename: String
  ) -> URL {
    let initial = directory.appendingPathComponent(filename, isDirectory: false)
    guard !FileManager.default.fileExists(atPath: initial.path) else {
      return uniqueNumberedDestinationURL(in: directory, filename: filename)
    }
    return initial
  }

  private nonisolated static func uniqueNumberedDestinationURL(
    in directory: URL,
    filename: String
  ) -> URL {
    let ns = filename as NSString
    let extensionName = ns.pathExtension
    let stem = ns.deletingPathExtension

    for index in 2...999 {
      let candidateName = extensionName.isEmpty
        ? "\(stem) \(index)"
        : "\(stem) \(index).\(extensionName)"
      let candidate = directory.appendingPathComponent(
        candidateName,
        isDirectory: false
      )
      if !FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }

    return directory.appendingPathComponent(
      "\(UUID().uuidString)-\(filename)",
      isDirectory: false
    )
  }
}

private struct MacLibraryViewModeButton: View {
  let mode: MacLibraryViewMode
  let isSelected: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
    Button(action: action) {
      Image(systemName: mode.symbol)
        .foregroundStyle(
          isSelected || isHovered
            ? MacDesignTokens.Colors.textPrimary
            : MacDesignTokens.Colors.textMuted
        )
        .frame(width: 26, height: 24)
        .background(backgroundColor, in: shape)
        .contentShape(shape)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .help(mode.title)
    .accessibilityLabel("\(mode.title) view")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private var backgroundColor: Color {
    if isSelected { return MacDesignTokens.Colors.surface }
    if isHovered { return Color.primary.opacity(0.055) }
    return Color.clear
  }
}

private struct MacLibraryInspectorToggleButton: View {
  let isActive: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    Button(action: action) {
      Image(systemName: "sidebar.right")
        .foregroundStyle(
          isActive
            ? MacDesignTokens.Colors.accent
            : (isHovered ? MacDesignTokens.Colors.textPrimary : MacDesignTokens.Colors.textMuted)
        )
        .frame(width: 28, height: 26)
        .background(backgroundColor, in: shape)
        .overlay {
          if isActive {
            shape.stroke(MacDesignTokens.Colors.accent.opacity(0.3), lineWidth: 0.75)
          }
        }
        .contentShape(shape)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .help(isActive ? "Hide Info" : "Show Info")
    .accessibilityLabel(isActive ? "Hide Library info" : "Show Library info")
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
  }

  private var backgroundColor: Color {
    if isActive { return MacDesignTokens.Colors.accent.opacity(isHovered ? 0.19 : 0.14) }
    if isHovered { return Color.primary.opacity(MacDesignTokens.Control.hoverOpacity) }
    return Color.clear
  }
}

private struct MacLibraryGalleryCard: View {
  let entry: LibraryEntry
  @Bindable var workspace: MacWorkspaceModel
  let sourceTitle: String
  let isSelected: Bool
  let onClick: () -> Void

  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
    Button(action: onClick) {
      VStack(alignment: .leading, spacing: 0) {
        MacLibraryThumbnailView(
          entry: entry,
          workspace: workspace,
          width: nil,
          height: 138,
          cornerRadius: 8,
          symbolSize: 30
        )
        .padding(8)

        Divider()

        VStack(alignment: .leading, spacing: 4) {
          Text(entry.filename)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .lineLimit(1)

          Text("\(sourceTitle) · \(entry.byteCountText)")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(1)

          Text(entry.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
            .font(.caption2)
            .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.82))
            .lineLimit(1)
        }
        .padding(10)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(MacDesignTokens.Colors.surface, in: shape)
      .overlay {
        if isHovered && !isSelected {
          shape.fill(Color.primary.opacity(0.025))
        }
      }
      .overlay {
        shape.stroke(borderColor, lineWidth: isSelected ? 1.5 : 0.75)
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private var borderColor: Color {
    if isSelected { return MacDesignTokens.Colors.accent }
    if isHovered { return MacDesignTokens.Colors.accent.opacity(0.38) }
    return MacDesignTokens.Colors.separator.opacity(0.65)
  }
}

private struct MacLibraryListRow: View {
  let entry: LibraryEntry
  @Bindable var workspace: MacWorkspaceModel
  let sourceTitle: String
  let fileTypeTitle: String
  let isSelected: Bool
  let onClick: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: onClick) {
      HStack(spacing: 12) {
        HStack(spacing: 10) {
          MacLibraryThumbnailView(
            entry: entry,
            workspace: workspace,
            size: 34,
            cornerRadius: 7,
            symbolSize: 14
          )

          Text(entry.filename)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text(sourceTitle)
          .frame(width: 170, alignment: .leading)
          .lineLimit(1)

        Text(fileTypeTitle)
          .frame(width: 72, alignment: .leading)
          .lineLimit(1)

        Text(entry.byteCountText)
          .frame(width: 72, alignment: .trailing)
          .lineLimit(1)

        Text(entry.createdAt, format: .dateTime.month(.abbreviated).day())
          .frame(width: 88, alignment: .trailing)
          .lineLimit(1)
      }
      .font(.caption)
      .foregroundStyle(MacDesignTokens.Colors.textMuted)
      .padding(.horizontal, 16)
      .frame(minHeight: 48)
      .background(rowBackground)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private var rowBackground: Color {
    if isSelected { return MacDesignTokens.Colors.accent.opacity(0.11) }
    if isHovered { return Color.primary.opacity(0.035) }
    return Color.clear
  }
}

struct MacLibraryThumbnailView: View {
  let entry: LibraryEntry
  @Bindable var workspace: MacWorkspaceModel
  let width: CGFloat?
  let height: CGFloat
  let cornerRadius: CGFloat
  let symbolSize: CGFloat

  @Environment(\.displayScale) private var displayScale
  @State private var image: NSImage?

  init(
    entry: LibraryEntry,
    workspace: MacWorkspaceModel,
    size: CGFloat = 38,
    cornerRadius: CGFloat = 8,
    symbolSize: CGFloat = 16
  ) {
    self.entry = entry
    self.workspace = workspace
    self.width = size
    self.height = size
    self.cornerRadius = cornerRadius
    self.symbolSize = symbolSize
  }

  init(
    entry: LibraryEntry,
    workspace: MacWorkspaceModel,
    width: CGFloat?,
    height: CGFloat,
    cornerRadius: CGFloat = 8,
    symbolSize: CGFloat = 16
  ) {
    self.entry = entry
    self.workspace = workspace
    self.width = width
    self.height = height
    self.cornerRadius = cornerRadius
    self.symbolSize = symbolSize
  }

  private var targetPixelSize: CGFloat {
    let maxDimension = max(width ?? 220, height)
    return max(96, ceil(maxDimension * max(displayScale, 1)))
  }

  private var cacheKey: String {
    "\(entry.id.rawValue)@\(Int(targetPixelSize.rounded()))"
  }

  private var displayedImage: NSImage? {
    image ?? MacLibraryThumbnailCache.shared.image(forKey: cacheKey)
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    MacDesignTokens.Colors.canvas.opacity(0.65)
      .frame(maxWidth: width == nil ? .infinity : width, minHeight: height, maxHeight: height)
      .frame(width: width, height: height)
      .overlay {
        if let displayedImage {
          Image(nsImage: displayedImage)
            .resizable()
            .scaledToFill()
        } else {
          Image(
            systemName: MacLibraryThumbnailCache.fileSymbol(
              mimeType: entry.mimeType,
              isImage: entry.isImage
            )
          )
          .font(.system(size: symbolSize, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.accent)
        }
      }
      .clipShape(shape)
      .task(id: cacheKey) {
        await loadThumbnail()
      }
  }

  private func loadThumbnail() async {
    guard entry.isImage else {
      image = nil
      return
    }
    let key = cacheKey
    if let cached = MacLibraryThumbnailCache.shared.image(forKey: key) {
      image = cached
      return
    }
    image = nil

    guard await MacImageWorkLimiter.shared.acquirePermit() else { return }
    defer {
      Task { await MacImageWorkLimiter.shared.releasePermit() }
    }
    guard !Task.isCancelled else { return }

    if let cached = MacLibraryThumbnailCache.shared.image(forKey: key) {
      image = cached
      return
    }

    let maxPixels = targetPixelSize
    guard let data = await workspace.libraryThumbnail(entry, maxPixelSize: maxPixels),
      !data.isEmpty,
      !Task.isCancelled
    else { return }

    let bitmap = await Task.detached(priority: .utility) {
      MacLibraryThumbnailCache.decodeBitmap(from: data, maxPixelSize: maxPixels)
    }.value

    guard !Task.isCancelled, let bitmap else { return }
    let decoded = NSImage(cgImage: bitmap.cgImage, size: bitmap.pointSize)
    MacLibraryThumbnailCache.shared.insert(decoded, forKey: key, byteCost: bitmap.byteCost)
    image = decoded
  }
}

private final class MacLibraryPreviewItem: NSObject, QLPreviewItem {
  let previewItemURL: URL?

  init(url: URL) {
    previewItemURL = url
  }
}

struct MacLibraryQuickLookView: NSViewRepresentable {
  let url: URL

  final class Coordinator {
    fileprivate var item: MacLibraryPreviewItem?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> QLPreviewView {
    let view = QLPreviewView(frame: .zero, style: .normal)!
    view.autostarts = true
    let item = MacLibraryPreviewItem(url: url)
    context.coordinator.item = item
    view.previewItem = item
    return view
  }

  func updateNSView(_ view: QLPreviewView, context: Context) {
    guard context.coordinator.item?.previewItemURL != url else { return }
    let item = MacLibraryPreviewItem(url: url)
    context.coordinator.item = item
    view.previewItem = item
    view.refreshPreviewItem()
  }
}

enum MacLibraryRenameValidation {
  struct Evaluation: Equatable, Sendable {
    let trimmedName: String
    let canSave: Bool
    let errorMessage: String?
    let warningMessage: String?
  }

  static func evaluate(proposed: String, original: String) -> Evaluation {
    let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return Evaluation(
        trimmedName: trimmed,
        canSave: false,
        errorMessage: nil,
        warningMessage: nil
      )
    }
    if trimmed.contains("/") || trimmed.contains("\0") {
      return Evaluation(
        trimmedName: trimmed,
        canSave: false,
        errorMessage: "Filenames cannot contain '/'.",
        warningMessage: nil
      )
    }
    if trimmed == "." || trimmed == ".." {
      return Evaluation(
        trimmedName: trimmed,
        canSave: false,
        errorMessage: "Filenames cannot be '.' or '..'.",
        warningMessage: nil
      )
    }
    if trimmed == original {
      return Evaluation(
        trimmedName: trimmed,
        canSave: false,
        errorMessage: nil,
        warningMessage: nil
      )
    }

    let originalExt = (original as NSString).pathExtension
    let newExt = (trimmed as NSString).pathExtension
    var warning: String?
    if !originalExt.isEmpty {
      if newExt.isEmpty {
        warning = "Removing the .\(originalExt) extension may prevent previews from opening."
      } else if newExt.caseInsensitiveCompare(originalExt) != .orderedSame {
        warning = "Changing the .\(originalExt) extension to .\(newExt) may affect previews."
      }
    }
    return Evaluation(
      trimmedName: trimmed,
      canSave: true,
      errorMessage: nil,
      warningMessage: warning
    )
  }
}

private struct MacLibraryRenameSheet: View {
  let entry: LibraryEntry
  let save: (String) async -> String?

  @Environment(\.dismiss) private var dismiss
  @FocusState private var isFilenameFocused: Bool
  @State private var filename: String
  @State private var isSaving = false
  @State private var saveError: String?

  init(
    entry: LibraryEntry,
    save: @escaping (String) async -> String?
  ) {
    self.entry = entry
    self.save = save
    _filename = State(initialValue: entry.filename)
  }

  private var validation: MacLibraryRenameValidation.Evaluation {
    MacLibraryRenameValidation.evaluate(proposed: filename, original: entry.filename)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename Library Item")
        .font(.headline)

      if let saveError {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Text(saveError)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button {
            self.saveError = nil
          } label: {
            Image(systemName: "xmark")
              .font(.caption2.weight(.semibold))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Dismiss error")
        }
        .padding(8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(Color.red.opacity(0.25), lineWidth: 0.75)
        }
      }

      TextField("Filename", text: $filename)
        .textFieldStyle(.roundedBorder)
        .focused($isFilenameFocused)
        .onSubmit { commit() }

      if let error = validation.errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      } else if let warning = validation.warningMessage {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      HStack {
        Spacer()

        Button("Cancel") {
          dismiss()
        }
        .buttonStyle(MacActionButtonStyle(.secondary))
        .keyboardShortcut(.cancelAction)
        .disabled(isSaving)

        Button("Rename") {
          commit()
        }
        .buttonStyle(MacActionButtonStyle(.primary))
        .keyboardShortcut(.defaultAction)
        .disabled(!validation.canSave || isSaving)
      }
    }
    .padding(20)
    .frame(width: 420)
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      isFilenameFocused = true
    }
    .onChange(of: filename) { _, _ in
      saveError = nil
    }
  }

  private func commit() {
    let evaluation = validation
    guard evaluation.canSave, !isSaving else { return }

    isSaving = true
    saveError = nil
    Task { @MainActor in
      if let error = await save(evaluation.trimmedName) {
        saveError = error
        isSaving = false
      } else {
        dismiss()
      }
    }
  }
}
