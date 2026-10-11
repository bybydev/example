import Foundation

/// ONNX INT8 is the only shipping synthesis backend. Retain a fixed engine
/// identity for generation cache migration; the old Core ML setting is ignored.
nonisolated enum SpeechEngineKind: String, Sendable {
    case onnxINT8 = "kokoro-onnx-int8"

    var runtimeRevisionOverride: String {
        "onnx-community-kokoro-v1.0-468588286ebb2dd77c25b9771e5d165896538cce-int8-fbae9257-g2p757759c3-lex8a8e3350-v4"
    }
}

nonisolated struct SpeechVoice: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let locale: String

    static let heart = SpeechVoice(id: "af_heart", name: "Heart", locale: "American English")
    static let bella = SpeechVoice(id: "af_bella", name: "Bella", locale: "American English")
    static let michael = SpeechVoice(id: "am_michael", name: "Michael", locale: "American English")

    /// All 28 English Kokoro v1.0 voice styles (American and British).
    static let all: [SpeechVoice] = [
        .heart,
        SpeechVoice(id: "af_alloy", name: "Alloy", locale: "American English"),
        SpeechVoice(id: "af_aoede", name: "Aoede", locale: "American English"),
        .bella,
        SpeechVoice(id: "af_jessica", name: "Jessica", locale: "American English"),
        SpeechVoice(id: "af_kore", name: "Kore", locale: "American English"),
        SpeechVoice(id: "af_nicole", name: "Nicole", locale: "American English"),
        SpeechVoice(id: "af_nova", name: "Nova", locale: "American English"),
        SpeechVoice(id: "af_river", name: "River", locale: "American English"),
        SpeechVoice(id: "af_sarah", name: "Sarah", locale: "American English"),
        SpeechVoice(id: "af_sky", name: "Sky", locale: "American English"),
        SpeechVoice(id: "am_adam", name: "Adam", locale: "American English"),
        SpeechVoice(id: "am_echo", name: "Echo", locale: "American English"),
        SpeechVoice(id: "am_eric", name: "Eric", locale: "American English"),
        SpeechVoice(id: "am_fenrir", name: "Fenrir", locale: "American English"),
        SpeechVoice(id: "am_liam", name: "Liam", locale: "American English"),
        .michael,
        SpeechVoice(id: "am_onyx", name: "Onyx", locale: "American English"),
        SpeechVoice(id: "am_puck", name: "Puck", locale: "American English"),
        SpeechVoice(id: "am_santa", name: "Santa", locale: "American English"),
        SpeechVoice(id: "bf_alice", name: "Alice", locale: "British English"),
        SpeechVoice(id: "bf_emma", name: "Emma", locale: "British English"),
        SpeechVoice(id: "bf_isabella", name: "Isabella", locale: "British English"),
        SpeechVoice(id: "bf_lily", name: "Lily", locale: "British English"),
        SpeechVoice(id: "bm_daniel", name: "Daniel", locale: "British English"),
        SpeechVoice(id: "bm_fable", name: "Fable", locale: "British English"),
        SpeechVoice(id: "bm_george", name: "George", locale: "British English"),
        SpeechVoice(id: "bm_lewis", name: "Lewis", locale: "British English"),
    ]
}

nonisolated enum SpeechEngineError: LocalizedError {
    case notLoaded
    case unsupportedVoice(String)
    case loadFailed(String)
    case warmUpFailed(String)
    case synthesisFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notLoaded: "Kokoro ONNX is not loaded."
        case .unsupportedVoice(let id): "Unsupported Kokoro voice: \(id)"
        case .loadFailed(let message): "Failed to load Kokoro ONNX: \(message)"
        case .warmUpFailed(let message): "ONNX warm-up failed: \(message)"
        case .synthesisFailed(let message): "Kokoro synthesis failed: \(message)"
        case .cancelled: "Kokoro synthesis was cancelled."
        }
    }
}

typealias SpeechPCM = KokoroAudio

nonisolated struct SpeechSynthesisResult: Sendable {
    let audio: SpeechPCM
    let elapsedSeconds: Double

    var durationSeconds: Double { audio.durationSeconds }
    var realTimeFactor: Double {
        guard audio.durationSeconds > 0 else { return 0 }
        return elapsedSeconds / audio.durationSeconds
    }
}

nonisolated struct SpeechWarmUpResult: Sendable {
    let elapsedSeconds: Double
}

/// Foreground reader and offline generation share the same ONNX inference actor.
nonisolated protocol SpeechSynthesisEngine: Actor {
    func load() async throws
    func warmUp(text: String, voice: SpeechVoice, speed: Float)
        async throws -> SpeechWarmUpResult
    func synthesize(text: String, voice: SpeechVoice, speed: Float,
                    maxChunkSeconds: Double) async throws -> SpeechSynthesisResult
    func unload() async
}

nonisolated enum SpeechEngineFactory {
    static func make(_ kind: SpeechEngineKind) -> any SpeechSynthesisEngine {
        KokoroONNXEngine.shared
    }
}
