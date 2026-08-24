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
  @State private var viewerEntry: LibraryEntry?
  @State private var viewerImage: UIImage?
  @State private var viewerShareData: Data?
  @State private var quickLookFiles: [(filename: String, data: Data)]?
  @State private var renameTarget: LibraryEntry?
  @State private var renameText = ""
  @State private var deleteTarget: LibraryEntry?
  @State private var photoPickerItems: [PhotosPickerItem] = []
  @State private var isPhotoPickerPresented = false
  @State private var isFileImporterPresented = false

  var body: some View {
    Group {
      if library.entries.isEmpty {
        emptyState
      } else {
        entryList
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Library")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Open Sidebar", systemImage: "text.alignleft", action: openSidebar)
          .labelStyle(.iconOnly)
          .accessibilityLabel("Open sidebar")
      }
      ToolbarItem(placement: .primaryAction) {
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
      "Delete file?",
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        guard let target = deleteTarget else { return }
        Task { await library.deleteEntries([target.id]) }
        deleteTarget = nil
      }
      Button("Cancel", role: .cancel) { deleteTarget = nil }
    } message: {
      Text("\((deleteTarget?.filename ?? "This file")) will be removed from your library. Chats are unaffected.")
    }
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "Library is Empty",
      systemImage: "books.vertical",
      description: Text("Save images and documents from chats, or add them here with +.")
    )
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
      storageSummary
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)

      ForEach(LibraryDateGrouper.sections(for: library.entries), id: \.title) { section in
        Section(section.title) {
          ForEach(section.entries) { entry in
            row(entry)
          }
        }
      }
    }
    .listStyle(.plain)
  }

  private func row(_ entry: LibraryEntry) -> some View {
    Button {
      open(entry)
    } label: {
      HStack(spacing: 12) {
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
    .buttonStyle(.plain)
    .listRowBackground(theme.surfaceColor)
    .contextMenu { contextActions(entry) }
  }

  @ViewBuilder
  private func contextActions(_ entry: LibraryEntry) -> some View {
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
      deleteTarget = entry
    }
  }

  private func subtitle(for entry: LibraryEntry) -> String {
    switch entry.source {
    case .chat(let conversationID, _):
      let title = chats.conversation(conversationID)?.title ?? "Chat"
      return "\(title) · \(entry.byteCountText)"
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

  private func importPhotos(_ items: [PhotosPickerItem]) {
    guard !items.isEmpty else { return }
    Task { @MainActor in
      defer { photoPickerItems = [] }
      for item in items {
        do {
          guard let data = try await item.loadTransferable(type: Data.self),
            let jpeg = Self.normalizedJPEG(from: data)
          else { continue }
          let index = library.entries.count + 1
          _ = await library.add(
            filename: "image-\(index).jpg",
            mimeType: "image/jpeg",
            data: jpeg
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
                data: jpeg
              )
            } else {
              _ = await library.add(
                filename: url.lastPathComponent,
                mimeType: type.preferredMIMEType ?? "application/octet-stream",
                data: data
              )
            }
          } catch {
            library.errorMessage = error.localizedDescription
          }
        }
      }
    }
  }

  /// Matches the chat composer's pick pipeline: images become JPEG so every
  /// provider adapter receives a supported encoding.
  private static func normalizedJPEG(from data: Data) -> Data? {
    guard let image = UIImage(data: data) else { return nil }
    return image.jpegData(compressionQuality: 0.9)
  }
}

/// Identifiable wrappers so `sheet(item:)` can drive the two previews.
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
