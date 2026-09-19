import Foundation
import InkribeCore
import LLMRuntime

public actor TranscriptAIService {
    public static let minimumInputCharacters = 8

    private let runtime: any LLMRuntimeProtocol
    private let chunker: TranscriptAIChunker

    public init(
        runtime: any LLMRuntimeProtocol,
        chunker: TranscriptAIChunker = .init()
    ) {
        self.runtime = runtime
        self.chunker = chunker
    }

    public static func bundled(
        in bundle: Bundle = .main,
        model: LLMModel = .defaultModel,
        configuration: LLMRuntimeConfiguration = .recommended,
        chunker: TranscriptAIChunker = .init()
    ) throws -> TranscriptAIService {
        let runtime = try NativeLLMRuntime.bundled(
            in: bundle,
            model: model,
            configuration: configuration
        )
        return TranscriptAIService(runtime: runtime, chunker: chunker)
    }

    public func generate(
        action: TranscriptAIAction,
        transcript: Transcript,
        progress: TranscriptAIProgressHandler? = nil
    ) async throws -> TranscriptAIResult {
        try Task.checkCancellation()
        let input = sourceText(for: transcript)
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw TranscriptAIError.emptyInput }
        guard normalized.count >= Self.minimumInputCharacters else {
            throw TranscriptAIError.inputTooShort(
                minimumCharacters: Self.minimumInputCharacters
            )
        }

        await report(
            TranscriptAIProgress(phase: .preparing, fraction: 0),
            to: progress
        )
        try await runtime.loadModel()
        try Task.checkCancellation()

        let sourceChunks = chunker.chunks(for: input)
        var transformed: [String] = []
        transformed.reserveCapacity(sourceChunks.count)

        for (index, chunk) in sourceChunks.enumerated() {
            try Task.checkCancellation()
            await report(
                TranscriptAIProgress(
                    phase: .transforming(
                        chunk: index + 1,
                        totalChunks: sourceChunks.count
                    ),
                    fraction: 0.05 + (0.70 * Double(index) / Double(max(sourceChunks.count, 1)))
                ),
                to: progress
            )

            let outputs = try await transformChunk(
                action: action,
                text: chunk,
                chunkIndex: index,
                chunkCount: sourceChunks.count
            )
            transformed.append(contentsOf: outputs)
        }

        let finalContent: String
        if action.supportsEditedTextReplacement {
            finalContent = transformed.joined(separator: "\n\n")
        } else {
            finalContent = try await mergeDerivedOutputs(
                action: action,
                outputs: transformed,
                progress: progress
            )
        }

        let sanitized = sanitize(finalContent)
        guard !sanitized.isEmpty else { throw TranscriptAIError.emptyResult }

        await report(
            TranscriptAIProgress(phase: .finishing, fraction: 1),
            to: progress
        )

        return TranscriptAIResult(
            action: action,
            sourceRevision: transcript.revision,
            content: sanitized
        )
    }

    public func unloadModel() async {
        await runtime.unloadModel()
    }

    private func transformChunk(
        action: TranscriptAIAction,
        text: String,
        chunkIndex: Int,
        chunkCount: Int
    ) async throws -> [String] {
        try Task.checkCancellation()
        let request = LLMGenerationRequest(
            systemPrompt: TranscriptAIPromptTemplates.systemPrompt,
            prompt: TranscriptAIPromptTemplates.transformPrompt(
                action: action,
                text: text,
                chunkIndex: chunkIndex,
                chunkCount: chunkCount
            ),
            maximumOutputTokens: action.maximumOutputTokens,
            sampling: LLMSamplingConfiguration(
                temperature: action.samplingTemperature,
                seed: 42
            )
        )

        do {
            let output = sanitize(try await runtime.generate(request))
            guard !output.isEmpty else { throw TranscriptAIError.emptyResult }
            return [output]
        } catch let runtimeError as LLMRuntimeError {
            guard case .promptTooLong = runtimeError,
                  text.count > 256 else {
                throw runtimeError
            }

            let fallbackMaximum = max(256, text.count / 2)
            let fallbackChunks = TranscriptAIChunker(
                maximumCharacters: fallbackMaximum
            ).chunks(for: text)
            guard fallbackChunks.count > 1 else { throw runtimeError }

            var outputs: [String] = []
            outputs.reserveCapacity(fallbackChunks.count)
            for (index, fallbackChunk) in fallbackChunks.enumerated() {
                try Task.checkCancellation()
                outputs.append(
                    contentsOf: try await transformChunk(
                        action: action,
                        text: fallbackChunk,
                        chunkIndex: index,
                        chunkCount: fallbackChunks.count
                    )
                )
            }
            return outputs
        }
    }

    private func mergeDerivedOutputs(
        action: TranscriptAIAction,
        outputs: [String],
        progress: TranscriptAIProgressHandler?
    ) async throws -> String {
        guard outputs.count > 1 else { return outputs.first ?? "" }

        var current = outputs
        var pass = 1

        while current.count > 1 {
            try Task.checkCancellation()
            var next: [String] = []
            let groups = stride(from: 0, to: current.count, by: 2).map { start -> [String] in
                let end = min(start + 2, current.count)
                return Array(current[start..<end])
            }
            next.reserveCapacity(groups.count)

            for (groupIndex, group) in groups.enumerated() {
                try Task.checkCancellation()
                await report(
                    TranscriptAIProgress(
                        phase: .merging(
                            pass: pass,
                            chunk: groupIndex + 1,
                            totalChunks: groups.count
                        ),
                        fraction: min(
                            0.75 + (0.20 * Double(groupIndex) / Double(max(groups.count, 1))),
                            0.95
                        )
                    ),
                    to: progress
                )

                if group.count == 1 {
                    next.append(group[0])
                    continue
                }

                let partials = group.enumerated().map { index, content in
                    "--- partial \(index + 1) ---\n\(content)"
                }.joined(separator: "\n\n")

                let request = LLMGenerationRequest(
                    systemPrompt: TranscriptAIPromptTemplates.systemPrompt,
                    prompt: TranscriptAIPromptTemplates.mergePrompt(
                        action: action,
                        partialOutputs: partials,
                        mergePass: pass
                    ),
                    maximumOutputTokens: action.maximumOutputTokens,
                    sampling: LLMSamplingConfiguration(
                        temperature: action.samplingTemperature,
                        seed: 42
                    )
                )
                let merged = sanitize(try await runtime.generate(request))
                guard !merged.isEmpty else { throw TranscriptAIError.emptyResult }
                next.append(merged)
            }

            current = next
            pass += 1
        }

        return current[0]
    }

    private func sourceText(for transcript: Transcript) -> String {
        transcript.editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? transcript.rawText
            : transcript.editedText
    }

    private func sanitize(_ output: String) -> String {
        var value = output
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<|im_start|>assistant", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("<think>") {
            guard let closing = value.range(of: "</think>") else { return "" }
            value = String(value[closing.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let accidentalWrapperLines: Set<String> = [
            "<<RESULT>>",
            "<RESULT>",
            "</RESULT>",
            "<</RESULT>>"
        ]
        value = value
            .components(separatedBy: .newlines)
            .filter {
                !accidentalWrapperLines.contains(
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return value
    }

    private func report(
        _ value: TranscriptAIProgress,
        to progress: TranscriptAIProgressHandler?
    ) async {
        guard let progress else { return }
        await progress(value)
    }
}
