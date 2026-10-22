import Foundation

enum CaptionSpikeError: Error {
    case unsupportedCanvas
    case invalidWords
    case clipNotActive
    case renderContextUnavailable
    case pixelBufferSizeMismatch
    case pixelBufferFormatMismatch
}

/// P0 deliberately limits image pixels and word count. P4 widens this with profiling.
struct RenderCanvas: Equatable, Sendable {
    static let maximumPixels = 1920 * 1080
    let width: Int
    let height: Int

    init(width: Int, height: Int) throws {
        guard width > 0, height > 0,
              width <= 1920, height <= 1920,
              width * height <= Self.maximumPixels else {
            throw CaptionSpikeError.unsupportedCanvas
        }
        self.width = width
        self.height = height
    }
}

struct CaptionRenderWord: Sendable {
    let id: UUID
    let text: String
    let interval: MediaInterval
}

struct CaptionRenderSnapshot: Sendable {
    let revision: ProjectRevision
    let canvas: RenderCanvas
    let clip: IdentityClipMapping
    let captionInterval: MediaInterval
    let words: [CaptionRenderWord]

    init(
        revision: ProjectRevision,
        canvas: RenderCanvas,
        clip: IdentityClipMapping,
        captionInterval: MediaInterval,
        words: [CaptionRenderWord]
    ) throws {
        guard clip.timelineInterval.start <= captionInterval.start,
              captionInterval.end <= clip.timelineInterval.end,
              !words.isEmpty, words.count <= 16,
              Set(words.map(\.id)).count == words.count,
              words.allSatisfy({
                  !$0.text.isEmpty && $0.text.utf16.count <= 128 &&
                  captionInterval.start <= $0.interval.start &&
                  $0.interval.end <= captionInterval.end
              }) else { throw CaptionSpikeError.invalidWords }

        self.revision = revision
        self.canvas = canvas
        self.clip = clip
        self.captionInterval = captionInterval
        self.words = words
    }
}

enum CaptionWordState: Sendable {
    case upcoming
    case active
    case spoken
}

struct EvaluatedCaptionWord: Sendable {
    let text: String
    let state: CaptionWordState
}

struct CaptionScene: Sendable {
    let words: [EvaluatedCaptionWord]
}

/// Pure scene evaluation, independent of UI state, frame cadence and wall-clock time.
struct CaptionSceneEvaluator: Sendable {
    func evaluate(_ snapshot: CaptionRenderSnapshot, at time: MediaTime) -> CaptionScene {
        guard snapshot.captionInterval.contains(time) else { return CaptionScene(words: []) }
        return CaptionScene(words: snapshot.words.map { word in
            let state: CaptionWordState
            if word.interval.contains(time) {
                state = .active
            } else if time >= word.interval.end {
                state = .spoken
            } else {
                state = .upcoming
            }
            return EvaluatedCaptionWord(text: word.text, state: state)
        })
    }
}

/// Deterministic representative data only, not a persisted user project or measured test result.
enum P0CaptionFixture {
    static func makeSnapshot() throws -> CaptionRenderSnapshot {
        func stamp(_ ticks: Int64) throws -> MediaTime {
            try MediaTime(value: ticks, timescale: 600)
        }

        let sourceAssetID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let clip = try IdentityClipMapping(
            clipID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            sourceAssetID: sourceAssetID,
            sourceInterval: MediaInterval(start: stamp(0), end: stamp(3_000)),
            timelineStart: stamp(600)
        )
        return try CaptionRenderSnapshot(
            revision: ProjectRevision(
                projectID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
                contentRevision: 1
            ),
            canvas: RenderCanvas(width: 1080, height: 1920),
            clip: clip,
            captionInterval: MediaInterval(start: stamp(1_200), end: stamp(2_400)),
            words: [
                CaptionRenderWord(
                    id: UUID(uuidString: "44444444-4444-4444-8444-444444444441")!,
                    text: "Create",
                    interval: MediaInterval(start: stamp(1_200), end: stamp(1_600))
                ),
                CaptionRenderWord(
                    id: UUID(uuidString: "44444444-4444-4444-8444-444444444442")!,
                    text: "with",
                    interval: MediaInterval(start: stamp(1_600), end: stamp(2_000))
                ),
                CaptionRenderWord(
                    id: UUID(uuidString: "44444444-4444-4444-8444-444444444443")!,
                    text: "Inkribe",
                    interval: MediaInterval(start: stamp(2_000), end: stamp(2_400))
                )
            ]
        )
    }
}
