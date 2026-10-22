import Foundation
import InkribeModelAssets

/// iOS-only variants. The Mac's single-model manifest and defaults stay intact.
enum IOSSpeechModelCatalog {
    static let smallID = "whisper-small-multilingual"
    static let revision = "90a64d80ea254cf67575b41a5971f972c79f7b45"
    static let all: [ModelAssetDescriptor] = [
        model("tiny", bytes: 77_691_713,
              sha: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
        model("base", bytes: 147_951_465,
              sha: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        model("small", bytes: 487_601_967,
              sha: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b")
    ]

    static func descriptor(_ id: String) throws -> ModelAssetDescriptor {
        guard let value = all.first(where: { $0.id == id }) else {
            throw IOSModelError.unknownVariant
        }
        return value
    }

    static func bundledURL(_ model: ModelAssetDescriptor) -> URL? {
        Bundle.main.url(forResource: (model.fileName as NSString).deletingPathExtension,
                        withExtension: "bin")
    }

    /// A build policy, never an end-user toggle. The bundled spec defines this
    /// condition for all configurations; cache fallback is disabled with it.
    static var downloadsEnabled: Bool {
        #if INKRIBE_IOS_BUNDLED_MODELS_ONLY
        false
        #else
        true
        #endif
    }

    private static func model(_ variant: String, bytes: Int64, sha: String) -> ModelAssetDescriptor {
        ModelAssetDescriptor(id: "whisper-\(variant)-multilingual", runtime: .whisper,
            displayName: "Whisper \(variant.capitalized) Multilingual",
            relativePath: "whisper/ggml-\(variant).bin", sourceRepository: "ggerganov/whisper.cpp",
            revision: revision,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/ggml-\(variant).bin?download=true")!,
            sha256: sha, byteCount: bytes, license: "MIT")
    }
}

enum IOSModelError: LocalizedError {
    case unknownVariant, missing(String), downloadsDisabled, busy, inUse, invalidDownload, insufficientSpace
    var errorDescription: String? {
        switch self {
        case .unknownVariant: "This speech model variant is not supported by this version of Inkribe."
        case .missing(let name): "\(name) is unavailable. Open Speech Models to download it, or select an available model."
        case .downloadsDisabled: "This build uses bundled speech models. Downloads are disabled."
        case .busy: "Wait for the current model operation to finish, or cancel it."
        case .inUse: "This model is used by a queued or running transcription. Cancel that transcription before removing it."
        case .invalidDownload: "The model download is incomplete or does not match its verified size and SHA-256. Retry the download."
        case .insufficientSpace: "There is not enough free storage to download this model. Free some space and try again."
        }
    }
}
