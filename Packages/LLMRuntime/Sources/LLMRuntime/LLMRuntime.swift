import Foundation

public struct LLMGenerationRequest: Equatable, Sendable {
    public let prompt: String
    public let maximumOutputTokens: Int

    public init(prompt: String, maximumOutputTokens: Int) {
        self.prompt = prompt
        self.maximumOutputTokens = maximumOutputTokens
    }
}

public protocol LLMRuntimeProtocol: Sendable {
    func generate(_ request: LLMGenerationRequest) async throws -> String
}
