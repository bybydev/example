import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Foundation

/// Historical P0 feasibility spike. Shipping styled preview and P5 adapters use
/// IOSCaptionRenderer with IOSCaptionSnapshot, not this fixture-only path.
/// Frame decode/scheduling, audio, timeline effects and file export are NOT P0 features.
struct ClipFrameCompositor {
    private let evaluator = CaptionSceneEvaluator()

    func composedFrame(
        decodedClipFrame: CIImage,
        snapshot: CaptionRenderSnapshot,
        at projectTime: MediaTime
    ) throws -> CIImage {
        guard snapshot.clip.sourceTime(at: projectTime) != nil else {
            throw CaptionSpikeError.clipNotActive
        }

        let canvas = snapshot.canvas
        let target = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let sourceBounds = decodedClipFrame.extent
        guard sourceBounds.width > 0, sourceBounds.height > 0,
              sourceBounds.width.isFinite, sourceBounds.height.isFinite else {
            throw CaptionSpikeError.renderContextUnavailable
        }

        // The incoming clip is already decoded and oriented by its future adapter.
        // P6 will replace the identity clip mapper; no independent animation clock.
        let fillScale = max(
            target.width / sourceBounds.width,
            target.height / sourceBounds.height
        )
        let normalized = decodedClipFrame
            .transformed(by: CGAffineTransform(
                translationX: -sourceBounds.minX, y: -sourceBounds.minY
            ))
            .transformed(by: CGAffineTransform(
                scaleX: fillScale, y: fillScale
            ))
            .transformed(by: CGAffineTransform(
                translationX: (target.width - sourceBounds.width * fillScale) / 2,
                y: (target.height - sourceBounds.height * fillScale) / 2
            ))
            .cropped(to: target)

        let scene = evaluator.evaluate(snapshot, at: projectTime)
        guard !scene.words.isEmpty else { return normalized }
        let overlay = try makeCaptionImage(scene: scene, canvas: canvas)
        return overlay.composited(over: normalized).cropped(to: target)
    }

    /// Pixel-buffer output is the shared adapter boundary for a future live preview
    /// or AVAssetWriter path. It does not export or own a source-media reader.
    func render(
        decodedClipFrame: CVPixelBuffer,
        into output: CVPixelBuffer,
        snapshot: CaptionRenderSnapshot,
        compositionTimestamp: CMTime,
        using context: CIContext
    ) throws {
        let canvas = snapshot.canvas
        guard CVPixelBufferGetWidth(output) == canvas.width,
              CVPixelBufferGetHeight(output) == canvas.height else {
            throw CaptionSpikeError.pixelBufferSizeMismatch
        }

        guard CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA else {
            throw CaptionSpikeError.pixelBufferFormatMismatch
        }

        let time = try MediaTime(validating: compositionTimestamp)
        let source = CIImage(cvPixelBuffer: decodedClipFrame)
        let composed = try composedFrame(
            decodedClipFrame: source, snapshot: snapshot, at: time
        )
        context.render(
            composed,
            to: output,
            bounds: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    private func makeCaptionImage(
        scene: CaptionScene, canvas: RenderCanvas
    ) throws -> CIImage {
        guard let bitmap = CGContext(
            data: nil, width: canvas.width, height: canvas.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CaptionSpikeError.renderContextUnavailable }

        let fontSize = min(CGFloat(canvas.width) / 13, CGFloat(canvas.height) / 15)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let regular = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let active = CGColor(red: 0.9, green: 0.85, blue: 0.3, alpha: 1)
        let secondary = CGColor(red: 0.85, green: 0.85, blue: 0.9, alpha: 1)
        let spacing = fontSize * 0.2

        let lines: [(CTLine, CGFloat)] = scene.words.map { word in
            let color: CGColor = switch word.state {
            case .active: active
            case .upcoming: secondary
            case .spoken: regular
            }
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]
            let attributed = NSAttributedString(string: word.text, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            return (line, width)
        }
        let totalWidth = lines.reduce(CGFloat(0)) { $0 + $1.1 }
            + spacing * CGFloat(max(lines.count - 1, 0))
        let scale = min(1, (CGFloat(canvas.width) * 0.9) / max(1, totalWidth))

        bitmap.saveGState()
        bitmap.translateBy(
            x: (CGFloat(canvas.width) - totalWidth * scale) / 2,
            y: CGFloat(canvas.height) * 0.15
        )
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.65))
        bitmap.fill(CGRect(
            x: -fontSize * 0.15, y: -fontSize * 0.32,
            width: totalWidth + fontSize * 0.3, height: fontSize * 1.4
        ))
        bitmap.textMatrix = .identity

        var position: CGFloat = 0
        for (line, width) in lines {
            bitmap.textPosition = CGPoint(x: position, y: 0)
            CTLineDraw(line, bitmap)
            position += width + spacing
        }
        bitmap.restoreGState()

        guard let image = bitmap.makeImage() else {
            throw CaptionSpikeError.renderContextUnavailable
        }
        return CIImage(cgImage: image)
    }
}
