import AppKit
import BYOKchatProviderCore
import SwiftUI
import UniformTypeIdentifiers

struct MacLibraryView: View {
  @Bindable var workspace: MacWorkspaceModel

  @Environment(\.dismiss) private var dismiss
  @State private var selectedID: LibraryEntryID?
  @State private var showingImporter = false
  @State private var renameTarget: LibraryEntry?
  @State private var deleteTarget: LibraryEntry?
  @State private var previewData: Data?
  @State private var isLoadingPreview = false

  private var selectedEntry: LibraryEntry? {
    guard let selectedID else { return nil }
    return workspace.libraryEntries.first { $0.id == selectedID }
  }

  var body: some View {
    NavigationSplitView {
      List(selection: $selectedID) {
        ForEach(workspace.libraryEntries) { entry in
          HStack(spacing: 10) {
            Image(systemName: entry.isImage ? "photo" : fileSymbol(entry))
              .foregroundStyle(MacDesignTokens.Colors.accent)
              .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.filename).lineLimit(1)
              Text("\(entry.byteCountText) · \(entry.mimeType)")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .lineLimit(1)
            }
          }
          .tag(entry.id)
          .contextMenu {
            Button("Rename", systemImage: "pencil") { renameTarget = entry }
            Button("Export…", systemImage: "square.and.arrow.down") { export(entry) }
            Button("Share…", systemImage: "square.and.arrow.up") { share(entry) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = entry }
          }
        }
      }
      .navigationTitle("Library")
      .navigationSplitViewColumnWidth(min: 250, ideal: 310, max: 390)
      .toolbar {
        ToolbarItem {
          Button("Import Files", systemImage: "plus") { showingImporter = true }
        }
      }
    } detail: {
      if let entry = selectedEntry {
        MacLibraryPreviewView(entry: entry, data: previewData, isLoading: isLoadingPreview)
          .toolbar {
            ToolbarItemGroup {
              Button("Export", systemImage: "square.and.arrow.down") { export(entry) }
              Button("Share", systemImage: "square.and.arrow.up") { share(entry) }
              Button("Rename", systemImage: "pencil") { renameTarget = entry }
              Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = entry }
            }
          }
      } else {
        ContentUnavailableView(
          workspace.libraryEntries.isEmpty ? "Library Empty" : "Select an Item",
          systemImage: "books.vertical",
          description: Text(workspace.libraryEntries.isEmpty ? "Import files or save attachments and responses from chats." : "Choose a Library item to preview it.")
        )
      }
    }
    .frame(minWidth: 850, minHeight: 580)
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      if selectedID == nil { selectedID = workspace.libraryEntries.first?.id }
    }
    .onChange(of: selectedID) { _, _ in loadPreview() }
    .onChange(of: workspace.libraryEntries.map(\.id)) { _, ids in
      if let selectedID, !ids.contains(selectedID) { self.selectedID = ids.first }
    }
    .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
      switch result {
      case .failure(let error): workspace.errorMessage = error.localizedDescription
      case .success(let urls): importFiles(urls)
      }
    }
    .sheet(item: $renameTarget) { entry in
      MacLibraryRenameSheet(entry: entry) { filename in
        await workspace.renameLibraryEntry(entry.id, filename: filename)
      }
    }
    .confirmationDialog(
      deleteTarget.map { "Delete \"\($0.filename)\"?" } ?? "Delete item?",
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        guard let entry = deleteTarget else { return }
        deleteTarget = nil
        Task { _ = await workspace.deleteLibraryEntries([entry.id]) }
      }
      Button("Cancel", role: .cancel) { deleteTarget = nil }
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

  private func importFiles(_ urls: [URL]) {
    Task { @MainActor in
      do {
        let attachments = try await MacAttachmentImporter.importURLs(urls)
        _ = await workspace.addLibraryAttachments(attachments)
        if selectedID == nil { selectedID = workspace.libraryEntries.first?.id }
      } catch {
        workspace.errorMessage = error.localizedDescription
      }
    }
  }

  private func loadPreview() {
    previewData = nil
    guard let entry = selectedEntry else { return }
    isLoadingPreview = true
    Task { @MainActor in
      previewData = await workspace.libraryData(entry)
      isLoadingPreview = false
    }
  }

  private func export(_ entry: LibraryEntry) {
    Task { @MainActor in
      guard let data = await workspace.libraryData(entry) else {
        workspace.errorMessage = "The saved bytes for \(entry.filename) are unavailable."
        return
      }
      let panel = NSSavePanel()
      panel.nameFieldStringValue = entry.filename
      if panel.runModal() == .OK, let url = panel.url {
        do { try data.write(to: url, options: .atomic) }
        catch { workspace.errorMessage = error.localizedDescription }
      }
    }
  }

  private func share(_ entry: LibraryEntry) {
    Task { @MainActor in
      guard let data = await workspace.libraryData(entry) else {
        workspace.errorMessage = "The saved bytes for \(entry.filename) are unavailable."
        return
      }
      do {
        let folder = FileManager.default.temporaryDirectory
          .appendingPathComponent("BYOKchat-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(entry.filename)
        try data.write(to: url, options: .atomic)
        guard let view = NSApp.keyWindow?.contentView else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
      } catch {
        workspace.errorMessage = error.localizedDescription
      }
    }
  }

  private func fileSymbol(_ entry: LibraryEntry) -> String {
    let mime = entry.mimeType.lowercased()
    if mime.contains("pdf") { return "doc.richtext" }
    if mime.contains("json") || mime.contains("javascript") { return "curlybraces.square" }
    if mime.hasPrefix("text/") { return "doc.text" }
    return "doc"
  }
}

private struct MacLibraryPreviewView: View {
  let entry: LibraryEntry
  let data: Data?
  let isLoading: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(entry.filename).font(.headline).textSelection(.enabled)
          Text("\(entry.byteCountText) · \(entry.mimeType)")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        Spacer()
      }
      .padding(18)
      Divider()

      Group {
        if isLoading {
          ProgressView().controlSize(.large)
        } else if let data {
          preview(data)
        } else {
          ContentUnavailableView("Preview Unavailable", systemImage: "doc.badge.ellipsis")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  @ViewBuilder
  private func preview(_ data: Data) -> some View {
    if entry.isImage, let image = NSImage(data: data) {
      ScrollView([.horizontal, .vertical]) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 900, maxHeight: 720)
          .padding(24)
      }
    } else if isTextLike, let text = String(data: data, encoding: .utf8) {
      ScrollView {
        Text(text)
          .font(.system(size: 12.5, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(24)
      }
    } else {
      VStack(spacing: 12) {
        Image(systemName: "doc.fill").font(.system(size: 48)).foregroundStyle(MacDesignTokens.Colors.accent)
        Text(entry.filename).font(.headline)
        Text("Preview is not available for this file type. Export or share the original file.")
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .padding(30)
    }
  }

  private var isTextLike: Bool {
    let mime = entry.mimeType.lowercased()
    return mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") || mime.contains("javascript") || mime.contains("yaml")
  }
}

private struct MacLibraryRenameSheet: View {
  let entry: LibraryEntry
  let save: (String) async -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var filename: String
  @State private var isSaving = false

  init(entry: LibraryEntry, save: @escaping (String) async -> Bool) {
    self.entry = entry
    self.save = save
    _filename = State(initialValue: entry.filename)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Rename Library Item").font(.headline)
      TextField("Filename", text: $filename)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Rename") {
          let value = filename.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !value.isEmpty else { return }
          isSaving = true
          Task { @MainActor in
            if await save(value) { dismiss() } else { isSaving = false }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}
