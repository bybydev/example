import Foundation
import InkribeCore

public struct TranscriptExportDocument: Equatable, Sendable {
    public let format: TranscriptExportFormat
    public let fileName: String
    public let content: String

    public init(format: TranscriptExportFormat, fileName: String, content: String) {
        self.format = format
        self.fileName = fileName
        self.content = content
    }

    public var utf8Data: Data {
        Data(content.utf8)
    }
}

public struct TranscriptExporter: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    public func document(
        for transcript: Transcript,
        format: TranscriptExportFormat,
        textSource: TranscriptTextSource = .edited
    ) throws -> TranscriptExportDocument {
        let content: String
        switch format {
        case .plainText:
            content = text(for: transcript, source: textSource)
        case .markdown:
            content = markdown(for: transcript, source: textSource)
        case .srt:
            content = try subtitleContent(for: transcript, format: .srt)
        case .vtt:
            content = try subtitleContent(for: transcript, format: .vtt)
        }

        return TranscriptExportDocument(
            format: format,
            fileName: fileName(for: transcript, format: format),
            content: content
        )
    }

    public func copyText(
        for transcript: Transcript,
        source: TranscriptTextSource = .edited
    ) -> String {
        text(for: transcript, source: source)
    }

    public func fileName(
        for transcript: Transcript,
        format: TranscriptExportFormat
    ) -> String {
        let base = sanitizedFileStem(transcript.title)
        return "\(base) - \(dateString(transcript.createdAt)).\(format.fileExtension)"
    }

    private func text(
        for transcript: Transcript,
        source: TranscriptTextSource
    ) -> String {
        switch source {
        case .edited:
            transcript.editedText
        case .raw:
            transcript.rawText
        }
    }

    private func markdown(
        for transcript: Transcript,
        source: TranscriptTextSource
    ) -> String {
        let title = transcript.title
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text(for: transcript, source: source)
        guard !title.isEmpty else { return body }
        guard !body.isEmpty else { return "# \(title)\n" }
        return "# \(title)\n\n\(body)\n"
    }

    private func subtitleContent(
        for transcript: Transcript,
        format: TranscriptExportFormat
    ) throws -> String {
        guard !transcript.segments.isEmpty else {
            throw TranscriptExportError.noTimestampedSegments
        }

        let cues = subtitleCues(from: transcript)
        guard !cues.isEmpty else {
            throw TranscriptExportError.noTimestampedSegments
        }

        switch format {
        case .srt:
            return cues.enumerated().map { index, cue in
                """
                \(index + 1)
                \(formatSRTTimestamp(cue.startMilliseconds)) --> \(formatSRTTimestamp(cue.endMilliseconds))
                \(cue.text)
                """
            }.joined(separator: "\n\n") + "\n"

        case .vtt:
            let body = cues.map { cue in
                """
                \(formatVTTTimestamp(cue.startMilliseconds)) --> \(formatVTTTimestamp(cue.endMilliseconds))
                \(cue.text)
                """
            }.joined(separator: "\n\n")
            return "WEBVTT\n\n\(body)\n"

        case .plainText, .markdown:
            return ""
        }
    }

    private func subtitleCues(from transcript: Transcript) -> [SubtitleCue] {
        let ordered = transcript.segments.enumerated().sorted { lhs, rhs in
            let lhsStart = normalizedSeconds(lhs.element.startTime)
            let rhsStart = normalizedSeconds(rhs.element.startTime)
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return lhs.offset < rhs.offset
        }

        var cues: [SubtitleCue] = []
        cues.reserveCapacity(ordered.count)

        for (_, segment) in ordered {
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let text: String
            if let speakerID = segment.speakerID {
                text = "\(transcript.speakerName(for: speakerID)): \(body)"
            } else {
                text = body
            }

            let start = milliseconds(from: normalizedSeconds(segment.startTime))
            let requestedEnd = milliseconds(from: normalizedSeconds(segment.endTime))
            let end = max(start + 1, requestedEnd)

            cues.append(
                SubtitleCue(
                    startMilliseconds: start,
                    endMilliseconds: end,
                    text: text
                )
            )
        }

        return cues
    }

    private func normalizedSeconds(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        let upperBound = Double((Int.max - 1_000) / 1_000)
        return min(max(0, value), upperBound)
    }

    private func milliseconds(from seconds: TimeInterval) -> Int {
        Int((seconds * 1_000).rounded())
    }

    private func formatSRTTimestamp(_ milliseconds: Int) -> String {
        formatTimestamp(milliseconds, decimalSeparator: ",")
    }

    private func formatVTTTimestamp(_ milliseconds: Int) -> String {
        formatTimestamp(milliseconds, decimalSeparator: ".")
    }

    private func formatTimestamp(_ milliseconds: Int, decimalSeparator: Character) -> String {
        let total = max(0, milliseconds)
        let hours = total / 3_600_000
        let minutes = (total % 3_600_000) / 60_000
        let seconds = (total % 60_000) / 1_000
        let millis = total % 1_000
        return String(
            format: "%02d:%02d:%02d%@%03d",
            locale: Locale(identifier: "en_US_POSIX"),
            hours,
            minutes,
            seconds,
            String(decimalSeparator),
            millis
        )
    }

    private func sanitizedFileStem(_ title: String) -> String {
        var forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        forbidden.formUnion(.controlCharacters)

        let mapped = title.unicodeScalars.map { scalar -> Character in
            forbidden.contains(scalar) ? " " : Character(String(scalar))
        }
        let collapsed = String(mapped)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return collapsed.isEmpty ? "Transcript" : String(collapsed.prefix(120))
    }

    private func dateString(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }
}

public enum TranscriptExportError: Error, Equatable, Sendable {
    case noTimestampedSegments
}

extension TranscriptExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noTimestampedSegments:
            "This transcript has no timestamped segments to export as subtitles."
        }
    }
}

private struct SubtitleCue {
    let startMilliseconds: Int
    let endMilliseconds: Int
    let text: String
}
