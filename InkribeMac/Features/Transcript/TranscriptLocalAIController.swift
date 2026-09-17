import Foundation
import InkribeAI
import InkribeCore
import Logging
import Observation

@MainActor
@Observable
final class TranscriptLocalAIController {
    typealias ServiceFactory = () throws -> any TranscriptAIProcessing
    typealias KeepModelLoadedProvider = @MainActor () -> Bool

    static let shared = TranscriptLocalAIController()

    private(set) var isGenerating = false
    private(set) var progress: TranscriptAIProgress?
    private(set) var errorDescription: String?

    @ObservationIgnored private var service: (any TranscriptAIProcessing)?
    @ObservationIgnored private let serviceFactory: ServiceFactory
    @ObservationIgnored private let keepModelLoadedProvider: KeepModelLoadedProvider
    @ObservationIgnored private let logger = Logger(label: "Inkribe.LocalAI")

    init(
        serviceFactory: @escaping ServiceFactory = {
            try TranscriptAIService.bundled()
        },
        keepModelLoadedProvider: @escaping KeepModelLoadedProvider = {
            InkribePreferences.shared.keepAIModelLoaded
        }
    ) {
        self.serviceFactory = serviceFactory
        self.keepModelLoadedProvider = keepModelLoadedProvider
    }

    func generate(
        action: TranscriptAIAction,
        transcript: Transcript
    ) async throws -> TranscriptAIResult {
        guard !isGenerating else { throw ControllerError.alreadyGenerating }

        let service = try resolveService()
        isGenerating = true
        progress = TranscriptAIProgress(phase: .preparing, fraction: 0)
        errorDescription = nil
        let startedAt = Date()

        logger.info(
            "Local transcript AI started",
            metadata: [
                "action": "\(action.rawValue)",
                "transcript_id": "\(transcript.id.rawValue.uuidString)",
                "source_revision": "\(transcript.revision)"
            ]
        )

        defer {
            isGenerating = false
        }

        do {
            let result = try await service.generate(
                action: action,
                transcript: transcript,
                progress: { [weak self] value in
                    await MainActor.run {
                        self?.progress = value
                    }
                }
            )
            progress = TranscriptAIProgress(phase: .finishing, fraction: 1)
            logger.info(
                "Local transcript AI finished",
                metadata: [
                    "action": "\(action.rawValue)",
                    "transcript_id": "\(transcript.id.rawValue.uuidString)",
                    "source_revision": "\(transcript.revision)",
                    "duration_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
                ]
            )
            await releaseServiceIfConfigured(service)
            return result
        } catch is CancellationError {
            progress = nil
            logger.info(
                "Local transcript AI cancelled",
                metadata: [
                    "action": "\(action.rawValue)",
                    "transcript_id": "\(transcript.id.rawValue.uuidString)"
                ]
            )
            await releaseServiceIfConfigured(service)
            throw CancellationError()
        } catch {
            progress = nil
            errorDescription = error.localizedDescription
            logger.error(
                "Local transcript AI failed",
                metadata: [
                    "action": "\(action.rawValue)",
                    "transcript_id": "\(transcript.id.rawValue.uuidString)",
                    "error_type": "\(String(reflecting: type(of: error)))"
                ]
            )
            await releaseServiceIfConfigured(service)
            throw error
        }
    }

    func clearError() {
        errorDescription = nil
    }

    func unloadModel() async {
        guard !isGenerating, let service else { return }
        await service.unloadModel()
        self.service = nil
        progress = nil
    }

    private func resolveService() throws -> any TranscriptAIProcessing {
        if let service { return service }
        let created = try serviceFactory()
        service = created
        return created
    }

    private func releaseServiceIfConfigured(
        _ activeService: any TranscriptAIProcessing
    ) async {
        guard !keepModelLoadedProvider() else { return }
        await activeService.unloadModel()
        service = nil
        logger.debug("Local AI model released after action")
    }

    enum ControllerError: LocalizedError {
        case alreadyGenerating

        var errorDescription: String? {
            switch self {
            case .alreadyGenerating:
                "Another local AI action is already running."
            }
        }
    }
}
