import AppKit
import InkribeCore
import InkribeExport
import UniformTypeIdentifiers

@MainActor
enum TranscriptExportCoordinator {
    private static let exporter = TranscriptExporter()

    static func copyTranscript(
        id: TranscriptID,
        source: TranscriptTextSource,
        appState: InkribeAppState
    ) async throws {
        let transcript = try await requireTranscript(id: id, appState: appState)
        let text = exporter.copyText(for: transcript, source: source)

        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            throw TranscriptExportPresentationError.clipboardUnavailable
        }
    }

    @discardableResult
    static func exportTranscript(
        id: TranscriptID,
        format: TranscriptExportFormat,
        textSource: TranscriptTextSource = .edited,
        appState: InkribeAppState
    ) async throws -> Bool {
        let transcript = try await requireTranscript(id: id, appState: appState)
        let document = try exporter.document(
            for: transcript,
            format: format,
            textSource: textSource
        )

        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.prompt = "Export"
        panel.nameFieldStringValue = document.fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [contentType(for: format)]

        guard panel.runModal() == .OK, let destination = panel.url else {
            return false
        }

        try document.utf8Data.write(to: destination, options: .atomic)
        return true
    }

    static func presentFailure(_ error: Error, operation: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = operation
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func requireTranscript(
        id: TranscriptID,
        appState: InkribeAppState
    ) async throws -> Transcript {
        guard let transcript = try await appState.transcript(id: id) else {
            throw TranscriptExportPresentationError.transcriptUnavailable
        }
        return transcript
    }

    private static func contentType(for format: TranscriptExportFormat) -> UTType {
        switch format {
        case .plainText:
            .plainText
        case .markdown:
            UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
        case .srt:
            UTType(filenameExtension: "srt", conformingTo: .plainText) ?? .plainText
        case .vtt:
            UTType(filenameExtension: "vtt", conformingTo: .plainText) ?? .plainText
        }
    }
}

enum TranscriptExportPresentationError: LocalizedError {
    case transcriptUnavailable
    case clipboardUnavailable

    var errorDescription: String? {
        switch self {
        case .transcriptUnavailable:
            "The transcript is no longer available."
        case .clipboardUnavailable:
            "The transcript could not be copied to the clipboard."
        }
    }
}
