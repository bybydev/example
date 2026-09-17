import Foundation
import InkribeModelAssets

public enum WhisperModelAsset {
    public static func descriptor() throws -> ModelAssetDescriptor {
        try ModelAssetCatalog.bundledManifest().asset(runtime: .whisper)
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

    public init(detectedLanguageCode: String?, segments: [WhisperSegment]) {
        self.detectedLanguageCode = detectedLanguageCode
        self.segments = segments
    }
}

public protocol WhisperRuntimeProtocol: Sendable {
    func transcribe(mediaURL: URL, requestedLanguageCode: String?) async throws -> WhisperTranscriptionResult
}
