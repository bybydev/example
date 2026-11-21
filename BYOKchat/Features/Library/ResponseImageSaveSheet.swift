import AppFoundation
import BYOKchatProviderCore
import SwiftUI
import UIKit

/// Confirmation sheet for "Save Images…" on a chat message: previews image
/// candidates found in the reply, lets the user pick which ones to keep,
/// downloads (or reuses cached bytes for) the selected ones, and files them
/// into the library with provenance back to this message.
struct ResponseImageSaveSheet: View {
  let candidates: [ResponseImageCandidate]
  let conversationID: ConversationID
  let messageID: ChatMessageID
  let library: LibraryManagementModel
  var onSaved: (Int) -> Void = { _ in }

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var selected: Set<String> = []
  @State private var savedIDs: Set<String> = []
  @State private var loadedByteCounts: [String: Int] = [:]
  @State private var savingID: String?
  @State private var isSaving = false
  @State private var savedCount = 0
  @State private var errorMessage: String?
  @State private var didInitializeSelection = false

  private var selectableIDs: [String] {
    candidates.map(\.id).filter { !savedIDs.contains($0) }
  }

  private var allSelectableSelected: Bool {
    !selectableIDs.isEmpty && selectableIDs.allSatisfy { selected.contains($0) }
  }

  private var saveButtonTitle: String {
    if candidates.count == 1 {
      return "Save"
    }
    return selected.isEmpty ? "Save" : "Save (\(selected.count))"
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(candidates) { candidate in
            candidateRow(candidate)
          }
        } header: {
          sectionHeader
        } footer: {
          Text("Selected images are saved to your Library and linked back to this message.")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle(candidates.count == 1 ? "Save Image" : "Save Images")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(selectableIDs.isEmpty ? "Done" : "Cancel") { dismiss() }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .primaryAction) {
          if isSaving {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Saving images")
          } else if !selectableIDs.isEmpty {
            Button(saveButtonTitle) {
              Task { await saveSelection() }
            }
            .fontWeight(.semibold)
            .disabled(selected.isEmpty)
          }
        }
      }
    }
    .presentationDragIndicator(.visible)
    .interactiveDismissDisabled(isSaving)
    .alert("Library Error", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Unknown error")
    }
    .onAppear {
      // Default to saving everything found.
      if !didInitializeSelection {
        selected = Set(candidates.map(\.id))
        didInitializeSelection = true
      }
    }
  }

  private var sectionHeader: some View {
    HStack {
      if candidates.count == 1 {
        Text("Image")
          .foregroundStyle(theme.secondaryForegroundColor)
      } else {
        Text("\(selected.count) of \(candidates.count) selected")
          .foregroundStyle(theme.secondaryForegroundColor)
      }

      Spacer(minLength: 8)

      if candidates.count > 1, !selectableIDs.isEmpty {
        Button(allSelectableSelected ? "Deselect All" : "Select All") {
          UISelectionFeedbackGenerator().selectionChanged()
          if allSelectableSelected {
            selected.removeAll()
          } else {
            selected = Set(selectableIDs)
          }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(theme.accentColor)
        .textCase(nil)
        .disabled(isSaving)
      }
    }
  }

  private func candidateRow(_ candidate: ResponseImageCandidate) -> some View {
    let isSaved = savedIDs.contains(candidate.id)
    let isCurrentlySaving = savingID == candidate.id
    let isSelected = selected.contains(candidate.id)

    return Button {
      guard !isSaved, !isSaving else { return }
      UISelectionFeedbackGenerator().selectionChanged()
      if !selected.insert(candidate.id).inserted {
        selected.remove(candidate.id)
      }
    } label: {
      HStack(spacing: 12) {
        ResponseImageCandidateThumbnail(candidate: candidate) { byteCount in
          if loadedByteCounts[candidate.id] != byteCount {
            loadedByteCounts[candidate.id] = byteCount
          }
        }

        VStack(alignment: .leading, spacing: 3) {
          Text(candidate.label)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.primaryForegroundColor)
            .lineLimit(1)

          Text(detail(for: candidate))
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        if isCurrentlySaving {
          ProgressView()
            .controlSize(.small)
        } else if isSaved {
          Label("Saved", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
            .labelStyle(.titleAndIcon)
        } else {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(
              isSelected ? theme.accentColor : theme.secondaryForegroundColor.opacity(0.55)
            )
            .symbolRenderingMode(.hierarchical)
        }
      }
      .padding(.vertical, 2)
      .contentShape(Rectangle())
      .opacity(isSaving && !isCurrentlySaving && !isSaved ? 0.6 : 1)
    }
    .buttonStyle(.plain)
    .disabled(isSaving || isSaved)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func detail(for candidate: ResponseImageCandidate) -> String {
    switch candidate.source {
    case .url(let url):
      let host = url.host ?? "Remote image"
      let byteCount = loadedByteCounts[candidate.id]
        ?? MarkdownImageSupport.cachedRawBytes(for: MarkdownImageSupport.cacheKey(for: url))?.count
      if let byteCount {
        let size = ByteCountFormatter.string(
          fromByteCount: Int64(byteCount),
          countStyle: .file
        )
        return "\(host) · \(size)"
      }
      return host
    case .data(let data, let fileExtension):
      let size = ByteCountFormatter.string(
        fromByteCount: Int64(data.count),
        countStyle: .file
      )
      return "\(fileExtension.uppercased()) · \(size)"
    }
  }

  private func saveSelection() async {
    guard !isSaving else { return }
    isSaving = true
    defer {
      savingID = nil
      isSaving = false
    }

    let wanted = selected
    var failures: [String] = []
    for (index, candidate) in candidates.enumerated()
    where wanted.contains(candidate.id) {
      savingID = candidate.id
      guard let data = await fetchData(for: candidate.source) else {
        failures.append("Couldn't fetch \(candidate.label).")
        continue
      }
      let filename = ResponseImageScanner.suggestedFilename(
        for: candidate.source,
        fallbackIndex: index + 1
      )
      let mimeType = Self.mimeType(for: data, filename: filename)
      let added = await library.add(
        filename: filename,
        mimeType: mimeType,
        data: data,
        source: .chat(conversationID: conversationID, messageID: messageID),
        onError: { error in
          failures.append("\(candidate.label): \(error.localizedDescription)")
        }
      )
      // Keep only unsaved selections for retry, without duplicating successes.
      if added != nil {
        selected.remove(candidate.id)
        savedIDs.insert(candidate.id)
        savedCount += 1
      }
    }

    if savedCount > 0 {
      onSaved(savedCount)
    }

    if !failures.isEmpty {
      BYOKAppAnalytics.reportError("library_share_failed", component: "library")
      errorMessage = failures.joined(separator: "\n")
    } else {
      dismiss()
    }
  }

  private func fetchData(for source: ResponseImageCandidate.Source) async -> Data? {
    if case .url(let url) = source {
      let cacheKey = MarkdownImageSupport.cacheKey(for: url)
      if let cached = MarkdownImageSupport.cachedRawBytes(for: cacheKey),
        cached.count <= LibraryStore.maxByteCount
      {
        return cached
      }
    }
    return await ResponseImageScanner.fetchData(
      for: source,
      maxByteCount: LibraryStore.maxByteCount
    )
  }

  /// Sniff the encoding rather than trusting the link; adapters and viewers
  /// both assume a real image payload.
  nonisolated static func mimeType(for data: Data, filename: String) -> String {
    if data.prefix(2) == Data([0xFF, 0xD8]) { return "image/jpeg" }
    if data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
      return "image/png"
    }
    if data.prefix(6) == Data("GIF89a".utf8) || data.prefix(6) == Data("GIF87a".utf8) {
      return "image/gif"
    }
    if data.count >= 12,
      data.prefix(4) == Data("RIFF".utf8),
      data.subdata(in: 8..<12) == Data("WEBP".utf8)
    {
      return "image/webp"
    }
    return filename.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
  }
}

private struct ResponseImageCandidateThumbnail: View {
  let candidate: ResponseImageCandidate
  var onByteCountLoaded: (Int) -> Void = { _ in }

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @State private var loadedImage: UIImage?
  @State private var didFail = false

  private let tileSize: CGFloat = 56

  private var pixelSize: CGFloat {
    ceil(tileSize * max(displayScale, 1))
  }

  private var cacheKey: String {
    switch candidate.source {
    case .url(let url):
      MarkdownImageSupport.cacheKey(for: url)
    case .data:
      "respimg::\(candidate.id)"
    }
  }

  var body: some View {
    let displayed = loadedImage ?? AttachmentThumbnailLoader.cachedImage(
      cacheKey: cacheKey,
      maxPixelSize: pixelSize
    )

    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(theme.backgroundColor.opacity(0.65))

      if let displayed {
        Image(uiImage: displayed)
          .resizable()
          .scaledToFill()
          .frame(width: tileSize, height: tileSize)
          .clipped()
      } else {
        Image(systemName: didFail ? "exclamationmark.triangle" : "photo")
          .font(.system(size: 18))
          .foregroundStyle(theme.secondaryForegroundColor.opacity(0.55))
      }
    }
    .frame(width: tileSize, height: tileSize)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 0.75)
    )
    .task(id: candidate.id) {
      await loadThumbnail()
    }
  }

  private func loadThumbnail() async {
    let key = cacheKey
    let maxPixels = pixelSize

    if let cached = AttachmentThumbnailLoader.cachedImage(cacheKey: key, maxPixelSize: maxPixels) {
      loadedImage = cached
      didFail = false
      return
    }

    let rawData: Data?
    switch candidate.source {
    case .data(let data, _):
      rawData = data
    case .url(let url):
      rawData = await MarkdownImageSupport.loadBytes(for: url)?.data
    }

    guard !Task.isCancelled else { return }

    if let rawData {
      onByteCountLoaded(rawData.count)
    }

    guard let rawData,
      let decoded = await AttachmentThumbnailLoader.decodeImage(
        from: rawData,
        cacheKey: key,
        maxPixelSize: maxPixels
      )
    else {
      if !Task.isCancelled { didFail = true }
      return
    }

    guard !Task.isCancelled else { return }
    loadedImage = decoded
    didFail = false
  }
}
