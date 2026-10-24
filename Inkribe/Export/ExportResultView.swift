@preconcurrency import Photos
import SwiftUI

private struct ExportDeliveryPresentation: Identifiable {
    enum Kind { case files, share }
    let id = UUID()
    let kind: Kind
    let url: URL
}

/// Every button and native callback captures this job's lease, never selection.
struct ExportResultView: View {
    @Environment(ProjectsModel.self) private var model
    let jobID: UUID
    @State private var delivery: ExportDeliveryPresentation?
    @State private var deliveryToken: UUID?
    @State private var savingPhotos = false
    @State private var error: String?
    @State private var message: String?
    private var exports: ExportController { model.exports }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let artifact = exports.artifacts[jobID], let url = artifact.outputURL {
                Label("Ready to save or share", systemImage: "checkmark.circle")
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                if artifact.profile?.format == .mp4 {
                    Button("Save to Photos", systemImage: "photo.on.rectangle", action: saveToPhotos)
                        .disabled(savingPhotos || delivery != nil)
                }
                Button("Save to Files", systemImage: "folder") { present(.files) }
                    .disabled(savingPhotos || delivery != nil)
                Button("Share…", systemImage: "square.and.arrow.up") { present(.share) }
                    .disabled(savingPhotos || delivery != nil)
            } else {
                Text("The completed file is unavailable. Your project and saved captions are preserved; create a new export from the project.")
                    .foregroundStyle(.secondary)
            }
            if savingPhotos { ProgressView("Saving to Photos…") }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .buttonStyle(.borderless)
        .sheet(item: $delivery, onDismiss: endDelivery) { destination in
            if destination.kind == .files {
                ExportFilesPicker(url: destination.url) { saved in
                    if saved { message = "Saved to Files." }
                    endDelivery()
                    delivery = nil
                }
                .interactiveDismissDisabled()
            } else {
                ExportShareSheet(url: destination.url) { completed, failure in
                    if let failure { error = failure }
                    else if completed { message = "Sharing finished." }
                    endDelivery()
                    delivery = nil
                }
                .interactiveDismissDisabled()
            }
        }
    }

    private func present(_ kind: ExportDeliveryPresentation.Kind) {
        error = nil; message = nil
        do {
            let lease = try exports.beginDelivery(jobID)
            deliveryToken = lease.token
            delivery = ExportDeliveryPresentation(kind: kind, url: lease.url)
        } catch { self.error = error.localizedDescription }
    }
    private func endDelivery() {
        if let token = deliveryToken { exports.endDelivery(token) }
        deliveryToken = nil
    }
    private func saveToPhotos() {
        error = nil; message = nil
        do {
            let lease = try exports.beginDelivery(jobID)
            savingPhotos = true
            Task {
                defer { exports.endDelivery(lease.token); savingPhotos = false }
                do {
                    let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    guard authorization == .authorized || authorization == .limited else {
                        error = "Allow Inkribe to add videos in Settings, or save to Files instead."
                        return
                    }
                    try await PHPhotoLibrary.shared().performChanges {
                        let creation = PHAssetCreationRequest.forAsset()
                        creation.addResource(with: .video, fileURL: lease.url, options: nil)
                    }
                    message = "Saved to Photos."
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
