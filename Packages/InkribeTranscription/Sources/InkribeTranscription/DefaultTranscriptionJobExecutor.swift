import DiarizationRuntime
import Foundation
import InkribeAudio
import InkribeCore
import InkribePersistence
import WhisperRuntime

public protocol TranscriptionRuntimeManaging: Sendable {
    func unloadTranscriptionModel() async
}

public struct DefaultTranscriptionJobExecutor: TranscriptionJobExecuting, TranscriptionRuntimeManaging, Sendable {
    private let mediaStore: DurableMediaStore
    private let decoder: AudioMediaDecoder
    private let whisperRuntime: any WhisperRuntimeProtocol
    private let diarizationRuntime: (any SpeakerDiarizationRuntimeProtocol)?
    private let transcriptRepository: any TranscriptRepository

    public init(
        mediaStore: DurableMediaStore,
        decoder: AudioMediaDecoder = AudioMediaDecoder(),
        whisperRuntime: any WhisperRuntimeProtocol,
        diarizationRuntime: (any SpeakerDiarizationRuntimeProtocol)? = nil,
        transcriptRepository: any TranscriptRepository
    ) {
        self.mediaStore = mediaStore
        self.decoder = decoder
        self.whisperRuntime = whisperRuntime
        self.diarizationRuntime = diarizationRuntime
        self.transcriptRepository = transcriptRepository
    }

    public static func bundled(
        mediaStore: DurableMediaStore,
        transcriptRepository: any TranscriptRepository,
        bundle: Bundle = .main
    ) throws -> Self {
        Self(
            mediaStore: mediaStore,
            whisperRuntime: try NativeWhisperRuntime.bundled(in: bundle),
            diarizationRuntime: try NativeSpeakerDiarizationRuntime.bundled(in: bundle),
            transcriptRepository: transcriptRepository
        )
    }

    public func execute(
        payload: TranscriptionJob.Payload,
        progress: @escaping TranscriptionProgressHandler
    ) async throws {
        try Task.checkCancellation()
        await progress(0.02, "Preparing audio")

        let transcriptID = TranscriptID(rawValue: payload.transcriptID)
        guard var transcript = try await transcriptRepository.transcript(id: transcriptID) else {
            throw TranscriptionJobError.transcriptNotFound(payload.transcriptID)
        }

        let mediaReference = DurableMediaReference(
            relativePath: payload.sourceMediaRelativePath
        )
        let mediaURL = try await mediaStore.url(for: mediaReference)
        let decoded = try await decoder.decodeForTranscription(url: mediaURL)
        try Task.checkCancellation()
        await progress(0.18, "Transcribing")

        let stream = AsyncStream<Double>.makeStream()
        let progressTask = Task {
            for await fraction in stream.stream {
                let mapped = 0.18 + min(max(fraction, 0), 1) * 0.55
                await progress(mapped, "Transcribing")
            }
        }

        let requestedLanguage = normalizedLanguage(payload.requestedLanguage)
        let result: WhisperTranscriptionResult
        do {
            result = try await whisperRuntime.transcribe(
                buffer: WhisperAudioBuffer(
                    samples: decoded.samples,
                    sampleRate: Int(decoded.metadata.sampleRate)
                ),
                requestedLanguageCode: requestedLanguage,
                progress: { fraction in
                    stream.continuation.yield(fraction)
                }
            )
            stream.continuation.finish()
            await progressTask.value
        } catch {
            stream.continuation.finish()
            progressTask.cancel()
            _ = await progressTask.result
            throw error
        }

        try Task.checkCancellation()

        let aligned: SpeakerAlignmentResult
        if let diarizationRuntime {
            await progress(0.76, "Detecting speakers")
            let speakerTurns = try await diarizationRuntime.diarize(
                samples: decoded.samples,
                sampleRate: Int(decoded.metadata.sampleRate),
                speakerCount: nil
            )
            aligned = SpeakerAlignmentEngine().align(
                tokens: result.tokens,
                speakerTurns: speakerTurns,
                fallbackSegments: result.segments
            )
        } else {
            aligned = SpeakerAlignmentEngine().align(
                tokens: result.tokens,
                speakerTurns: [],
                fallbackSegments: result.segments
            )
        }

        try Task.checkCancellation()
        await progress(0.93, "Saving transcript")

        let previousRawText = transcript.rawText
        let previousEditedText = transcript.editedText
        let shouldKeepEditorInSync = previousEditedText.isEmpty || previousEditedText == previousRawText
        let newRawText = result.text

        transcript.sourceMediaRelativePath = payload.sourceMediaRelativePath
        transcript.languageCode = result.detectedLanguageCode ?? requestedLanguage
        transcript.duration = decoded.metadata.duration
        transcript.rawText = newRawText
        if shouldKeepEditorInSync {
            transcript.editedText = newRawText
            if previousEditedText != newRawText {
                transcript.revision += 1
            }
        }
        let stabilized = SpeakerIdentityStabilizer().stabilize(
            aligned,
            against: transcript.segments,
            previousSpeakers: transcript.speakers
        )
        transcript.segments = stabilized.segments
        transcript.speakers = stabilized.speakers
        transcript.updatedAt = .now

        // The durable transcript write is the commit point. Once it succeeds the
        // queue must complete rather than report a cancellation for already-saved content.
        try await transcriptRepository.save(transcript)
        await progress(1, "Complete")
    }

    public func unloadTranscriptionModel() async {
        await whisperRuntime.unloadModel()
        await diarizationRuntime?.unloadModels()
    }

    private func normalizedLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "auto" else { return nil }
        return trimmed
    }
}
