import JobQueue
@preconcurrency import Photos
import SwiftUI

private struct IOSExportDeliveryPresentation: Identifiable {
    enum Kind: Equatable { case files, share }
    let id = UUID()
    let kind: Kind
    let url: URL
}

struct IOSExportView: View {
    @Environment(IOSProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: IOSEditorSession?
    @State private var profile = IOSExportProfile()
    @State private var launching = false
    @State private var launchTask: Task<Void, Never>?
    @State private var error: String?
    @State private var message: String?
    @State private var delivery: IOSExportDeliveryPresentation?
    @State private var deliveryToken: UUID?
    @State private var savingPhotos = false
    @State private var confirmDiscard = false
    private var exports: IOSExportController { model.exports }

    var body: some View {
        NavigationStack {
            Form {
                if let session {
                    Section("Export this project") {
                        Text(session.document?.title ?? "Project").font(.headline)
                        Picker("Format", selection: $profile.format) {
                            ForEach(IOSExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        if profile.format == .mp4 {
                            Picker("Resolution", selection: $profile.resolution) {
                                ForEach(IOSExportResolution.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            if let canvas = session.document?.canvas, let output = try? profile.resolution.canvas(for: canvas) {
                                LabeledContent("Output", value: "\(output.width) × \(output.height) · 30 fps")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("H.264 MP4 with burned-in captions and original audio. Audio-only projects use a black canvas.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("UTF-8 subtitles with your edited text and project timing. Fonts and animations are part of video exports.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button {
                            launch()
                        } label: {
                            if launching || exports.isPreparing { ProgressView("Preparing export…") }
                            else { Label(exports.record == nil ? "Export" : "Start new export", systemImage: "square.and.arrow.up") }
                        }
                        .disabled(launching || exports.isPreparing || exports.isActive || exports.isDelivering
                            || exports.persistenceError != nil || session.document == nil
                            || (profile.format == .srt && !hasCaptions))
                        if profile.format == .srt && !hasCaptions {
                            Text("Transcribe the media and keep at least one visible caption to export SRT.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if exports.record != nil {
                            Text("Starting a new export replaces the previous local export file. Save it first if you want to keep it.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if launching {
                            Button("Cancel preparation", role: .cancel) { launchTask?.cancel() }
                        }
                    }
                }
                if let record = exports.record {
                    Section("Current export") {
                        if let title = exports.frozenTitle { Text(title).font(.headline) }
                        Text("Uses the captions and media saved when this export started.")
                            .font(.caption).foregroundStyle(.secondary)
                        status(record)
                    }
                }
                if let storageError = exports.persistenceError {
                    Section {
                        Text(storageError).foregroundStyle(.red)
                        Button("Retry export storage") { Task { await exports.retryStorage() } }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if let message { Section { Text(message).foregroundStyle(.secondary) } }
                Section {
                    Text("Keep Inkribe open while exporting. If interrupted, the export starts again when you return. Completed files stay here until replaced or discarded.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.disabled(launching || exports.isPreparing || exports.isDelivering)
                }
            }
            .interactiveDismissDisabled(launching || exports.isPreparing || exports.isDelivering)
            .sheet(item: $delivery, onDismiss: endDelivery) { destination in
                if destination.kind == .files {
                    IOSExportFilesPicker(url: destination.url) { saved in
                        if saved { message = "Saved to Files." }
                        endDelivery()
                        delivery = nil
                    }
                    .interactiveDismissDisabled()
                } else {
                    IOSExportShareSheet(url: destination.url) { completed, failure in
                        if let failure { error = failure }
                        else if completed { message = "Sharing finished." }
                        endDelivery()
                        delivery = nil
                    }
                    .interactiveDismissDisabled()
                }
            }
            .confirmationDialog("Discard this local export?", isPresented: $confirmDiscard) {
                Button("Discard export", role: .destructive) {
                    Task {
                        do { try await exports.discard(); await model.refreshStorage() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } message: { Text("Your project, captions and original media are preserved.") }
            .task { await exports.start(); await exports.refreshArtifact() }
        }
    }

    private var hasCaptions: Bool {
        guard let snapshot = session?.snapshot else { return false }
        return snapshot.cues.contains { !snapshot.text(for: $0).isEmpty }
    }

    @ViewBuilder
    private func status(_ record: JobRecord) -> some View {
        let progress = exports.queue?.liveProgress[record.id]
        if !record.status.isTerminal {
            Text(exports.queue?.isPaused == true ? "Paused. Return to the app to restart rendering." :
                record.status == .cancelling ? "Cancelling…" : progress?.message ?? "Preparing export…")
            if let fraction = progress?.fractionCompleted { ProgressView(value: fraction) }
            else { ProgressView() }
            Button("Cancel export", role: .cancel) { perform { try exports.cancel() } }
                .disabled(record.status == .cancelling)
        } else if record.status == .completed {
            if let url = exports.completedURL {
                Label("Ready to save or share", systemImage: "checkmark.circle")
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                if url.pathExtension.lowercased() == "mp4" {
                    Button("Save to Photos", systemImage: "photo.on.rectangle") { saveToPhotos() }
                        .disabled(exports.isDelivering || exports.isPreparing)
                }
                Button("Save to Files", systemImage: "folder") { present(.files) }
                    .disabled(exports.isDelivering || exports.isPreparing)
                Button("Share…", systemImage: "square.and.arrow.up") { present(.share) }
                    .disabled(exports.isDelivering || exports.isPreparing)
                if savingPhotos { ProgressView("Saving to Photos…") }
            } else {
                Text("This export file is unavailable. Start a new export.").foregroundStyle(.secondary)
            }
        } else {
            Text(record.status == .cancelled ? "Export cancelled." : record.error ?? "Export could not finish.")
                .foregroundStyle(.secondary).textSelection(.enabled)
            if record.status.isRetryable {
                Button("Retry saved export", systemImage: "arrow.clockwise") { perform { try exports.retry() } }
                    .disabled(exports.isPreparing || exports.isDelivering)
            }
        }
        if record.status.isTerminal {
            Button("Discard local export", systemImage: "trash", role: .destructive) { confirmDiscard = true }
                .disabled(exports.isPreparing || exports.isDelivering || exports.queue?.isProcessing == true)
        }
    }

    private func launch() {
        guard let session else { return }
        launching = true
        error = nil
        message = nil
        session.pause()
        session.endTyping()
        session.endStyleEditing()
        let selected = profile
        launchTask = Task {
            defer { launching = false; launchTask = nil }
            do {
                let document = try await session.savedDocument()
                try Task.checkCancellation()
                try await exports.enqueue(document: document, profile: selected)
                await model.refreshStorage()
            } catch is CancellationError {
                message = "Export cancelled."
            } catch { self.error = error.localizedDescription }
        }
    }

    private func present(_ kind: IOSExportDeliveryPresentation.Kind) {
        perform {
            let lease = try exports.beginDelivery()
            deliveryToken = lease.token
            delivery = IOSExportDeliveryPresentation(kind: kind, url: lease.url)
        }
    }
    private func endDelivery() {
        if let token = deliveryToken { exports.endDelivery(token) }
        deliveryToken = nil
    }
    private func perform(_ action: () throws -> Void) {
        error = nil
        message = nil
        do { try action() } catch { self.error = error.localizedDescription }
    }
    private func saveToPhotos() {
        perform {
            let lease = try exports.beginDelivery()
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
        }
    }
}
