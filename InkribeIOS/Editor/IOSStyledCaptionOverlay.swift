import CoreGraphics
import SwiftUI
import UIKit

/// UIKit only adapts coordinate systems. All typography/effects are rendered by
/// IOSCaptionRenderer, including the bitmap/composition interface used by P5.
struct IOSStyledCaptionOverlay: UIViewRepresentable {
    let snapshot: IOSCaptionSnapshot
    let time: MediaTime
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
        guard uiView.snapshot?.id != snapshot.id || uiView.time != time else { return }
        uiView.snapshot = snapshot
        uiView.time = time
        uiView.generation = UUID()
        uiView.setNeedsDisplay()
    }

    final class Surface: UIView {
        var snapshot: IOSCaptionSnapshot?
        var time = MediaTime.zero
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
                try renderer.draw(snapshot: snapshot, at: time, in: context, bounds: bounds)
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
