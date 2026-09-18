import InkribeCore
import InkribeExport
import Logging

@MainActor
enum TranscriptExportActions {
    private static let logger = Logger(label: "Inkribe.TranscriptExport")

    static func copy(
        id: TranscriptID,
        source: TranscriptTextSource,
        appState: InkribeAppState
    ) {
        Task { @MainActor in
            do {
                try await TranscriptExportCoordinator.copyTranscript(
                    id: id,
                    source: source,
                    appState: appState
                )
                logger.info(
                    "Transcript copied to clipboard",
                    metadata: ["source": "\(source.rawValue)"]
                )
            } catch {
                logger.error(
                    "Transcript copy failed",
                    metadata: ["error_type": "\(String(reflecting: type(of: error)))"]
                )
                TranscriptExportCoordinator.presentFailure(error, operation: "Copy Failed")
            }
        }
    }

    static func export(
        id: TranscriptID,
        format: TranscriptExportFormat,
        textSource: TranscriptTextSource = .edited,
        appState: InkribeAppState
    ) {
        Task { @MainActor in
            do {
                let didExport = try await TranscriptExportCoordinator.exportTranscript(
                    id: id,
                    format: format,
                    textSource: textSource,
                    appState: appState
                )
                guard didExport else { return }

                logger.info(
                    "Transcript exported",
                    metadata: [
                        "format": "\(format.rawValue)",
                        "source": "\(format.supportsTextSourceSelection ? textSource.rawValue : "segments")"
                    ]
                )
            } catch {
                logger.error(
                    "Transcript export failed",
                    metadata: [
                        "format": "\(format.rawValue)",
                        "error_type": "\(String(reflecting: type(of: error)))"
                    ]
                )
                TranscriptExportCoordinator.presentFailure(error, operation: "Export Failed")
            }
        }
    }
}
