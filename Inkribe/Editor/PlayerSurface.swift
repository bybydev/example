@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// AVPlayerLayer supplies footage only. All transport actions use the editor's project clock.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        view.backgroundColor = .black
        return view
    }
    func updateUIView(_ uiView: Surface, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
    static func dismantleUIView(_ uiView: Surface, coordinator: ()) { uiView.playerLayer.player = nil }

    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
