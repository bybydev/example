import CoreGraphics
import SwiftUI
import UIKit

/// UIKit only adapts coordinate systems. All typography/effects are rendered by
/// IOSCaptionRenderer, including the bitmap/composition interface used by P5.
struct IOSStyledCaptionOverlay: UIViewRepresentable {
    let snapshot: IOSCaptionSnapshot
    let time: MediaTime
    let mediaSize: CGSize
    let onError: (String?) -> Void

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.contentMode = .redraw
        return view
    }
    func updateUIView(_ uiView: Surface, context: Context) {
        uiView.onError = onError
        guard uiView.snapshot?.id != snapshot.id || uiView.time != time || uiView.mediaSize != mediaSize else { return }
        uiView.snapshot = snapshot
        uiView.time = time
        uiView.mediaSize = mediaSize
        uiView.generation = UUID()
        uiView.setNeedsDisplay()
    }

    final class Surface: UIView {
        var snapshot: IOSCaptionSnapshot?
        var time = MediaTime.zero
        var mediaSize = CGSize.zero
        var onError: ((String?) -> Void)?
        var generation = UUID()
        private let renderer = IOSCaptionRenderer()
        private var reportedError: String?

        override func draw(_ rect: CGRect) {
            guard let snapshot, let context = UIGraphicsGetCurrentContext() else { return }
            let message: String?
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            do {
                guard mediaSize.width > 0, mediaSize.height > 0 else { throw IOSCaptionRenderError.invalidFrame }
                // Match AVPlayerLayer's actual raster viewport before fitting the
                // project canvas. Even-pixel rounding must not shift captions.
                let fit = min(bounds.width / mediaSize.width, bounds.height / mediaSize.height)
                let viewport = CGRect(x: bounds.midX - mediaSize.width * fit / 2,
                    y: bounds.midY - mediaSize.height * fit / 2,
                    width: mediaSize.width * fit, height: mediaSize.height * fit)
                try renderer.draw(snapshot: snapshot, at: time, in: context, bounds: viewport)
                message = nil
            } catch { message = error.localizedDescription }
            context.restoreGState()
            guard message != reportedError else { return }
            let expected = generation
            // Never mutate SwiftUI state during drawing or publish a stale frame's error.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expected else { return }
                self.reportedError = message
                self.onError?(message)
            }
        }
    }
}
