import AppKit
import BYOKchatProviderCore
import SwiftUI

/// Confirmation sheet for "Save Images…" on a chat message: previews image
/// candidates found in the reply, lets the user pick which ones to keep,
/// downloads (or reuses cached bytes for) the selected ones, and files them
/// into the Library with provenance back to this message.
struct MacResponseImageSaveSheet: View {
  let candidates: [MacResponseImageCandidate]
  let conversationID: ConversationID
  let messageID: ChatMessageID
  let workspace: MacWorkspaceModel
  var onSaved: (Int) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selected: Set<String> = []
  @State private var savedIDs: Set<String> = []
  @State private var failedPreviewIDs: Set<String> = []
  @State private var loadedByteCounts: [String: Int] = [:]
  @State private var savingID: String?
  @State private var isSaving = false
  @State private var savedCount = 0
  @State private var errorMessage: String?
  @State private var didInitializeSelection = false

  init(
    candidates: [MacResponseImageCandidate],
    conversationID: ConversationID,
    messageID: ChatMessageID,
    workspace: MacWorkspaceModel,
    onSaved: @escaping (Int) -> Void = { _ in }
  ) {
    self.candidates = candidates
    self.conversationID = conversationID
    self.messageID = messageID
    self.workspace = workspace
    self.onSaved = onSaved
  }

  private var selectableIDs: [String] {
    candidates.map(\.id).filter { !savedIDs.contains($0) }
  }

  private var allSelectableSelected: Bool {
    !selectableIDs.isEmpty && selectableIDs.allSatisfy { selected.contains($0) }
  }

  private var saveButtonTitle: String {
    if candidates.count == 1 {
      return "Save to Library"
    }
    return selected.isEmpty ? "Save" : "Save (\(selected.count))"
  }

  var body: some View {
    VStack(spacing: 0) {
      headerBar

      Divider()

      if candidates.isEmpty {
        ContentUnavailableView(
          "No Images Found",
          systemImage: "photo",
          description: Text("This response doesn't include any savable images.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        selectionBar

        Divider()

        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(candidates) { candidate in
              candidateRow(candidate)
            }
          }
          .padding(16)
        }

        Divider()

        HStack(spacing: 8) {
          Image(systemName: "books.vertical")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Text("Selected images are saved to your Library and linked back to this message.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(MacDesignTokens.Colors.surface.opacity(0.6))
      }
    }
    .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 460)
    .background(MacDesignTokens.Colors.canvas)
    .interactiveDismissDisabled(isSaving)
    .alert(
      "Library Error",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Unknown error")
    }
    .onAppear {
      if !didInitializeSelection {
        selected = Set(candidates.map(\.id))
        didInitializeSelection = true
      }
    }
  }

  private var headerBar: some View {
    HStack(spacing: 10) {
      Text(candidates.count == 1 ? "Save Image" : "Save Images")
        .font(.headline)
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)

      Spacer(minLength: 8)

      Button(selectableIDs.isEmpty ? "Done" : "Cancel") { dismiss() }
        .buttonStyle(MacActionButtonStyle(.secondary))
        .keyboardShortcut(.cancelAction)
        .disabled(isSaving)

      if isSaving {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text("Saving…")
            .font(.callout)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      } else if !selectableIDs.isEmpty {
        Button(saveButtonTitle) {
          Task { await saveSelection() }
        }
        .buttonStyle(MacActionButtonStyle(.primary))
        .keyboardShortcut(.defaultAction)
        .disabled(selected.isEmpty)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var selectionBar: some View {
    HStack(spacing: 8) {
      if candidates.count == 1 {
        Text("1 image found in this response")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      } else {
        Text("\(selected.count) of \(candidates.count) selected")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }

      Spacer(minLength: 8)

      if candidates.count > 1, !selectableIDs.isEmpty {
        Button(allSelectableSelected ? "Deselect All" : "Select All") {
          if allSelectableSelected {
            selected.removeAll()
          } else {
            selected = Set(selectableIDs)
          }
        }
        .font(.system(size: 11.5, weight: .medium))
        .buttonStyle(MacSecondaryButtonStyle())
        .disabled(isSaving)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(MacDesignTokens.Colors.surface.opacity(0.45))
  }

  private func candidateRow(_ candidate: MacResponseImageCandidate) -> some View {
    let isSaved = savedIDs.contains(candidate.id)
    let isCurrentlySaving = savingID == candidate.id
    let isSelected = selected.contains(candidate.id)
    let previewFailed = failedPreviewIDs.contains(candidate.id)

    return Button {
      guard !isSaved, !isSaving else { return }
      if !selected.insert(candidate.id).inserted {
        selected.remove(candidate.id)
      }
    } label: {
      HStack(spacing: 12) {
        MacResponseImageCandidateThumbnail(
          candidate: candidate,
          onByteCountLoaded: { byteCount in
            if loadedByteCounts[candidate.id] != byteCount {
              loadedByteCounts[candidate.id] = byteCount
            }
          },
          onLoadStateChanged: { failed in
            if failed {
              failedPreviewIDs.insert(candidate.id)
            } else {
              failedPreviewIDs.remove(candidate.id)
            }
          }
        )

        VStack(alignment: .leading, spacing: 3) {
          Text(candidate.label)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .lineLimit(1)

          Text(detail(for: candidate, previewFailed: previewFailed))
            .font(.caption)
            .foregroundStyle(
              previewFailed
                ? Color.orange
                : MacDesignTokens.Colors.textMuted
            )
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer(minLength: 8)

        if isCurrentlySaving {
          ProgressView()
            .controlSize(.small)
        } else if isSaved {
          Label("Saved", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
        } else {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 19))
            .foregroundStyle(
              isSelected
                ? MacDesignTokens.Colors.accent
                : MacDesignTokens.Colors.textMuted.opacity(0.55)
            )
            .symbolRenderingMode(.hierarchical)
        }
      }
      .padding(10)
      .background(
        isSelected && !isSaved
          ? MacDesignTokens.Colors.accentSoft.opacity(0.55)
          : MacDesignTokens.Colors.surface,
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
          .stroke(
            isSelected && !isSaved
              ? MacDesignTokens.Colors.accent.opacity(0.45)
              : MacDesignTokens.Colors.separator.opacity(0.75),
            lineWidth: 0.75
          )
      }
      .contentShape(Rectangle())
      .opacity(isSaving && !isCurrentlySaving && !isSaved ? 0.6 : 1)
    }
    .buttonStyle(.plain)
    .disabled(isSaving || isSaved)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func detail(for candidate: MacResponseImageCandidate, previewFailed: Bool) -> String {
    switch candidate.source {
    case .url(let url):
      let host = url.host(percentEncoded: false) ?? url.host ?? "Remote image"
      let cachedBytes = MacMarkdownImageSupport.cachedRawBytes(
        for: MacMarkdownImageSupport.cacheKey(for: url)
      )
      let byteCount = loadedByteCounts[candidate.id] ?? cachedBytes?.count
      if let byteCount {
        let size = ByteCountFormatter.string(
          fromByteCount: Int64(byteCount),
          countStyle: .file
        )
        let typeLabel = cachedBytes.map {
          shortTypeLabel(for: MacResponseImageScanner.mimeType(for: $0, filename: url.lastPathComponent))
        }
        if let typeLabel {
          return "\(host) · \(typeLabel) · \(size)"
        }
        return "\(host) · \(size)"
      }
      return previewFailed ? "\(host) · Preview unavailable" : host

    case .data(let data, let fileExtension):
      let size = ByteCountFormatter.string(
        fromByteCount: Int64(data.count),
        countStyle: .file
      )
      let typeLabel = shortTypeLabel(
        for: MacResponseImageScanner.mimeType(for: data, filename: "image.\(fileExtension)")
      )
      return previewFailed ? "\(typeLabel) · \(size) · Preview unavailable" : "\(typeLabel) · \(size)"
    }
  }

  private func shortTypeLabel(for mimeType: String) -> String {
    let subtype = mimeType.split(separator: "/").last.map(String.init) ?? mimeType
    return subtype == "jpeg" ? "JPEG" : subtype.uppercased()
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
      guard MacResponseImageScanner.isValidImageData(data) else {
        failures.append("\(candidate.label) isn't a valid image.")
        continue
      }

      let initialFilename = MacResponseImageScanner.suggestedFilename(
        for: candidate.source,
        fallbackIndex: index + 1
      )
      let mimeType = MacResponseImageScanner.mimeType(for: data, filename: initialFilename)
      let filename = MacResponseImageScanner.suggestedFilename(
        for: candidate.source,
        fallbackIndex: index + 1,
        resolvedMimeType: mimeType
      )

      let added = await workspace.saveLibraryItem(
        filename: filename,
        mimeType: mimeType,
        data: data,
        source: .chat(conversationID: conversationID, messageID: messageID),
        successMessage: nil
      )

      // Keep only unsaved selections for retry, without duplicating successes.
      if added != nil {
        selected.remove(candidate.id)
        savedIDs.insert(candidate.id)
        savedCount += 1
      } else {
        let reason = workspace.errorMessage ?? "Couldn't save to Library."
        failures.append("\(candidate.label): \(reason)")
      }
    }

    if savedCount > 0 {
      workspace.statusMessage = savedCount == 1
        ? "Saved image to Library"
        : "Saved \(savedCount) images to Library"
      onSaved(savedCount)
    }

    if !failures.isEmpty {
      MacAppAnalytics.reportError("library_share_failed", component: "library")
      errorMessage = failures.joined(separator: "\n")
    } else {
      dismiss()
    }
  }

  private func fetchData(for source: MacResponseImageCandidate.Source) async -> Data? {
    if case .url(let url) = source {
      let cacheKey = MacMarkdownImageSupport.cacheKey(for: url)
      if let cached = MacMarkdownImageSupport.cachedRawBytes(for: cacheKey),
        !cached.isEmpty,
        cached.count <= LibraryStore.maxByteCount
      {
        return cached
      }
    }
    return await MacResponseImageScanner.fetchData(
      for: source,
      maxByteCount: LibraryStore.maxByteCount
    )
  }
}

@MainActor
private final class MacResponseImageThumbnailCache {
  static let shared = MacResponseImageThumbnailCache()

  private let storage: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 64
    return cache
  }()

  func image(forKey key: String) -> NSImage? {
    storage.object(forKey: key as NSString)
  }

  func insert(_ image: NSImage, forKey key: String) {
    storage.setObject(image, forKey: key as NSString)
  }
}

private struct MacResponseImageCandidateThumbnail: View {
  let candidate: MacResponseImageCandidate
  var onByteCountLoaded: (Int) -> Void = { _ in }
  var onLoadStateChanged: (Bool) -> Void = { _ in }

  @Environment(\.displayScale) private var displayScale
  @State private var loadedImage: NSImage?
  @State private var isLoading = false
  @State private var didFail = false

  private let tileSize: CGFloat = 56

  private var pixelSize: CGFloat {
    ceil(tileSize * max(displayScale, 1))
  }

  private var cacheKey: String {
    let base: String
    switch candidate.source {
    case .url(let url):
      base = MacMarkdownImageSupport.cacheKey(for: url)
    case .data:
      base = "respimg::\(candidate.id)"
    }
    return "\(base)@\(Int(pixelSize.rounded()))"
  }

  var body: some View {
    let displayed = loadedImage ?? MacResponseImageThumbnailCache.shared.image(forKey: cacheKey)

    ZStack {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
        .fill(MacDesignTokens.Colors.canvas.opacity(0.75))

      if let displayed {
        Image(nsImage: displayed)
          .resizable()
          .scaledToFill()
          .frame(width: tileSize, height: tileSize)
          .clipped()
      } else if isLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: didFail ? "exclamationmark.triangle" : "photo")
          .font(.system(size: 17))
          .foregroundStyle(
            didFail ? Color.orange : MacDesignTokens.Colors.textMuted.opacity(0.55)
          )
      }
    }
    .frame(width: tileSize, height: tileSize)
    .clipShape(RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.8), lineWidth: 0.75)
    }
    .task(id: candidate.id) {
      await loadThumbnail()
    }
  }

  private func loadThumbnail() async {
    let key = cacheKey
    let maxPixels = pixelSize

    if let cached = MacResponseImageThumbnailCache.shared.image(forKey: key) {
      loadedImage = cached
      isLoading = false
      didFail = false
      onLoadStateChanged(false)
      return
    }

    isLoading = true
    didFail = false
    defer { isLoading = false }

    let rawData: Data?
    switch candidate.source {
    case .data(let data, _):
      rawData = data
    case .url(let url):
      rawData = await MacMarkdownImageSupport.loadBytes(for: url)?.data
    }

    guard !Task.isCancelled else { return }

    if let rawData {
      onByteCountLoaded(rawData.count)
    }

    guard let rawData, !rawData.isEmpty else {
      didFail = true
      onLoadStateChanged(true)
      return
    }

    let decodedImage: NSImage?
    if let cgImage = await MacResponseImageScanner.decodeThumbnailCGImage(
      from: rawData,
      maxPixelSize: maxPixels
    ) {
      decodedImage = NSImage(
        cgImage: cgImage,
        size: NSSize(width: cgImage.width, height: cgImage.height)
      )
    } else {
      decodedImage = NSImage(data: rawData)
    }

    guard !Task.isCancelled else { return }
    guard let decodedImage else {
      didFail = true
      onLoadStateChanged(true)
      return
    }

    MacResponseImageThumbnailCache.shared.insert(decodedImage, forKey: key)
    loadedImage = decodedImage
    didFail = false
    onLoadStateChanged(false)
  }
}
