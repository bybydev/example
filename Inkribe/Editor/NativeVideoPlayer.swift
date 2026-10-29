@preconcurrency import AVKit
import SwiftUI
import UIKit

/// Presents AVKit itself modally, so playback and dismissal use the system UI.
/// An editor borrows its existing player; a completed-file caller owns its player.
@MainActor
struct NativeVideoPlayer: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let player: AVPlayer?
    var session: EditorSession?
    var snapshot: CaptionSnapshot?
    var time = MediaTime.zero
    var mediaGeneration: UUID?
    var onError: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    func makeUIViewController(context: Context) -> Presenter { Presenter() }
    func updateUIViewController(_ host: Presenter, context: Context) {
        host.update(requested: isPresented, player: player, session: session,
            snapshot: snapshot, time: time, mediaGeneration: mediaGeneration, onError: onError) {
                isPresented = false
                onDismiss()
            }
    }
    static func dismantleUIViewController(_ host: Presenter, coordinator: ()) { host.tearDown() }

    @MainActor
    final class Presenter: UIViewController, @MainActor AVPlayerViewControllerDelegate,
        UIAdaptivePresentationControllerDelegate, PreviewVideoOwner {
        private var requested = false
        private var transitioning = false
        private var stopping = false
        private var closing = false
        private var pendingPlayer: AVPlayer?
        private var pendingSession: EditorSession?
        private var player: AVPlayer?
        private var session: EditorSession?
        private var native: AVPlayerViewController?
        private var captions: NativeCaptionOverlay?
        private var observations: [NSKeyValueObservation] = []
        private var inactiveObserver: NSObjectProtocol?
        private var externalPlayback: Bool?
        private var latestSnapshot: CaptionSnapshot?
        private var latestTime = MediaTime.zero
        private var mediaGeneration: UUID?
        private var close: (() -> Void)?
        private var activeClose: (() -> Void)?
        private var report: (String) -> Void = { _ in }

        override func loadView() {
            let surface = UIView()
            surface.isUserInteractionEnabled = false
            surface.backgroundColor = .clear
            view = surface
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Also handles native dismissal paths that don't use adaptive sheets.
            if let native, native.presentingViewController == nil, !transitioning {
                finish(native)
            } else { reconcile() }
        }

        func update(requested: Bool, player: AVPlayer?, session: EditorSession?,
                    snapshot: CaptionSnapshot?, time: MediaTime, mediaGeneration: UUID?,
                    onError: @escaping (String) -> Void, onClose: @escaping () -> Void) {
            guard !stopping else { return }
            self.requested = requested && !closing
            pendingPlayer = player; pendingSession = session
            let mediaChanged = self.mediaGeneration != mediaGeneration
            self.mediaGeneration = mediaGeneration
            latestSnapshot = snapshot; latestTime = time
            report = onError; close = onClose
            if let native, self.player === player {
                if self.requested, !transitioning, native.player == nil {
                    session?.previewFrames.claim(self)
                    native.player = player
                }
                if mediaChanged { observe(native) }
                updateCaptions()
            }
            reconcile()
        }

        private func reconcile() {
            guard !stopping, !transitioning else { return }
            if let native {
                if !requested { dismiss(native, animated: true) }
                return
            }
            guard requested, viewIfLoaded?.window != nil, presentedViewController == nil else { return }
            guard let pendingPlayer, pendingPlayer.currentItem != nil else {
                requested = false; closing = true
                let report = report, close = close
                Task { @MainActor [weak self] in
                    report("This video could not be opened."); close?()
                    self?.closing = false
                }
                return
            }
            let controller = AVPlayerViewController()
            controller.modalPresentationStyle = .fullScreen
            controller.delegate = self
            controller.videoGravity = .resizeAspect
            // These previews stay in-app: live caption overlays aren't part of
            // external video, and file delivery leases end with this presentation.
            controller.allowsPictureInPicturePlayback = false
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            controller.updatesNowPlayingInfoCenter = false
            externalPlayback = pendingPlayer.allowsExternalPlayback
            pendingPlayer.allowsExternalPlayback = false
            player = pendingPlayer; session = pendingSession
            activeClose = close
            native = controller
            transitioning = true
            session?.previewFrames.claim(self)
            controller.player = pendingPlayer
            controller.loadViewIfNeeded()
            if session != nil, let content = controller.contentOverlayView {
                let overlay = NativeCaptionOverlay(controller: controller)
                overlay.frame = content.bounds
                overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                overlay.onError = { [weak self] in self?.report($0) }
                content.addSubview(overlay)
                captions = overlay
                updateCaptions()
            }
            observe(controller)
            present(controller, animated: true) { [weak self, weak controller] in
                guard let self, let controller, self.native === controller else { return }
                self.transitioning = false
                controller.presentationController?.delegate = self
                if self.requested, controller.player == nil {
                    self.session?.previewFrames.claim(self)
                    controller.player = self.player
                    self.observe(controller)
                }
                self.updateCaptions()
                if self.stopping { self.dismiss(controller, animated: false) }
                else { self.reconcile() }
            }
        }

        private func observe(_ controller: AVPlayerViewController) {
            if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver) }
            observations = [
                controller.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] controller, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.native === controller else { return }
                        self.updateCaptions()
                    }
                },
                controller.observe(\.videoBounds, options: [.new]) { [weak self] controller, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.native === controller else { return }
                        self.captions?.setNeedsLayout()
                    }
                }
            ]
            if let item = player?.currentItem {
                observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let error = item.status == .failed ? item.error?.localizedDescription ?? "This video could not be played." : nil
                    Task { @MainActor [weak self] in
                        guard let self, self.native === controller, self.player?.currentItem === item,
                              let error else { return }
                        self.player?.pause()
                        self.report(error)
                        self.closing = true; self.requested = false
                        self.reconcile()
                    }
                })
            }
            inactiveObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.native === controller else { return }
                        self.player?.pause()
                        self.session?.pause()
                    }
                }
        }

        private func updateCaptions() {
            captions?.update(snapshot: latestSnapshot, time: latestTime, held: session?.previewFrames.heldFrame)
        }

        func relinquishVideo() {
            session?.holdPreviewFrame()
            native?.player = nil
            session?.previewFrames.release(self)
        }

        private func dismiss(_ controller: AVPlayerViewController, animated: Bool) {
            guard native === controller, !transitioning else { return }
            transitioning = true
            player?.pause(); session?.pause()
            controller.dismiss(animated: animated) { [self] in finish(controller) }
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator) {
            guard native === playerViewController else { return }
            transitioning = true
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                let cancelled = context.isCancelled
                Task { @MainActor [weak self] in
                    guard let self, self.native === playerViewController else { return }
                    self.transitioning = false
                    if !cancelled { self.finish(playerViewController) }
                    else if self.stopping { self.dismiss(playerViewController, animated: false) }
                    else { self.reconcile() }
                }
            }
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            if let native, presentationController.presentedViewController === native { finish(native) }
        }

        private func finish(_ controller: AVPlayerViewController) {
            guard native === controller else { return }
            player?.pause(); session?.pause()
            relinquishVideo()
            if let externalPlayback { player?.allowsExternalPlayback = externalPlayback }
            observations.removeAll()
            if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver) }
            inactiveObserver = nil
            captions?.removeFromSuperview(); captions = nil
            controller.delegate = nil
            controller.presentationController?.delegate = nil
            native = nil; player = nil; session = nil; externalPlayback = nil
            requested = false; transitioning = false; closing = true
            let callback = activeClose
            activeClose = nil
            // Binding writes must not occur during a representable update/teardown.
            Task { @MainActor [weak self] in
                callback?()
                self?.closing = false
            }
        }

        func tearDown() {
            let wasRequested = requested
            stopping = true; requested = false
            guard let native else {
                if wasRequested {
                    let callback = close
                    Task { @MainActor in callback?() }
                }
                return
            }
            player?.pause(); session?.pause()
            if !transitioning { dismiss(native, animated: false) }
        }
    }
}

/// Uses the existing caption drawing adapter in AVKit's public overlay area.
/// Video bounds keep captions aligned during rotation and native zoom-to-fill.
@MainActor
private final class NativeCaptionOverlay: UIView {
    private weak var controller: AVPlayerViewController?
    private let still = UIImageView()
    private let captionSurface = StyledCaptionOverlay.Surface()
    private var snapshot: CaptionSnapshot?
    private var time = MediaTime.zero
    private var held: PreviewHeldFrame?
    var onError: (String) -> Void = { _ in }

    init(controller: AVPlayerViewController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .clear; isUserInteractionEnabled = false; clipsToBounds = true
        still.contentMode = .scaleAspectFit; still.backgroundColor = .clear
        addSubview(still)
        captionSurface.backgroundColor = .clear; captionSurface.isOpaque = false
        captionSurface.isUserInteractionEnabled = false; captionSurface.contentMode = .redraw
        captionSurface.onError = { [weak self] error in if let error { self?.onError(error) } }
        addSubview(captionSurface)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(snapshot: CaptionSnapshot?, time: MediaTime, held: PreviewHeldFrame?) {
        self.snapshot = snapshot; self.time = time; self.held = held
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let controller else { return }
        let waiting = !controller.isReadyForDisplay && controller.player?.currentItem?.videoComposition != nil
        let displayed = waiting ? held?.snapshot ?? snapshot : snapshot
        let clock = waiting ? held?.time ?? time : time
        let viewport = controller.videoBounds
        let valid = viewport.width.isFinite && viewport.height.isFinite && viewport.width > 0 && viewport.height > 0
        let videoFrame = valid ? convert(viewport, from: controller.view) : bounds
        still.frame = videoFrame
        still.image = waiting ? held?.image.map { UIImage(cgImage: $0) } : nil
        still.isHidden = !waiting
        captionSurface.frame = videoFrame
        captionSurface.snapshot = displayed; captionSurface.time = clock
        if let displayed { captionSurface.mediaSize = PreviewComposition.previewSize(for: displayed.canvas) }
        captionSurface.generation = UUID()
        captionSurface.setNeedsDisplay()
        accessibilityLabel = displayed?.evaluate(at: clock)?.text
        isAccessibilityElement = accessibilityLabel != nil
    }
}
