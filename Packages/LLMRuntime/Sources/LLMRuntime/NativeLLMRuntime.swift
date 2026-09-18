import Foundation
import InkribeModelAssets
import Logging
import llama

public actor NativeLLMRuntime: LLMRuntimeProtocol {
    private let modelURL: URL
    private let configuration: LLMRuntimeConfiguration
    private let logger = Logger(label: "Inkribe.LLMRuntime")

    private var nativeState: LlamaNativeState?
    private var integrityChecked = false

    public init(
        modelURL: URL,
        configuration: LLMRuntimeConfiguration = .recommended
    ) {
        self.modelURL = modelURL
        self.configuration = configuration
    }

    public static func bundled(
        in bundle: Bundle = .main,
        configuration: LLMRuntimeConfiguration = .recommended
    ) throws -> NativeLLMRuntime {
        let descriptor = try LLMModelAsset.descriptor()
        let modelURL = try ModelAssetLocator(bundle: bundle).requireURL(for: descriptor)
        return NativeLLMRuntime(modelURL: modelURL, configuration: configuration)
    }

    public var isModelLoaded: Bool { nativeState != nil }

    public func loadModel() async throws {
        try loadModelIfNeeded()
    }

    public func unloadModel() async {
        guard nativeState != nil else { return }
        nativeState = nil
        logger.info("Local language model unloaded")
    }

    public func generate(
        _ request: LLMGenerationRequest,
        onToken: LLMTokenHandler?
    ) async throws -> String {
        try Task.checkCancellation()
        guard !request.prompt.isEmpty else { throw LLMRuntimeError.emptyPrompt }
        guard request.maximumOutputTokens > 0,
              request.maximumOutputTokens <= configuration.maximumOutputTokens else {
            throw LLMRuntimeError.invalidMaximumOutputTokens(request.maximumOutputTokens)
        }
        guard request.sampling.temperature >= 0, request.sampling.temperature <= 2 else {
            throw LLMRuntimeError.invalidTemperature(request.sampling.temperature)
        }

        try loadModelIfNeeded()
        guard let state = nativeState else { throw LLMRuntimeError.modelNotLoaded }
        state.abortState.reset()
        let startedAt = Date()

        logger.debug(
            "Local generation started",
            metadata: [
                "prompt_utf8_bytes": "\(request.prompt.utf8.count)",
                "maximum_output_tokens": "\(request.maximumOutputTokens)",
                "thread_count": "\(configuration.threadCount)",
                "backend": "\(configuration.useGPU ? "metal" : "cpu")"
            ]
        )

        do {
            let result = try await withTaskCancellationHandler {
                try performGeneration(request, state: state, onToken: onToken)
            } onCancel: {
                state.abortState.cancel()
            }

            logger.debug(
                "Local generation finished",
                metadata: [
                    "output_utf8_bytes": "\(result.utf8.count)",
                    "duration_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                ]
            )
            return result
        } catch is CancellationError {
            logger.debug("Local generation cancelled")
            throw CancellationError()
        } catch {
            logger.error(
                "Local generation failed",
                metadata: ["error_type": "\(String(reflecting: type(of: error)))"]
            )
            throw error
        }
    }

    private func loadModelIfNeeded() throws {
        guard nativeState == nil else { return }

        let descriptor = try LLMModelAsset.descriptor()
        if !integrityChecked {
            try ModelAssetIntegrityChecker.check(modelURL, against: descriptor)
            integrityChecked = true
        }

        LlamaBackendLifetime.shared.acquire()
        let startedAt = Date()
        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = configuration.useGPU ? -1 : 0

        guard let loadedModel = llama_model_load_from_file(modelURL.path, modelParameters) else {
            LlamaBackendLifetime.shared.release()
            logger.error("Local model load failed", metadata: ["model": "\(descriptor.id)"])
            throw LLMRuntimeError.couldNotLoadModel(descriptor.id)
        }

        let abortState = LLMAbortState()
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = configuration.contextSize
        // n_batch is the logical maximum submitted to llama_decode; n_ubatch
        // keeps the physical micro-batch conservative while allowing long prompts.
        contextParameters.n_batch = configuration.contextSize
        contextParameters.n_ubatch = min(configuration.contextSize, 512)
        contextParameters.n_threads = configuration.threadCount
        contextParameters.n_threads_batch = configuration.threadCount
        contextParameters.abort_callback = { opaque in
            guard let opaque else { return false }
            return Unmanaged<LLMAbortState>
                .fromOpaque(opaque)
                .takeUnretainedValue()
                .isCancelled
        }
        contextParameters.abort_callback_data = Unmanaged.passUnretained(abortState).toOpaque()

        guard let loadedContext = llama_init_from_model(loadedModel, contextParameters) else {
            llama_model_free(loadedModel)
            LlamaBackendLifetime.shared.release()
            logger.error("Local inference context creation failed", metadata: ["model": "\(descriptor.id)"])
            throw LLMRuntimeError.couldNotCreateContext
        }

        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            LlamaBackendLifetime.shared.release()
            logger.error("Local model vocabulary unavailable", metadata: ["model": "\(descriptor.id)"])
            throw LLMRuntimeError.couldNotLoadModel(descriptor.id)
        }

        nativeState = LlamaNativeState(
            model: loadedModel,
            context: loadedContext,
            vocab: loadedVocab,
            abortState: abortState
        )

        logger.info(
            "Local language model loaded",
            metadata: [
                "model": "\(descriptor.id)",
                "context_size": "\(configuration.contextSize)",
                "backend": "\(configuration.useGPU ? "metal" : "cpu")",
                "duration_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ]
        )
    }

    private func performGeneration(
        _ request: LLMGenerationRequest,
        state: LlamaNativeState,
        onToken: LLMTokenHandler?
    ) throws -> String {
        let promptTokens = try tokenize(request.prompt, vocab: state.vocab)
        let contextSize = Int(configuration.contextSize)
        guard promptTokens.count + request.maximumOutputTokens <= contextSize else {
            throw LLMRuntimeError.promptTooLong(
                promptTokens: promptTokens.count,
                requestedOutputTokens: request.maximumOutputTokens,
                contextSize: contextSize
            )
        }

        llama_memory_clear(llama_get_memory(state.context), true)
        defer { llama_memory_clear(llama_get_memory(state.context), true) }

        var batch = llama_batch_init(Int32(max(promptTokens.count, 1)), 0, 1)
        defer { llama_batch_free(batch) }

        for (position, token) in promptTokens.enumerated() {
            add(
                token: token,
                position: Int32(position),
                requestLogits: position == promptTokens.count - 1,
                to: &batch
            )
        }

        try checkDecodeResult(
            llama_decode(state.context, batch),
            abortState: state.abortState
        )

        guard let sampler = makeSampler(request.sampling) else {
            throw LLMRuntimeError.couldNotCreateSampler
        }
        defer { llama_sampler_free(sampler) }

        var output = ""
        var pendingUTF8: [UInt8] = []
        var currentPosition = promptTokens.count

        for _ in 0..<request.maximumOutputTokens {
            try throwIfCancelled(state.abortState)

            let token = llama_sampler_sample(sampler, state.context, -1)
            if llama_vocab_is_eog(state.vocab, token) { break }

            pendingUTF8.append(contentsOf: try pieceBytes(token: token, vocab: state.vocab))
            if let piece = String(bytes: pendingUTF8, encoding: .utf8) {
                output += piece
                onToken?(piece)
                pendingUTF8.removeAll(keepingCapacity: true)
            }

            batch.n_tokens = 0
            add(
                token: token,
                position: Int32(currentPosition),
                requestLogits: true,
                to: &batch
            )
            currentPosition += 1

            try checkDecodeResult(
                llama_decode(state.context, batch),
                abortState: state.abortState
            )
        }

        if !pendingUTF8.isEmpty {
            let finalPiece = String(decoding: pendingUTF8, as: UTF8.self)
            output += finalPiece
            onToken?(finalPiece)
        }

        try throwIfCancelled(state.abortState)
        return output
    }

    private func makeSampler(_ configuration: LLMSamplingConfiguration) -> UnsafeMutablePointer<llama_sampler>? {
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            return nil
        }
        if configuration.temperature == 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(configuration.temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(configuration.seed))
        }
        return sampler
    }

    private func tokenize(_ text: String, vocab: OpaquePointer) throws -> [llama_token] {
        let utf8Count = text.utf8.count
        let required = -llama_tokenize(vocab, text, Int32(utf8Count), nil, 0, true, false)
        guard required > 0 else { throw LLMRuntimeError.tokenizationFailed(required) }

        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: Int(required))
        defer { tokens.deallocate() }
        let count = llama_tokenize(
            vocab,
            text,
            Int32(utf8Count),
            tokens,
            required,
            true,
            false
        )
        guard count >= 0 else { throw LLMRuntimeError.tokenizationFailed(count) }
        return Array(UnsafeBufferPointer(start: tokens, count: Int(count)))
    }

    private func pieceBytes(token: llama_token, vocab: OpaquePointer) throws -> [UInt8] {
        var inline = [CChar](repeating: 0, count: 32)
        let inlineCount = inline.withUnsafeMutableBufferPointer { buffer in
            llama_token_to_piece(vocab, token, buffer.baseAddress, Int32(buffer.count), 0, false)
        }
        if inlineCount >= 0 {
            return inline.prefix(Int(inlineCount)).map { UInt8(bitPattern: $0) }
        }

        var expanded = [CChar](repeating: 0, count: Int(-inlineCount))
        let expandedCount = expanded.withUnsafeMutableBufferPointer { buffer in
            llama_token_to_piece(vocab, token, buffer.baseAddress, Int32(buffer.count), 0, false)
        }
        guard expandedCount >= 0 else { throw LLMRuntimeError.decodeFailed(expandedCount) }
        return expanded.prefix(Int(expandedCount)).map { UInt8(bitPattern: $0) }
    }

    private func add(
        token: llama_token,
        position: llama_pos,
        requestLogits: Bool,
        to batch: inout llama_batch
    ) {
        let index = Int(batch.n_tokens)
        batch.token[index] = token
        batch.pos[index] = position
        batch.n_seq_id[index] = 1
        batch.seq_id[index]![0] = 0
        batch.logits[index] = requestLogits ? 1 : 0
        batch.n_tokens += 1
    }

    private func checkDecodeResult(_ result: Int32, abortState: LLMAbortState) throws {
        if abortState.isCancelled { throw CancellationError() }
        guard result == 0 else { throw LLMRuntimeError.decodeFailed(result) }
    }

    private func throwIfCancelled(_ abortState: LLMAbortState) throws {
        if abortState.isCancelled { throw CancellationError() }
    }
}

private final class LlamaNativeState: @unchecked Sendable {
    let model: OpaquePointer
    let context: OpaquePointer
    let vocab: OpaquePointer
    let abortState: LLMAbortState

    init(model: OpaquePointer, context: OpaquePointer, vocab: OpaquePointer, abortState: LLMAbortState) {
        self.model = model
        self.context = context
        self.vocab = vocab
        self.abortState = abortState
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
        LlamaBackendLifetime.shared.release()
    }
}

private final class LLMAbortState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }
}

private final class LlamaBackendLifetime: @unchecked Sendable {
    static let shared = LlamaBackendLifetime()
    private let lock = NSLock()
    private var referenceCount = 0

    func acquire() {
        lock.lock()
        defer { lock.unlock() }
        if referenceCount == 0 { llama_backend_init() }
        referenceCount += 1
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard referenceCount > 0 else { return }
        referenceCount -= 1
        if referenceCount == 0 { llama_backend_free() }
    }
}
