import Foundation
import InkribeModelAssets

public enum LLMRuntimeRelease {
    public static let upstreamRepository = "ggml-org/llama.cpp"
    public static let stableVersion = "0.4.1"
    public static let binaryTag = "b10964"
    public static let revision = "b29c606e28a01b1bc8c1351026a0fa6e616bf6c4"
    public static let archiveSHA256 = "b342a31c3160095d02777cbf1719013d4e6ff7556a1d46ab9eb5df0a93d13c47"
}

public enum LLMModel: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case qwen3_0_6B = "qwen3-0.6b-q4-k-m"
    case qwen3_1_7B = "qwen3-1.7b-q4-k-m"

    public static let defaultModel: Self = .qwen3_0_6B

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen3_0_6B: "Qwen3 0.6B"
        case .qwen3_1_7B: "Qwen3 1.7B"
        }
    }

    public var detail: String {
        switch self {
        case .qwen3_0_6B: "Faster and lighter. Recommended for most local AI actions."
        case .qwen3_1_7B: "Higher quality, with greater memory and compute requirements."
        }
    }
}

public enum LLMModelAsset {
    public static func descriptor(model: LLMModel = .defaultModel) throws -> ModelAssetDescriptor {
        let descriptor = try ModelAssetCatalog.bundledManifest().asset(id: model.rawValue)
        guard descriptor.runtime == .llm else {
            throw ModelAssetError.missingRuntimeAsset(.llm)
        }
        return descriptor
    }

    public static func descriptors() throws -> [ModelAssetDescriptor] {
        try LLMModel.allCases.map { try descriptor(model: $0) }
    }

    public static func checkedURL(
        resourcesURL: URL,
        model: LLMModel = .defaultModel
    ) throws -> URL {
        let descriptor = try descriptor(model: model)
        return try ModelAssetLocator(resourcesURL: resourcesURL).requireCheckedURL(for: descriptor)
    }

    public static func checkedURL(
        bundle: Bundle,
        model: LLMModel = .defaultModel
    ) throws -> URL {
        let descriptor = try descriptor(model: model)
        return try ModelAssetLocator(bundle: bundle).requireCheckedURL(for: descriptor)
    }
}

public struct LLMRuntimeConfiguration: Equatable, Sendable {
    public let contextSize: UInt32
    public let threadCount: Int32
    public let useGPU: Bool
    public let maximumOutputTokens: Int

    public init(
        contextSize: UInt32 = 4_096,
        threadCount: Int32,
        useGPU: Bool,
        maximumOutputTokens: Int = 1_024
    ) {
        self.contextSize = max(512, contextSize)
        self.threadCount = max(1, threadCount)
        self.useGPU = useGPU
        self.maximumOutputTokens = max(1, maximumOutputTokens)
    }

    public static var recommended: Self {
        let processorCount = ProcessInfo.processInfo.processorCount

        #if targetEnvironment(simulator)
        return Self(
            threadCount: Int32(max(1, min(6, processorCount - 1))),
            useGPU: false
        )
        #elseif arch(arm64)
        return Self(
            threadCount: Int32(max(1, min(8, processorCount - 2))),
            useGPU: true
        )
        #else
        return Self(
            threadCount: Int32(max(1, min(6, processorCount - 1))),
            useGPU: false
        )
        #endif
    }
}

public struct LLMSamplingConfiguration: Equatable, Sendable {
    public let temperature: Float
    public let seed: UInt32

    public init(temperature: Float = 0.2, seed: UInt32 = 42) {
        self.temperature = temperature
        self.seed = seed
    }
}

public struct LLMGenerationRequest: Equatable, Sendable {
    public let systemPrompt: String?
    public let prompt: String
    public let maximumOutputTokens: Int
    public let sampling: LLMSamplingConfiguration

    public init(
        systemPrompt: String? = nil,
        prompt: String,
        maximumOutputTokens: Int,
        sampling: LLMSamplingConfiguration = .init()
    ) {
        self.systemPrompt = systemPrompt
        self.prompt = prompt
        self.maximumOutputTokens = maximumOutputTokens
        self.sampling = sampling
    }
}

public typealias LLMTokenHandler = @Sendable (String) -> Void

public protocol LLMRuntimeProtocol: Sendable {
    func loadModel() async throws
    func unloadModel() async
    func generate(
        _ request: LLMGenerationRequest,
        onToken: LLMTokenHandler?
    ) async throws -> String
}

public extension LLMRuntimeProtocol {
    func generate(_ request: LLMGenerationRequest) async throws -> String {
        try await generate(request, onToken: nil)
    }
}

public enum LLMRuntimeError: Error, Equatable, Sendable {
    case modelNotLoaded
    case couldNotLoadModel(String)
    case couldNotCreateContext
    case couldNotCreateSampler
    case missingChatTemplate
    case chatTemplateFormattingFailed(Int32)
    case emptyPrompt
    case invalidMaximumOutputTokens(Int)
    case invalidTemperature(Float)
    case promptTooLong(promptTokens: Int, requestedOutputTokens: Int, contextSize: Int)
    case tokenizationFailed(Int32)
    case decodeFailed(Int32)
}

extension LLMRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "The local language model is not loaded."
        case .couldNotLoadModel(let id):
            "The local language model could not load model \(id)."
        case .couldNotCreateContext:
            "The local language model could not create an inference context."
        case .couldNotCreateSampler:
            "The local language model could not create a token sampler."
        case .missingChatTemplate:
            "The local language model does not provide a supported chat template."
        case .chatTemplateFormattingFailed(let code):
            "The local language model could not format the chat prompt (code \(code))."
        case .emptyPrompt:
            "The generation prompt is empty."
        case .invalidMaximumOutputTokens(let count):
            "Requested output token count \(count) is outside the configured runtime limit."
        case .invalidTemperature(let temperature):
            "Sampling temperature \(temperature) must be between 0 and 2."
        case .promptTooLong(let promptTokens, let requestedOutputTokens, let contextSize):
            "Prompt and requested output require \(promptTokens + requestedOutputTokens) tokens, exceeding context size \(contextSize)."
        case .tokenizationFailed(let code):
            "Prompt tokenization failed with native result \(code)."
        case .decodeFailed(let code):
            "Local generation failed with native decode result \(code)."
        }
    }
}
