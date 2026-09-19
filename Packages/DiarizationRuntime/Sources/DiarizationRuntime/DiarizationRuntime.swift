import Foundation
import InkribeModelAssets
import Logging
@preconcurrency import SherpaOnnx

public enum DiarizationRuntimeRelease {
    public static let upstreamRepository = "k2-fsa/sherpa-onnx"
    public static let stableVersion = "1.13.8"
    public static let revision = "11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf"
}

public enum SpeakerDiarizationModelAsset {
    public static func segmentationDescriptor() throws -> ModelAssetDescriptor {
        try ModelAssetCatalog.bundledManifest().asset(runtime: .speakerSegmentation)
    }

    public static func embeddingDescriptor() throws -> ModelAssetDescriptor {
        try ModelAssetCatalog.bundledManifest().asset(runtime: .speakerEmbedding)
    }
}

public struct SpeakerTurn: Codable, Equatable, Sendable {
    public let speakerID: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(
        speakerID: Int,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.speakerID = max(0, speakerID)
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
    }
}

public struct SpeakerDiarizationConfiguration: Equatable, Sendable {
    public let threadCount: Int
    public let clusteringThreshold: Float
    public let minDurationOn: Float
    public let minDurationOff: Float
    public let windowShiftRatio: Float

    public init(
        threadCount: Int,
        clusteringThreshold: Float = 0.5,
        minDurationOn: Float = 0.3,
        minDurationOff: Float = 0.5,
        windowShiftRatio: Float = 0.1
    ) {
        self.threadCount = max(1, threadCount)
        self.clusteringThreshold = min(max(clusteringThreshold, 0), 1)
        self.minDurationOn = max(0, minDurationOn)
        self.minDurationOff = max(0, minDurationOff)
        self.windowShiftRatio = min(max(windowShiftRatio, 0.01), 1)
    }

    public static var recommended: Self {
        let processorCount = ProcessInfo.processInfo.processorCount
        return Self(threadCount: max(1, min(4, processorCount - 1)))
    }
}

public protocol SpeakerDiarizationRuntimeProtocol: Sendable {
    func diarize(
        samples: [Float],
        sampleRate: Int,
        speakerCount: Int?
    ) async throws -> [SpeakerTurn]
    func unloadModels() async
}

public extension SpeakerDiarizationRuntimeProtocol {
    func unloadModels() async {}
}

public actor NativeSpeakerDiarizationRuntime: SpeakerDiarizationRuntimeProtocol {
    public static let requiredSampleRate = 16_000

    private let segmentationURL: URL
    private let embeddingURL: URL
    private let segmentationDescriptor: ModelAssetDescriptor
    private let embeddingDescriptor: ModelAssetDescriptor
    private let configuration: SpeakerDiarizationConfiguration
    private let logger = Logger(label: "Inkribe.DiarizationRuntime")

    private var integrityChecked = false
    private var nativeRuntime: SherpaOnnxOfflineSpeakerDiarizationWrapper?

    public init(
        segmentationURL: URL,
        embeddingURL: URL,
        segmentationDescriptor: ModelAssetDescriptor,
        embeddingDescriptor: ModelAssetDescriptor,
        configuration: SpeakerDiarizationConfiguration = .recommended
    ) {
        self.segmentationURL = segmentationURL
        self.embeddingURL = embeddingURL
        self.segmentationDescriptor = segmentationDescriptor
        self.embeddingDescriptor = embeddingDescriptor
        self.configuration = configuration
    }

    public static func bundled(
        in bundle: Bundle = .main,
        configuration: SpeakerDiarizationConfiguration = .recommended
    ) throws -> NativeSpeakerDiarizationRuntime {
        let segmentationDescriptor = try SpeakerDiarizationModelAsset.segmentationDescriptor()
        let embeddingDescriptor = try SpeakerDiarizationModelAsset.embeddingDescriptor()
        let locator = try ModelAssetLocator(bundle: bundle)
        return NativeSpeakerDiarizationRuntime(
            segmentationURL: try locator.requireURL(for: segmentationDescriptor),
            embeddingURL: try locator.requireURL(for: embeddingDescriptor),
            segmentationDescriptor: segmentationDescriptor,
            embeddingDescriptor: embeddingDescriptor,
            configuration: configuration
        )
    }

    public func diarize(
        samples: [Float],
        sampleRate: Int,
        speakerCount: Int? = nil
    ) async throws -> [SpeakerTurn] {
        try Task.checkCancellation()
        guard !samples.isEmpty else { throw SpeakerDiarizationRuntimeError.emptyAudio }
        guard sampleRate == Self.requiredSampleRate else {
            throw SpeakerDiarizationRuntimeError.unsupportedSampleRate(sampleRate)
        }

        try checkIntegrityIfNeeded()
        try Task.checkCancellation()

        let normalizedSpeakerCount = speakerCount.flatMap { $0 > 0 ? $0 : nil }
        let startedAt = Date()

        let runtime = try loadRuntimeIfNeeded()
        var clusteringConfiguration = sherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
                    model: segmentationURL.path,
                    windowShiftRatio: configuration.windowShiftRatio
                ),
                numThreads: configuration.threadCount
            ),
            embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(
                model: embeddingURL.path,
                numThreads: configuration.threadCount
            ),
            clustering: sherpaOnnxFastClusteringConfig(
                numClusters: normalizedSpeakerCount ?? -1,
                threshold: configuration.clusteringThreshold
            ),
            minDurationOn: configuration.minDurationOn,
            minDurationOff: configuration.minDurationOff
        )
        runtime.setConfig(config: &clusteringConfiguration)

        guard runtime.sampleRate == sampleRate else {
            throw SpeakerDiarizationRuntimeError.unsupportedSampleRate(sampleRate)
        }

        logger.debug(
            "Speaker diarization started",
            metadata: [
                "sample_count": "\(samples.count)",
                "thread_count": "\(configuration.threadCount)",
                "speaker_count": .string(normalizedSpeakerCount.map(String.init) ?? "auto")
            ]
        )

        // sherpa-onnx 1.13.8 exposes a synchronous Swift wrapper. Running it
        // inside this actor keeps the native runtime isolated from feature UI.
        let segments = runtime.process(samples: samples)
        try Task.checkCancellation()

        let turns = segments
            .map {
                SpeakerTurn(
                    speakerID: $0.speaker,
                    startTime: TimeInterval($0.start),
                    endTime: TimeInterval($0.end)
                )
            }
            .filter { $0.endTime > $0.startTime }
            .sorted {
                if $0.startTime != $1.startTime {
                    return $0.startTime < $1.startTime
                }
                return $0.speakerID < $1.speakerID
            }

        logger.debug(
            "Speaker diarization finished",
            metadata: [
                "turn_count": "\(turns.count)",
                "speaker_count": "\(Set(turns.map(\.speakerID)).count)",
                "duration_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            ]
        )
        return turns
    }

    public func unloadModels() async {
        guard nativeRuntime != nil else { return }
        nativeRuntime = nil
        logger.info("Speaker diarization models unloaded")
    }

    private func loadRuntimeIfNeeded() throws -> SherpaOnnxOfflineSpeakerDiarizationWrapper {
        if let nativeRuntime { return nativeRuntime }

        var nativeConfiguration = sherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
                    model: segmentationURL.path,
                    windowShiftRatio: configuration.windowShiftRatio
                ),
                numThreads: configuration.threadCount
            ),
            embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(
                model: embeddingURL.path,
                numThreads: configuration.threadCount
            ),
            clustering: sherpaOnnxFastClusteringConfig(
                numClusters: -1,
                threshold: configuration.clusteringThreshold
            ),
            minDurationOn: configuration.minDurationOn,
            minDurationOff: configuration.minDurationOff
        )
        let runtime = SherpaOnnxOfflineSpeakerDiarizationWrapper(
            config: &nativeConfiguration
        )
        guard runtime.impl != nil else {
            throw SpeakerDiarizationRuntimeError.couldNotCreateRuntime
        }
        nativeRuntime = runtime
        logger.info("Speaker diarization models loaded")
        return runtime
    }

    private func checkIntegrityIfNeeded() throws {
        guard !integrityChecked else { return }
        try ModelAssetIntegrityChecker.check(
            segmentationURL,
            against: segmentationDescriptor
        )
        try ModelAssetIntegrityChecker.check(
            embeddingURL,
            against: embeddingDescriptor
        )
        integrityChecked = true
    }
}

public enum SpeakerDiarizationRuntimeError: Error, Equatable, Sendable {
    case emptyAudio
    case unsupportedSampleRate(Int)
    case couldNotCreateRuntime
}

extension SpeakerDiarizationRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyAudio:
            "Speaker detection cannot run on empty audio."
        case .unsupportedSampleRate(let sampleRate):
            "Speaker detection requires 16 kHz audio; received \(sampleRate) Hz."
        case .couldNotCreateRuntime:
            "The local speaker-detection runtime could not be created."
        }
    }
}
