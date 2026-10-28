@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// A mounted host keeps a still while the single live layer belongs elsewhere.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let frames: PreviewFrameBuffer
    let generation: UUID
    let snapshot: CaptionSnapshot?
    let time: MediaTime
    var isActive = true
    let onPresentation: (PreviewHeldFrame?) -> Void

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.configure(player: player, frames: frames, generation: generation,
            snapshot: snapshot, time: time, active: isActive, onPresentation: onPresentation)
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.tearDown() }

    @MainActor
    final class Surface: UIView, PreviewVideoOwner {
        private let video = AVPlayerLayer()
        private let still = UIImageView()
        private weak var player: AVPlayer?
        private weak var frames: PreviewFrameBuffer?
        private weak var item: AVPlayerItem?
        private var mediaGeneration: UUID?
        private var snapshot: CaptionSnapshot?
        private var time = MediaTime.zero
        private var requestedActive = false
        private var held: PreviewHeldFrame?
        private var readiness: NSKeyValueObservation?
        private var transition = UUID()
        private var publishedLive: Bool?
        private var publishedFrameID: UUID?
        private var onPresentation: ((PreviewHeldFrame?) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            video.videoGravity = .resizeAspect
            layer.addSublayer(video)
            still.contentMode = .scaleAspectFit
            still.backgroundColor = .black
            still.isUserInteractionEnabled = false
            addSubview(still)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            video.frame = bounds
            CATransaction.commit()
            still.frame = bounds
        }

        func configure(player: AVPlayer, frames: PreviewFrameBuffer, generation: UUID,
                       snapshot: CaptionSnapshot?, time: MediaTime, active: Bool,
                       onPresentation: @escaping (PreviewHeldFrame?) -> Void) {
            self.onPresentation = onPresentation
            let newPlayer = self.player !== player
            let newItem = newPlayer || item !== player.currentItem || mediaGeneration != generation
            let changed = newItem || requestedActive != active
            if changed {
                relinquishVideo()
                if newPlayer { held = nil; still.image = nil }
                self.player = player
                self.frames = frames
                item = player.currentItem
                mediaGeneration = generation
                requestedActive = active
            }
            self.snapshot = snapshot
            self.time = time
            guard changed else { return }
            beginTransition()
            if active {
                frames.claim(self)
                // Adopt the outgoing sheet's most recent still on return,
                // rather than revealing this host's older pre-sheet image.
                if let transferred = frames.heldFrame { held = transferred }
                showHeldFrame()
                if let item = player.currentItem, item.videoComposition == nil {
                    // Audio has no first video frame. Keep captions on the live
                    // clock instead of waiting forever for layer readiness.
                    held = nil
                    still.image = nil
                    publish(live: true)
                    return
                }
                video.player = player
                let expected = transition
                readiness = video.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.transition == expected else { return }
                        self.updateReadiness()
                    }
                }
            } else {
                showHeldFrame()
            }
        }

        func relinquishVideo() {
            let wasLive = publishedLive == true
            beginTransition()
            readiness = nil
            if video.player != nil || wasLive {
                // Capture before disconnecting. Failed capture preserves an
                // earlier good still and its caption clock/snapshot.
                if let captured = frames?.capture(at: player?.currentTime() ?? time.cmTime,
                    snapshot: snapshot, presentationTime: time) {
                    held = captured
                }
                showHeldFrame()
                video.player = nil
            }
            frames?.release(self)
        }

        private func showHeldFrame() {
            if held == nil {
                held = frames?.capture(at: player?.currentTime() ?? time.cmTime,
                    snapshot: snapshot, presentationTime: time)
                    ?? PreviewHeldFrame(image: nil, time: time, snapshot: snapshot)
            }
            still.image = held?.image.map { UIImage(cgImage: $0) }
            still.isHidden = false
            publish(live: false)
        }

        private func updateReadiness() {
            guard requestedActive, video.player === player, item === player?.currentItem else { return }
            guard video.isReadyForDisplay else { showHeldFrame(); return }
            // Seed a paused video's fallback before another handoff.
            if let captured = frames?.capture(at: player?.currentTime() ?? time.cmTime,
                snapshot: snapshot, presentationTime: time) {
                held = captured
            }
            publish(live: true)
        }

        private func publish(live: Bool) {
            let frameID = live ? nil : held?.id
            guard publishedLive != live || publishedFrameID != frameID else { return }
            publishedLive = live
            publishedFrameID = frameID
            let expected = transition
            // Deliver outside updateUIView and reject obsolete handoffs.
            Task { @MainActor [weak self] in
                guard let self, self.transition == expected,
                      self.publishedLive == live, self.publishedFrameID == frameID else { return }
                self.onPresentation?(live ? nil : self.held)
                if live { self.still.isHidden = true }
            }
        }

        private func beginTransition() {
            transition = UUID()
            publishedLive = nil
            publishedFrameID = nil
        }

        func tearDown() {
            relinquishVideo()
            transition = UUID()
            onPresentation = nil
            held = nil
            still.image = nil
            player = nil
            frames = nil
            item = nil
        }
    }
}
