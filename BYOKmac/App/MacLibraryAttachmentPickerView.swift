import BYOKchatProviderCore
import SwiftUI

struct MacLibraryAttachmentPickerView: View {
  @Bindable var workspace: MacWorkspaceModel
  let excludedIDs: Set<String>
  let attach: ([ChatAttachment]) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selection: Set<LibraryEntryID> = []
  @State private var isLoading = false

  private var availableEntries: [LibraryEntry] {
    workspace.libraryEntries.filter { !excludedIDs.contains($0.id.rawValue) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Attach from Library")
          .font(.headline)
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Attach") { commit() }
          .keyboardShortcut(.defaultAction)
          .disabled(selection.isEmpty || isLoading)
      }
      .padding(16)

      Divider()

      if availableEntries.isEmpty {
        ContentUnavailableView(
          "No Available Library Items",
          systemImage: "books.vertical",
          description: Text("Import files into Library or remove an already selected attachment.")
        )
      } else {
        List(availableEntries, selection: $selection) { entry in
          HStack(spacing: 10) {
            Image(systemName: entry.isImage ? "photo" : "doc")
              .foregroundStyle(MacDesignTokens.Colors.accent)
              .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.filename)
                .lineLimit(1)
              Text("\(entry.byteCountText) · \(entry.mimeType)")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .lineLimit(1)
            }
          }
          .tag(entry.id)
        }
      }
    }
    .frame(width: 560, height: 440)
    .background(MacDesignTokens.Colors.canvas)
    .overlay {
      if isLoading {
        ProgressView()
          .padding(12)
          .background(.regularMaterial, in: Capsule())
      }
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

  private func commit() {
    guard !selection.isEmpty, !isLoading else { return }
    isLoading = true
    Task { @MainActor in
      var values: [ChatAttachment] = []
      for entry in availableEntries where selection.contains(entry.id) {
        if let attachment = await workspace.attachment(for: entry) {
          values.append(attachment)
        }
      }
      isLoading = false
      guard !values.isEmpty else { return }
      attach(values)
      dismiss()
    }
  }
}
