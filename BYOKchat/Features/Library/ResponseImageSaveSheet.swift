import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// Confirmation sheet for "Save Images…" on a chat message: lists image
/// candidates found in the reply, downloads the selected ones, and files them
/// into the library with provenance back to this message.
struct ResponseImageSaveSheet: View {
  let candidates: [ResponseImageCandidate]
  let conversationID: ConversationID
  let messageID: ChatMessageID
  let library: LibraryManagementModel
  let onError: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var selected: Set<String> = []
  @State private var isSaving = false

  var body: some View {
    NavigationStack {
      List(candidates) { candidate in
        Button {
          if !selected.insert(candidate.id).inserted {
            selected.remove(candidate.id)
          }
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(candidate.label)
                .font(.body.weight(.medium))
                .foregroundStyle(theme.primaryForegroundColor)
                .lineLimit(1)
              Text(detail(for: candidate))
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: selected.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 20))
              .foregroundStyle(selected.contains(candidate.id) ? theme.accentColor : theme.secondaryForegroundColor)
              .symbolRenderingMode(.hierarchical)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(theme.backgroundColor)
      .navigationTitle("Save Images")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          if isSaving {
            ProgressView().controlSize(.small)
          } else {
            Button("Save\(selected.isEmpty ? "" : " (\(selected.count))")") {
              Task { await saveSelection() }
            }
            .disabled(selected.isEmpty)
          }
        }
      }
    }
    .presentationDragIndicator(.visible)
    .onAppear {
      // Default to saving everything found.
      if selected.isEmpty {
        selected = Set(candidates.map(\.id))
      }
    }
  }

  private func detail(for candidate: ResponseImageCandidate) -> String {
    switch candidate.source {
    case .url(let url): url.host ?? "link"
    case .data: "embedded in reply"
    }
  }

  private func saveSelection() async {
    isSaving = true
    defer { isSaving = false }

    var savedCount = 0
    for (index, candidate) in candidates.enumerated()
    where selected.contains(candidate.id) {
      guard
        let data = await ResponseImageScanner.fetchData(
          for: candidate.source,
          maxByteCount: LibraryStore.maxByteCount
        )
      else {
        onError("Couldn't fetch \(candidate.label).")
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
        source: .chat(conversationID: conversationID, messageID: messageID)
      )
      if added != nil { savedCount += 1 }
    }
    dismiss()
  }

  /// Sniff the encoding rather than trusting the link; adapters and viewers
  /// both assume a real image payload.
  private static func mimeType(for data: Data, filename: String) -> String {
    if data.prefix(2) == Data([0xFF, 0xD8]) { return "image/jpeg" }
    if data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
      return "image/png"
    }
    if data.prefix(6) == Data("GIF89a".utf8) || data.prefix(6) == Data("GIF87a".utf8) {
      return "image/gif"
    }
    if data.prefix(4) == Data("RIFF".utf8), data.subdata(in: 8..<12) == Data("WEBP".utf8) {
      return "image/webp"
    }
    return filename.hasSuffix(".png") ? "image/png" : "image/jpeg"
  }
}
