import Foundation
import InkribeModelAssets

public enum WhisperRuntimeRelease {
    public static let upstreamRepository = "ggml-org/whisper.cpp"
    public static let stableVersion = "1.9.4"
    public static let binaryTag = "b5130"
    public static let revision = "927cfce34f31707e17f2bff35c349632fb9e2c3a"
    public static let archiveSHA256 = "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
}

public enum WhisperModelAsset {
    public static func descriptor() throws -> ModelAssetDescriptor {
        try ModelAssetCatalog.bundledManifest().asset(runtime: .whisper)
    }

    public static func checkedURL(resourcesURL: URL) throws -> URL {
        let descriptor = try descriptor()
        return try ModelAssetLocator(resourcesURL: resourcesURL).requireCheckedURL(for: descriptor)
    }

    public static func checkedURL(bundle: Bundle) throws -> URL {
        let descriptor = try descriptor()
        return try ModelAssetLocator(bundle: bundle).requireCheckedURL(for: descriptor)
    }
}

public struct WhisperRuntimeConfiguration: Equatable, Sendable {
    public let threadCount: Int32
    public let useGPU: Bool
    public let flashAttention: Bool

    public init(threadCount: Int32, useGPU: Bool, flashAttention: Bool) {
        self.threadCount = max(1, threadCount)
        self.useGPU = useGPU
        self.flashAttention = flashAttention && useGPU
    }

    public static var recommended: Self {
        let processorCount = ProcessInfo.processInfo.processorCount

        #if targetEnvironment(simulator)
        return Self(
            threadCount: Int32(max(1, min(6, processorCount - 1))),
            useGPU: false,
            flashAttention: false
        )
        #elseif arch(arm64)
        return Self(
            threadCount: Int32(max(1, min(8, processorCount - 2))),
            useGPU: true,
            flashAttention: true
        )
        #else
        return Self(
            threadCount: Int32(max(1, min(6, processorCount - 1))),
            useGPU: false,
            flashAttention: false
        )
        #endif
    }
}

public struct WhisperAudioBuffer: Equatable, Sendable {
    public static let requiredSampleRate = 16_000

    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int = Self.requiredSampleRate) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public struct WhisperToken: Codable, Equatable, Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
        self.text = text
    }
}

public struct WhisperSegment: Codable, Equatable, Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct WhisperTranscriptionResult: Codable, Equatable, Sendable {
    public let detectedLanguageCode: String?
    public let segments: [WhisperSegment]
    public let tokens: [WhisperToken]

    public init(
        detectedLanguageCode: String?,
        segments: [WhisperSegment],
        tokens: [WhisperToken] = []
    ) {
        self.detectedLanguageCode = detectedLanguageCode
        self.segments = segments
        self.tokens = tokens
    }

    public var text: String {
        segments.map(\.text).joined()
    }
}

public typealias WhisperProgressHandler = @Sendable (Double) -> Void

public protocol WhisperRuntimeProtocol: Sendable {
    func loadModel() async throws
    func unloadModel() async
    func transcribe(
        mediaURL: URL,
        requestedLanguageCode: String?,
        progress: WhisperProgressHandler?
    ) async throws -> WhisperTranscriptionResult
    func transcribe(
        buffer: WhisperAudioBuffer,
        requestedLanguageCode: String?,
        progress: WhisperProgressHandler?
    ) async throws -> WhisperTranscriptionResult
}

public extension WhisperRuntimeProtocol {
    func transcribe(
        mediaURL: URL,
        requestedLanguageCode: String?
    ) async throws -> WhisperTranscriptionResult {
        try await transcribe(
            mediaURL: mediaURL,
            requestedLanguageCode: requestedLanguageCode,
            progress: nil
        )
    }

    func transcribe(
        buffer: WhisperAudioBuffer,
        requestedLanguageCode: String? = nil
    ) async throws -> WhisperTranscriptionResult {
        try await transcribe(
            buffer: buffer,
            requestedLanguageCode: requestedLanguageCode,
            progress: nil
        )
    }
}

public enum WhisperRuntimeError: Error, Equatable, Sendable {
    case modelNotLoaded
    case couldNotLoadModel(String)
    case emptyAudio
    case unsupportedSampleRate(Int)
    case unsupportedWaveFormat
    case malformedWaveFile
    case invalidLanguageCode(String)
    case transcriptionFailed(Int32)
}

extension WhisperRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "The Whisper model is not loaded."
        case .couldNotLoadModel(let id):
            "Whisper could not load model \(id)."
        case .emptyAudio:
            "The audio buffer is empty."
        case .unsupportedSampleRate(let rate):
            "Whisper requires 16 kHz audio; received \(rate) Hz."
        case .unsupportedWaveFormat:
            "The audio file must be normalized PCM or Float32 WAV for the native runtime."
        case .malformedWaveFile:
            "The WAV file is malformed or incomplete."
        case .invalidLanguageCode(let code):
            "Whisper does not recognize language code \(code)."
        case .transcriptionFailed(let code):
            "Whisper transcription failed with native error code \(code)."
        }
    }
}
