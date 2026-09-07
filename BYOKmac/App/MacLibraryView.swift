import AppKit
import BYOKchatProviderCore
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
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateFormat = "MMMM yyyy"
    let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)
    let sorted = entries.sorted { lhs, rhs in
      if lhs.createdAt == rhs.createdAt { return lhs.filename < rhs.filename }
      return lhs.createdAt > rhs.createdAt
    }

    func title(for date: Date) -> String {
      if calendar.isDate(date, inSameDayAs: now) { return "Today" }
      if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
        calendar.isDate(date, inSameDayAs: yesterday)
      {
        return "Yesterday"
      }
      if let weekAgo, date > weekAgo { return "Previous 7 Days" }
      return formatter.string(from: date)
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

struct MacLibraryView: View {
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var chats: MacChatSessionModel
  let openSourceChat: (ConversationID) -> Void

  @State private var selection: Set<LibraryEntryID> = []
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
  @State private var previewLoadingID: LibraryEntryID?
  @State private var showingPreview = false
  @State private var isWorking = false

  private var visibleEntries: [LibraryEntry] {
    var result = workspace.libraryEntries.filter {
      kindFilter.matches($0) && sourceFilter.matches($0)
    }
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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

  private var totalBytes: Int {
    workspace.libraryEntries.reduce(0) { $0 + $1.byteCount }
  }

  private var filtersAreActive: Bool {
    kindFilter != .all || sourceFilter != .all
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
    .frame(minWidth: 920, minHeight: 620)
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      normalizeSelection()
    }
    .onChange(of: visibleEntries.map(\.id)) { _, _ in
      normalizeSelection()
    }
    .onDisappear {
      cleanupPreview()
    }
    .fileImporter(
      isPresented: $showingImporter,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .failure(let error):
        workspace.errorMessage = error.localizedDescription
      case .success(let urls):
        importFiles(urls)
      }
    }
    .sheet(item: $renameTarget) { entry in
      MacLibraryRenameSheet(entry: entry) { filename in
        await workspace.renameLibraryEntry(entry.id, filename: filename)
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
        Task { @MainActor in
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
          ? "The file will be removed from Library. Chats are unaffected."
          : "The selected files will be removed from Library. Chats are unaffected."
      )
    }
    .alert(
      "Library Error",
      isPresented: Binding(
        get: { workspace.errorMessage != nil },
        set: { if !$0 { workspace.errorMessage = nil } }
      )
    ) {
      Button("OK") { workspace.errorMessage = nil }
    } message: {
      Text(workspace.errorMessage ?? "Unknown error")
    }
  }

  private var browserControls: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        searchField

        Picker("Source", selection: $sourceFilter) {
          ForEach(MacLibrarySourceFilter.allCases) { filter in
            Text(filter.compactTitle).tag(filter)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 300)

        Spacer(minLength: 8)

        Button("Import", systemImage: "plus") {
          showingImporter = true
        }
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
          Label(
            kindFilter == .all ? "Type" : kindFilter.rawValue,
            systemImage: filtersAreActive
              ? "line.3.horizontal.decrease.circle.fill"
              : "line.3.horizontal.decrease.circle"
          )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by file type")

        viewModeControl

        Button {
          showingInspector.toggle()
        } label: {
          Image(systemName: "sidebar.right")
            .frame(width: 26, height: 26)
            .background(
              showingInspector ? MacDesignTokens.Colors.accent.opacity(0.14) : Color.clear,
              in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .help(showingInspector ? "Hide Info" : "Show Info")
        .accessibilityLabel(showingInspector ? "Hide Library info" : "Show Library info")
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
        Button {
          viewMode = mode
        } label: {
          Image(systemName: mode.symbol)
            .frame(width: 26, height: 24)
            .background(
              viewMode == mode ? Color.primary.opacity(0.09) : Color.clear,
              in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .help(mode.title)
        .accessibilityLabel("\(mode.title) view")
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
        .keyboardShortcut(.space, modifiers: [])
        .disabled(previewLoadingID != nil || isWorking)
        .help("Quick Look (Space)")
      }

      Button("Export", systemImage: "square.and.arrow.down") {
        export(selectedEntries)
      }
      .disabled(isWorking)

      Button("Share", systemImage: "square.and.arrow.up") {
        share(selectedEntries)
      }
      .disabled(isWorking)

      if let selectedEntry {
        Button("Rename", systemImage: "pencil") {
          renameTarget = selectedEntry
        }
        .disabled(isWorking)
      }

      Button("Delete", systemImage: "trash", role: .destructive) {
        deleteTargets = selection
      }
      .disabled(isWorking)

      Button {
        selection = []
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Clear selection")
    }
    .padding(.horizontal, 16)
    .frame(height: 44)
    .background(MacDesignTokens.Colors.surface.opacity(0.62))
  }

  @ViewBuilder
  private var browserContent: some View {
    if workspace.libraryEntries.isEmpty {
      ContentUnavailableView(
        "Library is Empty",
        systemImage: "books.vertical",
        description: Text("Import files or save attachments and responses from chats.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if visibleEntries.isEmpty {
      ContentUnavailableView(
        searchText.isEmpty ? "No Files" : "No Matches",
        systemImage: searchText.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass",
        description: Text(
          searchText.isEmpty
            ? "Nothing matches the current filters."
            : "Try a different name or clear the filters."
        )
      )
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
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        ForEach(MacLibraryDateGrouper.sections(for: visibleEntries), id: \.title) { section in
          VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section.title)

            LazyVGrid(
              columns: [
                GridItem(.adaptive(minimum: 168, maximum: 218), spacing: 14, alignment: .top)
              ],
              alignment: .leading,
              spacing: 14
            ) {
              ForEach(section.entries) { entry in
                Button {
                  select(entry)
                } label: {
                  galleryCard(entry)
                }
                .buttonStyle(.plain)
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

  private func galleryCard(_ entry: LibraryEntry) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      MacLibraryThumbnailView(
        entry: entry,
        workspace: workspace,
        size: 152,
        cornerRadius: 9,
        symbolSize: 30
      )
      .frame(maxWidth: .infinity)
      .padding(8)

      Divider()

      VStack(alignment: .leading, spacing: 4) {
        Text(entry.filename)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          .lineLimit(1)

        Text("\(sourceTitle(for: entry)) · \(entry.byteCountText)")
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
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(
          selection.contains(entry.id)
            ? MacDesignTokens.Colors.accent
            : MacDesignTokens.Colors.separator.opacity(0.65),
          lineWidth: selection.contains(entry.id) ? 1.5 : 0.5
        )
    }
    .contentShape(RoundedRectangle(cornerRadius: 11))
  }

  private var listContent: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
        listColumnHeader

        ForEach(MacLibraryDateGrouper.sections(for: visibleEntries), id: \.title) { section in
          Section {
            ForEach(section.entries) { entry in
              Button {
                select(entry)
              } label: {
                libraryListRow(entry)
              }
              .buttonStyle(.plain)
              .contextMenu { contextActions(entry) }

              Divider()
                .padding(.leading, 58)
            }
          } header: {
            sectionHeader(section.title)
              .padding(.horizontal, 16)
              .padding(.top, 14)
              .padding(.bottom, 6)
              .background(MacDesignTokens.Colors.canvas)
          }
        }
      }
      .padding(.bottom, 16)
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

  private func libraryListRow(_ entry: LibraryEntry) -> some View {
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

      Text(sourceTitle(for: entry))
        .frame(width: 170, alignment: .leading)
        .lineLimit(1)

      Text(fileTypeTitle(for: entry))
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
    .background(
      selection.contains(entry.id)
        ? MacDesignTokens.Colors.accent.opacity(0.11)
        : Color.clear
    )
    .contentShape(Rectangle())
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
        Text("Use the selection bar to export, share, or delete these files.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .multilineTextAlignment(.center)
        Spacer()
      }
      .padding(22)
      .frame(maxHeight: .infinity)
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
          inspectorField("MIME Type", value: entry.mimeType)
          inspectorField(
            "Added",
            value: entry.createdAt.formatted(date: .abbreviated, time: .shortened)
          )

          if let conversationID = sourceConversationID(for: entry) {
            Divider()
            Button("Open Source Chat", systemImage: "bubble.left") {
              openSourceChat(conversationID)
            }
            .buttonStyle(.bordered)
          }

          Divider()

          HStack(spacing: 8) {
            Button("Quick Look", systemImage: "eye") {
              preview(entry)
            }
            .disabled(previewLoadingID != nil)

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
              Image(systemName: "ellipsis")
            }
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
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(previewEntry?.filename ?? "Preview")
            .font(.headline)
          if let previewEntry {
            Text("\(sourceTitle(for: previewEntry)) · \(previewEntry.byteCountText)")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }

        Spacer()

        Button("Done") {
          showingPreview = false
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 16)
      .frame(height: 52)

      Divider()

      if let previewURL {
        MacLibraryQuickLookView(url: previewURL)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView()
          .controlSize(.large)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 760, idealWidth: 900, minHeight: 560, idealHeight: 680)
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

    if let conversationID = sourceConversationID(for: entry) {
      Divider()
      Button("Open Source Chat", systemImage: "bubble.left") {
        openSourceChat(conversationID)
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
      let title = chats.summary(conversationID)?.title.trimmingCharacters(
        in: .whitespacesAndNewlines
      ) ?? ""
      return title.isEmpty ? "Chat" : title
    case .project(let projectID):
      return workspace.project(projectID)?.name ?? "Project File"
    }
  }

  private func sourceConversationID(for entry: LibraryEntry) -> ConversationID? {
    if case .chat(let conversationID, _) = entry.source {
      return conversationID
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

  private func select(_ entry: LibraryEntry) {
    let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.command) {
      if selection.contains(entry.id) {
        selection.remove(entry.id)
      } else {
        selection.insert(entry.id)
      }
    } else {
      selection = [entry.id]
    }
  }

  private func normalizeSelection() {
    let visibleIDs = Set(visibleEntries.map(\.id))
    selection.formIntersection(visibleIDs)
  }

  private func importFiles(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }
      var firstAddedID: LibraryEntryID?
      for url in urls {
        do {
          guard let attachment = try await MacAttachmentImporter.importURLs([url]).first else {
            continue
          }
          let before = Set(workspace.libraryEntries.map(\.id))
          guard await workspace.addLibraryAttachments([attachment]) else { break }
          if firstAddedID == nil {
            firstAddedID = workspace.libraryEntries.first {
              !before.contains($0.id)
            }?.id
          }
        } catch {
          workspace.errorMessage = error.localizedDescription
          break
        }
      }

      if let firstAddedID {
        selection = [firstAddedID]
      } else {
        normalizeSelection()
      }
    }
  }

  private func preview(_ entry: LibraryEntry) {
    guard previewLoadingID == nil else { return }

    cleanupPreview()
    previewEntry = entry
    previewLoadingID = entry.id
    let requestedID = entry.id

    Task { @MainActor in
      guard let data = await workspace.libraryData(entry), !data.isEmpty else {
        if previewLoadingID == requestedID {
          previewLoadingID = nil
          workspace.errorMessage = "The saved bytes for \(entry.filename) are unavailable."
        }
        return
      }

      do {
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

        let filename = Self.safeFilename(entry.filename)
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: url, options: .atomic)

        guard previewLoadingID == requestedID else {
          try? FileManager.default.removeItem(at: directory)
          return
        }

        previewURL = url
        previewLoadingID = nil
        showingPreview = true
      } catch {
        if previewLoadingID == requestedID {
          previewLoadingID = nil
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
    previewLoadingID = nil
  }

  private func export(_ entries: [LibraryEntry]) {
    guard !entries.isEmpty else { return }

    if entries.count == 1, let entry = entries.first {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = entry.filename
      guard panel.runModal() == .OK, let destination = panel.url else { return }
      write(entry, to: destination)
      return
    }

    let panel = NSOpenPanel()
    panel.title = "Export Library Files"
    panel.prompt = "Export"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let directory = panel.url else { return }

    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }
      do {
        for entry in entries {
          guard let data = await workspace.libraryData(entry) else {
            throw CocoaError(
              .fileReadNoSuchFile,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "The saved bytes for \(entry.filename) are unavailable."
              ]
            )
          }

          let destination = Self.uniqueDestinationURL(
            in: directory,
            filename: Self.safeFilename(entry.filename)
          )
          try data.write(to: destination, options: .atomic)
        }
      } catch {
        workspace.errorMessage = error.localizedDescription
      }
    }
  }

  private func write(_ entry: LibraryEntry, to destination: URL) {
    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }

      guard let data = await workspace.libraryData(entry) else {
        workspace.errorMessage = "The saved bytes for \(entry.filename) are unavailable."
        return
      }

      do {
        try data.write(to: destination, options: .atomic)
      } catch {
        workspace.errorMessage = error.localizedDescription
      }
    }
  }

  private func share(_ entries: [LibraryEntry]) {
    guard !entries.isEmpty else { return }

    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }

      do {
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
        for entry in entries {
          guard let data = await workspace.libraryData(entry) else {
            throw CocoaError(
              .fileReadNoSuchFile,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "The saved bytes for \(entry.filename) are unavailable."
              ]
            )
          }

          let url = Self.uniqueDestinationURL(
            in: folder,
            filename: Self.safeFilename(entry.filename)
          )
          try data.write(to: url, options: .atomic)
          urls.append(url)
        }

        guard let view = NSApp.keyWindow?.contentView else {
          throw CocoaError(
            .featureUnsupported,
            userInfo: [
              NSLocalizedDescriptionKey:
                "The share sheet could not be presented."
            ]
          )
        }

        NSSharingServicePicker(items: urls)
          .show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
      } catch {
        workspace.errorMessage = error.localizedDescription
      }
    }
  }

  private static func safeFilename(_ filename: String) -> String {
    let value = filename
      .replacingOccurrences(of: "/", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "file" : value
  }

  private static func uniqueDestinationURL(
    in directory: URL,
    filename: String
  ) -> URL {
    let initial = directory.appendingPathComponent(filename, isDirectory: false)
    guard !FileManager.default.fileExists(atPath: initial.path) else {
      return uniqueNumberedDestinationURL(in: directory, filename: filename)
    }
    return initial
  }

  private static func uniqueNumberedDestinationURL(
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

private struct MacLibraryThumbnailView: View {
  let entry: LibraryEntry
  @Bindable var workspace: MacWorkspaceModel
  let size: CGFloat
  let cornerRadius: CGFloat
  let symbolSize: CGFloat

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
    self.size = size
    self.cornerRadius = cornerRadius
    self.symbolSize = symbolSize
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: fileSymbol)
          .font(.system(size: symbolSize, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.accent)
      }
    }
    .frame(width: size, height: size)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: cornerRadius)
    )
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    .task(id: "\(entry.id.rawValue)-\(entry.updatedAt.timeIntervalSinceReferenceDate)-\(Int(size))") {
      guard entry.isImage else {
        image = nil
        return
      }

      let maxPixelSize = max(96, size * 2)
      let data = await workspace.libraryThumbnail(
        entry,
        maxPixelSize: maxPixelSize
      )
      image = data.flatMap(NSImage.init(data:))
    }
  }

  private var fileSymbol: String {
    if entry.isImage { return "photo" }
    let mime = entry.mimeType.lowercased()
    if mime.contains("pdf") { return "doc.richtext" }
    if mime.contains("json") || mime.contains("javascript") {
      return "curlybraces.square"
    }
    if mime.hasPrefix("text/") { return "doc.text" }
    return "doc"
  }
}

private final class MacLibraryPreviewItem: NSObject, QLPreviewItem {
  let previewItemURL: URL?

  init(url: URL) {
    previewItemURL = url
  }
}

private struct MacLibraryQuickLookView: NSViewRepresentable {
  let url: URL

  final class Coordinator {
    var item: MacLibraryPreviewItem?
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
    let item = MacLibraryPreviewItem(url: url)
    context.coordinator.item = item
    view.previewItem = item
    view.refreshPreviewItem()
  }
}

private struct MacLibraryRenameSheet: View {
  let entry: LibraryEntry
  let save: (String) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var filename: String
  @State private var isSaving = false

  init(
    entry: LibraryEntry,
    save: @escaping (String) async -> Bool
  ) {
    self.entry = entry
    self.save = save
    _filename = State(initialValue: entry.filename)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Rename Library Item")
        .font(.headline)

      TextField("Filename", text: $filename)

      HStack {
        Spacer()

        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Rename") {
          let value = filename.trimmingCharacters(
            in: .whitespacesAndNewlines
          )
          guard !value.isEmpty else { return }

          isSaving = true
          Task { @MainActor in
            if await save(value) {
              dismiss()
            } else {
              isSaving = false
            }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isSaving
        )
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}
