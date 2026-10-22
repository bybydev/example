import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import Foundation

enum IOSCaptionRenderError: LocalizedError {
    case oversizedCaption, doesNotFit, unavailableContext, invalidFrame
    var errorDescription: String? {
        switch self {
        case .oversizedCaption: "This caption is too long to render. Split it into shorter captions."
        case .doesNotFit: "This caption does not fit. Reduce its size or split it into shorter captions."
        case .unavailableContext: "The caption image could not be prepared."
        case .invalidFrame: "This video frame could not be composed."
        }
    }
}

/// One instance per UI/render queue, never shared concurrently. Core Text lines
/// are cached for one active cue only. Both preview and bitmap export call draw.
final class IOSCaptionRenderer {
    private struct Span { let wordID: UUID; let range: NSRange }
    private struct Fragment {
        var rect: CGRect
        var logicalIndex: Int
        let rightToLeft: Bool
    }
    private struct Line {
        let base: CTLine
        let accent: CTLine
        let contrast: CTLine
        let origin: CGPoint
    }
    private struct Layout {
        let size: CGSize
        let fontSize: CGFloat
        let lines: [Line]
        let fragments: [UUID: [Fragment]]
    }
    private struct Cache {
        let snapshotID: UUID
        let cueID: UUID
        let result: Result<Layout, IOSCaptionRenderError>
    }
    private var cached: Cache?

    /// CGContext and bounds use bottom-left coordinates. Layout is computed in
    /// the original project canvas, then aspect-fitted into the requested bounds.
    func draw(snapshot: IOSCaptionSnapshot, at time: MediaTime,
              in context: CGContext, bounds: CGRect) throws {
        guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return }
        guard let presentation = snapshot.evaluate(at: time) else { cached = nil; return }
        try snapshot.canvas.validate()
        try snapshot.style.validate()
        let layout: Layout
        if let cached, cached.snapshotID == snapshot.id, cached.cueID == presentation.cueID {
            layout = try cached.result.get()
        } else {
            do {
                layout = try makeLayout(presentation, style: snapshot.style, canvas: snapshot.canvas)
                cached = Cache(snapshotID: snapshot.id, cueID: presentation.cueID, result: .success(layout))
            } catch let error as IOSCaptionRenderError {
                cached = Cache(snapshotID: snapshot.id, cueID: presentation.cueID, result: .failure(error))
                throw error
            }
        }
        let style = snapshot.style
        let motion = IOSCaptionMotion.evaluate(snapshot.motionPresentation(presentation), style: style,
            at: try snapshot.timeline.originalTime(forOutput: time))
        let width = CGFloat(snapshot.canvas.width)
        let height = CGFloat(snapshot.canvas.height)
        let fit = min(bounds.width / width, bounds.height / height)
        let margin = min(width, height) * 0.02
        let maximumScale: CGFloat = style.effect == .pop ? 1.12 : 1
        let halfWidth = layout.size.width * maximumScale / 2
        let halfHeight = layout.size.height * maximumScale / 2
        let center = CGPoint(
            x: min(width - margin - halfWidth, max(margin + halfWidth, CGFloat(style.positionX) * width)),
            y: min(height - margin - halfHeight, max(margin + halfHeight, (1 - CGFloat(style.positionY)) * height)))

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        context.translateBy(x: bounds.midX - width * fit / 2, y: bounds.midY - height * fit / 2)
        context.scaleBy(x: fit, y: fit)
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: CGFloat(motion.scale), y: CGFloat(motion.scale))
        context.translateBy(x: -layout.size.width / 2, y: -layout.size.height / 2)
        context.setAlpha(CGFloat(motion.opacity))
        // A transparency layer applies opacity once, including overlapping glyph
        // outlines/backgrounds, rather than accumulating alpha at every overlap.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        context.textMatrix = .identity
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)
        if style.backgroundEnabled {
            context.setFillColor(style.backgroundColor.cgColor)
            context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: layout.size),
                cornerWidth: layout.fontSize * 0.22, cornerHeight: layout.fontSize * 0.22, transform: nil))
            context.fillPath()
        }
        let highlighted = motion.highlighted.flatMap { layout.fragments[$0] ?? [] }
        if !highlighted.isEmpty {
            context.setFillColor(style.accentColor.cgColor)
            for fragment in highlighted {
                context.addPath(CGPath(roundedRect: fragment.rect.insetBy(dx: -layout.fontSize * 0.06, dy: -layout.fontSize * 0.02),
                    cornerWidth: layout.fontSize * 0.12, cornerHeight: layout.fontSize * 0.12, transform: nil))
                context.fillPath()
            }
        }
        paint(layout.lines, variant: 0, in: context)
        if !highlighted.isEmpty {
            context.saveGState()
            context.clip(to: highlighted.map(\.rect))
            paint(layout.lines, variant: 2, in: context)
            context.restoreGState()
        }
        if style.effect == .karaoke {
            var clips: [CGRect] = []
            for word in presentation.words {
                let fraction = motion.karaoke[word.id] ?? 0
                let fragments = (layout.fragments[word.id] ?? []).sorted {
                    if $0.logicalIndex != $1.logicalIndex { return $0.logicalIndex < $1.logicalIndex }
                    if $0.rect.minY != $1.rect.minY { return $0.rect.minY > $1.rect.minY }
                    return $0.rect.minX < $1.rect.minX
                }
                let total = fragments.reduce(CGFloat(0)) { $0 + $1.rect.width }
                var remaining = total * CGFloat(fraction)
                for fragment in fragments {
                    let width = min(fragment.rect.width, max(0, remaining))
                    if width > 0 {
                        clips.append(CGRect(x: fragment.rightToLeft ? fragment.rect.maxX - width : fragment.rect.minX,
                            y: fragment.rect.minY, width: width, height: fragment.rect.height))
                    }
                    remaining -= fragment.rect.width
                }
            }
            if !clips.isEmpty {
                context.saveGState()
                context.clip(to: clips)
                paint(layout.lines, variant: 1, in: context)
                context.restoreGState()
            }
        }
    }

    /// Concrete P5 adapter: transparent sRGB pixels from the same layout/motion
    /// path as preview. Missing/hidden captions return nil; render failures throw.
    func overlay(snapshot: IOSCaptionSnapshot, at time: MediaTime, canvas: RenderCanvas) throws -> CGImage? {
        guard snapshot.evaluate(at: time) != nil else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: canvas.width, height: canvas.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw IOSCaptionRenderError.unavailableContext
        }
        try draw(snapshot: snapshot, at: time, in: context,
            bounds: CGRect(x: 0, y: 0, width: CGFloat(canvas.width), height: CGFloat(canvas.height)))
        guard let image = context.makeImage() else { throw IOSCaptionRenderError.unavailableContext }
        return image
    }

    /// The caller supplies its already-oriented, project-time decoded video frame.
    /// Aspect-fit matches the P3 media preview; P5 owns readers/writers/audio/jobs.
    func composedFrame(orientedFrame: CIImage, snapshot: IOSCaptionSnapshot,
                       at time: MediaTime, canvas: RenderCanvas) throws -> CIImage {
        try snapshot.canvas.validate()
        let source = orientedFrame.extent
        guard source.minX.isFinite, source.minY.isFinite, source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0 else {
            throw IOSCaptionRenderError.invalidFrame
        }
        let target = CGRect(x: 0, y: 0, width: CGFloat(canvas.width), height: CGFloat(canvas.height))
        let projectWidth = CGFloat(snapshot.canvas.width)
        let projectHeight = CGFloat(snapshot.canvas.height)
        let outputFit = min(target.width / projectWidth, target.height / projectHeight)
        let project = CGRect(x: target.midX - projectWidth * outputFit / 2,
            y: target.midY - projectHeight * outputFit / 2,
            width: projectWidth * outputFit, height: projectHeight * outputFit)
        let fit = min(project.width / source.width, project.height / source.height)
        let frame = orientedFrame
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            .transformed(by: CGAffineTransform(translationX: project.midX - source.width * fit / 2,
                                              y: project.midY - source.height * fit / 2))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: target))
            .cropped(to: target)
        guard let overlay = try overlay(snapshot: snapshot, at: time, canvas: canvas) else { return frame }
        return CIImage(cgImage: overlay).composited(over: frame).cropped(to: target)
    }

    private func paint(_ lines: [Line], variant: Int, in context: CGContext) {
        for line in lines {
            context.textPosition = line.origin
            CTLineDraw(variant == 1 ? line.accent : variant == 2 ? line.contrast : line.base, context)
        }
    }

    private func makeFont(_ choice: IOSCaptionFont, size: CGFloat) -> CTFont {
        let requested = CTFontCreateWithName(choice.postScriptName as CFString, size, nil)
        let system = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? requested
        let name = CTFontCopyPostScriptName(requested) as String
        let base = name.caseInsensitiveCompare(choice.postScriptName) == .orderedSame ? requested : system
        // Explicit installed-script/emoji cascade, with system fallback last.
        let names = ["PingFangSC-Semibold", "HiraginoSans-W6", "AppleSDGothicNeo-Bold", "Thonburi-Bold", "AppleColorEmoji"]
        let cascade = names.map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, size) } + [CTFontCopyFontDescriptor(system)]
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute as String: cascade] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }

    private func makeLayout(_ presentation: IOSCaptionPresentation, style: IOSCaptionStyle, canvas: IOSCanvas) throws -> Layout {
        let words = presentation.words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var joined = ""
        var units = 0
        for word in words {
            units += word.text.utf16.count
            guard units <= 16_384 else { throw IOSCaptionRenderError.oversizedCaption }
            joined += word.text
        }
        let text = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 16_384 else { throw IOSCaptionRenderError.oversizedCaption }
        let trim = (joined as NSString).range(of: text, options: .literal)
        var spans: [Span] = []
        var cursor = 0
        for word in words {
            let clean = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let local = (word.text as NSString).range(of: clean, options: .literal)
            let visible = NSIntersectionRange(NSRange(location: cursor + local.location, length: local.length), trim)
            if visible.length > 0 { spans.append(Span(wordID: word.id,
                range: NSRange(location: visible.location - trim.location, length: visible.length))) }
            cursor += word.text.utf16.count
        }
        let width = CGFloat(canvas.width)
        let height = CGFloat(canvas.height)
        let fontSize = CGFloat(style.fontSize) * min(width, height)
        let font = makeFont(style.font, size: fontSize)
        let padding = fontSize * (0.28 + CGFloat(style.outlineWidth))
        let margin = min(width, height) * 0.02
        let maximumScale: CGFloat = style.effect == .pop ? 1.12 : 1
        let maximumWidth = (width - margin * 2) / maximumScale - padding * 2
        func typesetter(color: IOSCaptionColor) -> CTTypesetter {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): style.outlineColor.cgColor,
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -style.outlineWidth * 100
            ]
            return CTTypesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
        }
        let base = typesetter(color: style.textColor)
        let accent = typesetter(color: style.accentColor)
        let contrast = typesetter(color: style.accentColor.contrastText)
        struct Measured {
            let range: CFRange; let base: CTLine; let width: CGFloat
            let ascent: CGFloat; let descent: CGFloat; let leading: CGFloat
        }
        var measured: [Measured] = []
        var start = 0
        var textWidth: CGFloat = 0
        var textHeight: CGFloat = 0
        while start < text.utf16.count {
            guard measured.count < 8 else { throw IOSCaptionRenderError.doesNotFit }
            var count = CTTypesetterSuggestLineBreak(base, start, Double(maximumWidth))
            if count == 0 { count = CTTypesetterSuggestClusterBreak(base, start, Double(maximumWidth)) }
            guard count > 0 else { throw IOSCaptionRenderError.doesNotFit }
            let range = CFRange(location: start, length: count)
            let line = CTTypesetterCreateLine(base, range)
            var ascent: CGFloat = 0; var descent: CGFloat = 0; var leading: CGFloat = 0
            let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let lineWidth = max(0, advance - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
            guard lineWidth.isFinite, lineWidth <= maximumWidth + 0.01,
                  ascent.isFinite, descent.isFinite, leading.isFinite else { throw IOSCaptionRenderError.doesNotFit }
            measured.append(Measured(range: range, base: line, width: lineWidth, ascent: ascent,
                descent: descent, leading: max(0, leading)))
            textWidth = max(textWidth, lineWidth)
            textHeight += ascent + descent + max(0, leading)
            start += count
        }
        let gap = fontSize * 0.1
        textHeight += gap * CGFloat(max(0, measured.count - 1))
        let size = CGSize(width: textWidth + padding * 2, height: textHeight + padding * 2)
        guard size.height * maximumScale <= height - margin * 2 else { throw IOSCaptionRenderError.doesNotFit }
        var lines: [Line] = []
        var fragments: [UUID: [Fragment]] = [:]
        var top = size.height - padding
        for line in measured {
            let origin = CGPoint(x: padding + CGFloat(CTLineGetPenOffsetForFlush(line.base, 0.5, Double(textWidth))), y: top - line.ascent)
            lines.append(Line(base: line.base, accent: CTTypesetterCreateLine(accent, line.range),
                contrast: CTTypesetterCreateLine(contrast, line.range), origin: origin))
            collectFragments(line.base, origin: origin, spans: spans, fontSize: fontSize, into: &fragments)
            top -= line.ascent + line.descent + line.leading + gap
        }
        return Layout(size: size, fontSize: fontSize, lines: lines, fragments: fragments)
    }

    private func collectFragments(_ line: CTLine, origin: CGPoint, spans: [Span], fontSize: CGFloat,
                                  into fragments: inout [UUID: [Fragment]]) {
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            positions.withUnsafeMutableBufferPointer { CTRunGetPositions(run, CFRange(location: 0, length: count), $0.baseAddress!) }
            advances.withUnsafeMutableBufferPointer { CTRunGetAdvances(run, CFRange(location: 0, length: count), $0.baseAddress!) }
            indices.withUnsafeMutableBufferPointer { CTRunGetStringIndices(run, CFRange(location: 0, length: count), $0.baseAddress!) }
            var ascent: CGFloat = 0; var descent: CGFloat = 0
            _ = CTRunGetTypographicBounds(run, CFRange(location: 0, length: count), &ascent, &descent, nil)
            var selected: [UUID: Fragment] = [:]
            for index in 0..<count {
                let stringIndex = indices[index]
                guard stringIndex >= 0 else { continue }
                var low = 0; var high = spans.count
                while low < high {
                    let mid = (low + high) / 2
                    if NSMaxRange(spans[mid].range) <= stringIndex { low = mid + 1 } else { high = mid }
                }
                guard low < spans.count, NSLocationInRange(stringIndex, spans[low].range) else { continue }
                let id = spans[low].wordID
                let position = positions[index]
                let advance = advances[index].width
                let rect = CGRect(x: origin.x + position.x + min(0, advance), y: origin.y + position.y - descent,
                    width: max(fontSize * 0.02, abs(advance)), height: ascent + descent)
                if var fragment = selected[id] {
                    fragment.rect = fragment.rect.union(rect)
                    fragment.logicalIndex = min(fragment.logicalIndex, stringIndex)
                    selected[id] = fragment
                } else {
                    selected[id] = Fragment(rect: rect, logicalIndex: stringIndex,
                        rightToLeft: CTRunGetStatus(run).contains(.rightToLeft))
                }
            }
            for (id, fragment) in selected { fragments[id, default: []].append(fragment) }
        }
    }
}
