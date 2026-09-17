import Foundation
import Testing
@testable import LLMRuntime

@Suite("LLM runtime")
struct LLMRuntimeTests {
    @Test func releaseAndModelPinsAreStable() throws {
        #expect(LLMRuntimeRelease.stableVersion == "0.4.1")
        #expect(LLMRuntimeRelease.binaryTag == "b10964")
        #expect(LLMRuntimeRelease.revision.count == 40)
        #expect(LLMRuntimeRelease.archiveSHA256.count == 64)

        let descriptor = try LLMModelAsset.descriptor()
        #expect(descriptor.id == "qwen3-1.7b-q4-k-m")
        #expect(descriptor.relativePath == "qwen/Qwen3-1.7B-Q4_K_M.gguf")
    }

    @Test func explicitConfigurationClampsUnsafeValues() {
        let configuration = LLMRuntimeConfiguration(
            contextSize: 64,
            threadCount: 0,
            useGPU: false,
            maximumOutputTokens: 0
        )

        #expect(configuration.contextSize == 512)
        #expect(configuration.threadCount == 1)
        #expect(!configuration.useGPU)
        #expect(configuration.maximumOutputTokens == 1)
    }

    @Test func generationRequestKeepsDeterministicSamplingConfiguration() {
        let request = LLMGenerationRequest(
            prompt: "Summarize this transcript.",
            maximumOutputTokens: 128,
            sampling: .init(temperature: 0.15, seed: 7)
        )

        #expect(request.maximumOutputTokens == 128)
        #expect(request.sampling.temperature == 0.15)
        #expect(request.sampling.seed == 7)
    }

    @Test func runtimeErrorsDoNotContainPromptContent() {
        let error = LLMRuntimeError.promptTooLong(
            promptTokens: 4_000,
            requestedOutputTokens: 512,
            contextSize: 4_096
        )

        #expect(error.errorDescription?.contains("4512") == true)
        #expect(error.errorDescription?.contains("transcript") == false)
    }
}
