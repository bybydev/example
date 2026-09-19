import Foundation
import InkribeModelAssets
import Logging
import whisper

public actor NativeWhisperRuntime: WhisperRuntimeProtocol {
    private let modelURL: URL
    private let configuration: WhisperRuntimeConfiguration
    private let logger = Logger(label: "Inkribe.WhisperRuntime")

    private var contextHandle: WhisperContextHandle?
    private var integrityChecked = false

    public init(
        modelURL: URL,
        configuration: WhisperRuntimeConfiguration = .recommended
    ) {
        self.modelURL = modelURL
        self.configuration = configuration
    }

    public static func bundled(
        in bundle: Bundle = .main,
        configuration: WhisperRuntimeConfiguration = .recommended
    ) throws -> NativeWhisperRuntime {
        let descriptor = try WhisperModelAsset.descriptor()
        let modelURL = try ModelAssetLocator(bundle: bundle).requireURL(for: descriptor)
        return NativeWhisperRuntime(modelURL: modelURL, configuration: configuration)
    }

    public var isModelLoaded: Bool {
        contextHandle != nil
    }

    public func loadModel() async throws {
        try loadModelIfNeeded()
    }

    public func unloadModel() async {
        guard contextHandle != nil else { return }
        contextHandle = nil
        logger.info("Whisper model unloaded")
    }

    public func transcribe(
        mediaURL: URL,
        requestedLanguageCode: String?,
        progress: WhisperProgressHandler?
    ) async throws -> WhisperTranscriptionResult {
        let buffer = try WhisperWaveDecoder.decode(url: mediaURL)
        return try await transcribe(
            buffer: buffer,
            requestedLanguageCode: requestedLanguageCode,
            progress: progress
        )
    }

    public func transcribe(
        buffer: WhisperAudioBuffer,
        requestedLanguageCode: String?,
        progress: WhisperProgressHandler?
    ) async throws -> WhisperTranscriptionResult {
        try Task.checkCancellation()
        guard !buffer.samples.isEmpty else { throw WhisperRuntimeError.emptyAudio }
        guard buffer.sampleRate == WhisperAudioBuffer.requiredSampleRate else {
            throw WhisperRuntimeError.unsupportedSampleRate(buffer.sampleRate)
        }

        try loadModelIfNeeded()
        let callbackState = WhisperCallbackState(progressHandler: progress)
        let startedAt = Date()

        logger.debug(
            "Whisper transcription started",
            metadata: [
                "sample_count": "\(buffer.samples.count)",
                "thread_count": "\(configuration.threadCount)",
                "backend": "\(configuration.useGPU ? "metal" : "cpu")"
            ]
        )

        do {
            let result = try await withTaskCancellationHandler {
                try performTranscription(
                    samples: buffer.samples,
                    requestedLanguageCode: requestedLanguageCode,
                    callbackState: callbackState
                )
            } onCancel: {
                callbackState.cancel()
            }

            logger.debug(
                "Whisper transcription finished",
                metadata: [
                    "segment_count": "\(result.segments.count)",
                    "duration_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                ]
            )
            return result
        } catch is CancellationError {
            logger.debug("Whisper transcription cancelled")
            throw CancellationError()
        } catch {
            logger.error(
                "Whisper transcription failed",
                metadata: ["error_type": "\(String(reflecting: type(of: error)))"]
            )
            throw error
        }
    }

    private func loadModelIfNeeded() throws {
        guard contextHandle == nil else { return }

        let descriptor = try WhisperModelAsset.descriptor()
        if !integrityChecked {
            try ModelAssetIntegrityChecker.check(modelURL, against: descriptor)
            integrityChecked = true
        }

        var nativeConfiguration = whisper_context_default_params()
        nativeConfiguration.use_gpu = configuration.useGPU
        nativeConfiguration.flash_attn = configuration.flashAttention

        let startedAt = Date()
        guard let loaded = whisper_init_from_file_with_params(modelURL.path, nativeConfiguration) else {
            logger.error("Whisper model load failed", metadata: ["model": "\(descriptor.id)"])
            throw WhisperRuntimeError.couldNotLoadModel(descriptor.id)
        }

        contextHandle = WhisperContextHandle(pointer: loaded)
        logger.info(
            "Whisper model loaded",
            metadata: [
                "model": "\(descriptor.id)",
                "backend": "\(configuration.useGPU ? "metal" : "cpu")",
                "duration_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ]
        )
    }

    private func performTranscription(
        samples: [Float],
        requestedLanguageCode: String?,
        callbackState: WhisperCallbackState
    ) throws -> WhisperTranscriptionResult {
        guard let context = contextHandle?.pointer else {
            throw WhisperRuntimeError.modelNotLoaded
        }

        if let requestedLanguageCode,
           !requestedLanguageCode.isEmpty,
           requestedLanguageCode != "auto" {
            let languageID = requestedLanguageCode.withCString { whisper_lang_id($0) }
            guard languageID >= 0 else {
                throw WhisperRuntimeError.invalidLanguageCode(requestedLanguageCode)
            }
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = configuration.threadCount
        params.translate = false
        params.no_context = true
        params.no_timestamps = false
        params.single_segment = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.token_timestamps = true
        // Let whisper.cpp enter auto-language mode through its explicit
        // "auto" language sentinel. Passing detect_language = true with a nil
        // language can complete successfully with zero text segments.
        params.detect_language = false

        let unmanagedState = Unmanaged.passRetained(callbackState)
        defer { unmanagedState.release() }
        let userData = unmanagedState.toOpaque()

        params.progress_callback = { _, _, nativeProgress, opaque in
            guard let opaque else { return }
            Unmanaged<WhisperCallbackState>
                .fromOpaque(opaque)
                .takeUnretainedValue()
                .report(progressPercent: nativeProgress)
        }
        params.progress_callback_user_data = userData
        params.abort_callback = { opaque in
            guard let opaque else { return false }
            return Unmanaged<WhisperCallbackState>
                .fromOpaque(opaque)
                .takeUnretainedValue()
                .isCancelled
        }
        params.abort_callback_user_data = userData

        callbackState.report(progressPercent: 0)

        let nativeResult: Int32
        if let requestedLanguageCode,
           !requestedLanguageCode.isEmpty,
           requestedLanguageCode != "auto" {
            nativeResult = requestedLanguageCode.withCString { language in
                params.language = language
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        } else {
            nativeResult = "auto".withCString { language in
                params.language = language
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }

        if callbackState.isCancelled {
            throw CancellationError()
        }
        guard nativeResult == 0 else {
            throw WhisperRuntimeError.transcriptionFailed(nativeResult)
        }

        let segmentCount = Int(whisper_full_n_segments(context))
        var segments: [WhisperSegment] = []
        var tokens: [WhisperToken] = []
        segments.reserveCapacity(segmentCount)

        let endOfTextToken = whisper_token_eot(context)
        for index in 0..<segmentCount {
            let segmentIndex = Int32(index)
            if let textPointer = whisper_full_get_segment_text(context, segmentIndex) {
                let start = TimeInterval(whisper_full_get_segment_t0(context, segmentIndex)) / 100.0
                let end = TimeInterval(whisper_full_get_segment_t1(context, segmentIndex)) / 100.0
                segments.append(
                    WhisperSegment(
                        startTime: start,
                        endTime: end,
                        text: String(cString: textPointer)
                    )
                )
            }

            let tokenCount = Int(whisper_full_n_tokens(context, segmentIndex))
            for tokenIndex in 0..<tokenCount {
                let nativeTokenIndex = Int32(tokenIndex)
                let data = whisper_full_get_token_data(
                    context,
                    segmentIndex,
                    nativeTokenIndex
                )
                guard data.id < endOfTextToken,
                      let tokenText = whisper_full_get_token_text(
                        context,
                        segmentIndex,
                        nativeTokenIndex
                      ) else {
                    continue
                }

                let text = String(cString: tokenText)
                guard !text.isEmpty else { continue }
                tokens.append(
                    WhisperToken(
                        startTime: TimeInterval(data.t0) / 100.0,
                        endTime: TimeInterval(data.t1) / 100.0,
                        text: text
                    )
                )
            }
        }

        let languageID = whisper_full_lang_id(context)
        let languageCode: String?
        if let languagePointer = whisper_lang_str(languageID) {
            languageCode = String(cString: languagePointer)
        } else {
            languageCode = nil
        }
        callbackState.report(progressPercent: 100)

        return WhisperTranscriptionResult(
            detectedLanguageCode: languageCode,
            segments: segments,
            tokens: tokens
        )
    }
}

private final class WhisperContextHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        whisper_free(pointer)
    }
}

private final class WhisperCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let progressHandler: WhisperProgressHandler?

    init(progressHandler: WhisperProgressHandler?) {
        self.progressHandler = progressHandler
    }

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

    func report(progressPercent: Int32) {
        lock.lock()
        let shouldReport = !cancelled
        let handler = progressHandler
        lock.unlock()

        guard shouldReport else { return }
        let clamped = min(100, max(0, progressPercent))
        handler?(Double(clamped) / 100.0)
    }
}
