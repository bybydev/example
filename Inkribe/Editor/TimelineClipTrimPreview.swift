@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Observation

/// Bounded boundary-frame audition using the existing shared media graph and
/// frame helper. No additional AVPlayer, temporary export, save or speech work.
@MainActor @Observable
final class TimelineClipTrimPreview {
    let plan: TimelineClipTrim
    let frame = CaptionPreviewFrame()
    let snapshot: CaptionSnapshot
    let audioOnly: Bool
    @ObservationIgnored private let document: ProjectDocument
    @ObservationIgnored private let urls: [UUID: URL]
    @ObservationIgnored private let onError: (String) -> Void
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var closed = false
    private var pending = MediaTime.zero
    private var lastFinished: MediaTime?

    init(plan: TimelineClipTrim, document: ProjectDocument, urls: [UUID: URL], onError: @escaping (String) -> Void) {
        self.plan = plan; self.urls = urls; self.onError = onError
        var audition = document
        var media = audition.effectiveMediaEdits; media.trim = plan.clip.timelineInterval
        audition.mediaEdits = media
        var settings = audition.settings(for: plan.clip.id); settings.sourceTrim = nil
        audition.setSettings(settings)
        // Boundary audition is paused; soundtrack timing still belongs to the
        // complete project's output clock and is never modified by this view.
        audition.music = nil
        audition.schemaVersion = ProjectSchema.current
        self.document = audition
        snapshot = CaptionSnapshot(audition)
        audioOnly = document.assets.first { $0.id == plan.clip.sourceAssetID }?.kind == .audio
    }

    func update(_ range: ClipSourceTrim) {
        guard !closed else { return }
        let point: CMTime
        if plan.edge == .end {
            let length = CMTimeSubtract(range.end.cmTime, range.start.cmTime)
            point = CMTimeSubtract(range.end.cmTime, CMTimeMinimum(CMTime(value: 1, timescale: 60_000),
                CMTimeMultiplyByFloat64(length, multiplier: 0.5)))
        } else { point = range.start.cmTime }
        let last = CMTimeSubtract(plan.clip.sourceInterval.end.cmTime,
            CMTimeMinimum(CMTime(seconds: 1 / plan.frameRate, preferredTimescale: 60_000), plan.clip.sourceInterval.duration))
        let bounded = CMTimeMaximum(plan.clip.sourceInterval.start.cmTime, CMTimeMinimum(point, last))
        guard let time = try? MediaTime(validating: CMTimeSubtract(bounded, plan.clip.sourceInterval.start.cmTime)) else { return }
        if time == pending && (worker != nil || lastFinished == time) { return }
        pending = time
        frame.cancel()
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            do {
                if self.item == nil {
                    self.item = try await PreviewComposition.make(document: self.document, urls: self.urls)
                }
                while !self.closed && !Task.isCancelled {
                    let requested = self.pending
                    let captured = await self.frame.capture(item: self.item, at: requested, audioOnly: self.audioOnly, preservingImage: true)
                    if captured { self.lastFinished = requested }
                    guard !self.closed, !Task.isCancelled else { return }
                    if let error = self.frame.error { self.onError(error) }
                    if self.pending == requested { break }
                }
            } catch {
                if !self.closed, !Task.isCancelled { self.onError(error.localizedDescription) }
            }
        }
    }
    func close() {
        closed = true; worker?.cancel(); frame.clear(); item = nil
    }
}
