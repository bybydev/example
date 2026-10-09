import Foundation
import OnnxRuntimeBindings

/// Production-path experiment: arbitrary English text -> ONNXG2P (lexicon +
/// CPU BART) -> Kokoro vocabulary -> ONNX INT8 -> 24 kHz mono PCM.
/// The isolated benchmark does not exercise text preparation.
actor KokoroONNXEngine: SpeechSynthesisEngine {
    static let shared = KokoroONNXEngine()
    private var environment: ORTEnv?
    private var loading: Task<Void, Error>?
    private var session: ORTSession?
    private var processor: KokoroTextProcessor?
    private var voiceTables: [String: Data] = [:]

    func load() async throws {
        guard session == nil else { return }
        if let loading {
            try await loading.value
            return
        }
        let task = Task { try await self.loadOnce() }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func loadOnce() async throws {
        try Task.checkCancellation()
        // Never access the network from Listen, prefetch or offline generation.
        let model = try await ONNXResourceStore.shared.installedURL(
            .kokoroModel
        )
        try Task.checkCancellation()

        // Load and verify the small pronunciation resources *before* the
        // large Kokoro ORT session, reducing simultaneous cold-start peaks.
        let g2pModelURL = try await ONNXResourceStore.shared.installedURL(
            .g2pModel
        )
        try Task.checkCancellation()
        let g2pMetadataURL = try await ONNXResourceStore.shared.installedURL(
            .g2pLexicon
        )
        try Task.checkCancellation()
        let phonemizer = try ONNXG2PPhonemizer(
            modelURL: g2pModelURL,
            metadataURL: g2pMetadataURL
        )
        let textProcessor = try KokoroTextProcessor(
            phonemizer: phonemizer,
            vocab: phonemizer.vocabulary
        )
        try Task.checkCancellation()

        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)
        let env = try ORTEnv(loggingLevel: .warning)
        let loadedSession = try ORTSession(
            env: env, modelPath: model.path, sessionOptions: options
        )
        try Task.checkCancellation()
        environment = env
        session = loadedSession
        processor = textProcessor
    }

    func warmUp(
        text: String = "Hello world.",
        voice: SpeechVoice = .heart,
        speed: Float = 1.0
    ) async throws -> SpeechWarmUpResult {
        let start = ContinuousClock().now
        _ = try await synthesize(
            text: text, voice: voice, speed: speed, maxChunkSeconds: 15
        )
        return SpeechWarmUpResult(
            elapsedSeconds: Self.seconds(start.duration(to: .now))
        )
    }

    func synthesize(
        text: String,
        voice: SpeechVoice = .heart,
        speed: Float = 1.0,
        maxChunkSeconds: Double = 15
    ) async throws -> SpeechSynthesisResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechEngineError.synthesisFailed("Empty text.")
        }
        guard speed.isFinite, speed > 0, maxChunkSeconds.isFinite,
              maxChunkSeconds > 0 else {
            throw SpeechEngineError.synthesisFailed("Invalid synthesis settings.")
        }
        guard SpeechVoice.all.contains(voice) else {
            throw SpeechEngineError.unsupportedVoice(voice.id)
        }

        guard let resource = ONNXResource.voice(voice.id) else {
            throw SpeechEngineError.unsupportedVoice(voice.id)
        }
        try await ONNXResourceStore.shared.require([
            .kokoroModel, .g2pModel, .g2pLexicon, resource
        ])
        try await load()
        guard let session, let processor else {
            throw SpeechEngineError.notLoaded
        }
        try Task.checkCancellation()
        let voiceData = try await voiceTable(for: voice.id)
        let clock = ContinuousClock()
        let start = clock.now
        var samples: [Float] = []

        do {
            try synthesizeFragments(
                text: text, speed: speed, processor: processor,
                voiceData: voiceData, session: session,
                into: &samples, depth: 0
            )
            try Task.checkCancellation()
            guard !samples.isEmpty else { throw BenchmarkAudioError.emptyAudio }
            return SpeechSynthesisResult(
                audio: KokoroAudio(samples: samples, sampleRate: 24_000),
                elapsedSeconds: Self.seconds(start.duration(to: clock.now))
            )
        } catch is CancellationError {
            throw SpeechEngineError.cancelled
        } catch {
            throw SpeechEngineError.synthesisFailed(
                (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            )
        }
    }

    func unload() async {
        // Prevent in-progress downloads/session initialization from reviving
        // an engine that the user has just switched away from.
        if let loading {
            loading.cancel()
            _ = await loading.result
        }
        self.loading = nil
        // Release the session/arena before the other engine loads.
        session = nil
        environment = nil
        processor = nil
        voiceTables.removeAll()
    }

    private enum BenchmarkAudioError: LocalizedError {
        case tooLong
        case emptyAudio
        case outputInvalid

        var errorDescription: String? {
            switch self {
            case .tooLong: "A Kokoro chunk could not be split within its token limit."
            case .emptyAudio: "ONNX returned no audio."
            case .outputInvalid: "ONNX returned invalid PCM audio."
            }
        }
    }

    private func synthesizeFragments(
        text: String,
        speed: Float,
        processor: KokoroTextProcessor,
        voiceData: Data,
        session: ORTSession,
        into samples: inout [Float],
        depth: Int
    ) throws {
        try Task.checkCancellation()
        let normalized = KokoroTextProcessor.normalizeWhitespace(text)
        let phonemes = try processor.phonemize(normalized)
        let tokenization = processor.tokenization(
            forPhonemes: phonemes.phonemes
        )
        // No dropped spoken text or unrecognized IPA symbols may silently
        // become a cacheable segment. Fail recoverably instead.
        guard phonemes.droppedTokens == 0,
              tokenization.droppedCharacters == 0 else {
            throw SpeechEngineError.synthesisFailed(
                "The ONNX phonemizer produced unsupported sounds."
            )
        }
        let ids = tokenization.tokenIDs
        guard !ids.isEmpty else { throw BenchmarkAudioError.emptyAudio }

        // ONNX Kokoro supports up to 512 framed IDs; voice vectors index by
        // phoneme UTF-16 count, so both budgets must be respected.
        if ids.count > 508 || phonemes.utf16Count >= 510 {
            guard depth < 12,
                  let pair = SpeechTextSegmentation.splitForModelBudget(normalized) else {
                throw BenchmarkAudioError.tooLong
            }
            try synthesizeFragments(
                text: pair.0, speed: speed, processor: processor,
                voiceData: voiceData, session: session,
                into: &samples, depth: depth + 1
            )
            try synthesizeFragments(
                text: pair.1, speed: speed, processor: processor,
                voiceData: voiceData, session: session,
                into: &samples, depth: depth + 1
            )
            return
        }

        let stride = 256 * MemoryLayout<Float>.size
        let offset = phonemes.utf16Count * stride
        guard offset >= 0, offset + stride <= voiceData.count else {
            throw BenchmarkAudioError.tooLong
        }

        let tokenIDs = [Int64(0)] + ids.map(Int64.init) + [Int64(0)]

        // This synchronous boundary is deliberately per Kokoro inference,
        // not around an entire paragraph or EPUB. ONNX Runtime's ObjC
        // wrappers, tensor inputs, output, and temporary Data must become
        // eligible for release before we grow the retained PCM array.
        // The returned Swift [Float] is the only value that escapes the pool.
        let pcm: [Float] = try autoreleasepool {
            try Task.checkCancellation()
            let input = try ORTValue(
                tensorData: Self.mutableBytes(tokenIDs),
                elementType: .int64,
                shape: [1, NSNumber(value: tokenIDs.count)]
            )
            let style = try ORTValue(
                tensorData: NSMutableData(
                    data: voiceData.subdata(in: offset..<(offset + stride))
                ),
                elementType: .float,
                shape: [1, 256]
            )
            let pace = try ORTValue(
                tensorData: Self.mutableBytes([speed]),
                elementType: .float,
                shape: [1]
            )
            let result = try session.run(
                withInputs: [
                    "input_ids": input,
                    "style": style,
                    "speed": pace
                ],
                outputNames: ["waveform"],
                runOptions: nil
            )
            try Task.checkCancellation()
            guard let output = result["waveform"],
                  try output.tensorTypeAndShapeInfo().elementType == .float else {
                throw BenchmarkAudioError.outputInvalid
            }
            let data = try output.tensorData() as Data
            guard !data.isEmpty,
                  data.count.isMultiple(of: MemoryLayout<Float>.size),
                  data.count <= 24_000 * MemoryLayout<Float>.size * 60 else {
                throw BenchmarkAudioError.outputInvalid
            }
            let count = data.count / MemoryLayout<Float>.size
            var converted = [Float](repeating: 0, count: count)
            _ = converted.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            guard converted.allSatisfy(\.isFinite) else {
                throw BenchmarkAudioError.outputInvalid
            }
            return converted
        }

        try Task.checkCancellation()
        // Bound retained Swift PCM independently of the autorelease pool:
        // autoreleasepool cannot reclaim arrays the reader still owns.
        guard pcm.count <= ReadAloudSafety.maximumParagraphSamples,
              samples.count <= ReadAloudSafety.maximumParagraphSamples - pcm.count else {
            throw BenchmarkAudioError.outputInvalid
        }
        samples.append(contentsOf: pcm)
    }

    private func voiceTable(for id: String) async throws -> Data {
        if let existing = voiceTables[id] { return existing }
        guard let resource = ONNXResource.voice(id) else {
            throw SpeechEngineError.unsupportedVoice(id)
        }
        let local = try await ONNXResourceStore.shared.installedURL(resource)
        let bytes = try Data(contentsOf: local)
        voiceTables[id] = bytes
        return bytes
    }

    private static func mutableBytes<T>(_ values: [T]) -> NSMutableData {
        NSMutableData(data: values.withUnsafeBytes { Data($0) })
    }

    private static func seconds(_ value: Duration) -> Double {
        let parts = value.components
        return Double(parts.seconds)
            + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

}
