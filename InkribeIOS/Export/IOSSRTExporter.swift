import CoreMedia
import Foundation
import JobQueue

enum IOSSRTExporter {
    /// Stream UTF-8 cues instead of collecting another complete transcript.
    /// Edits and genuine project intervals are exported, never raw recognition.
    static func write(_ snapshot: IOSCaptionSnapshot, to url: URL, progress: JobProgressReporter) async throws {
        let cues = snapshot.cues.sorted {
            $0.interval.start == $1.interval.start ? $0.id.uuidString < $1.id.uuidString : $0.interval.start < $1.interval.start
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw IOSExportError.encoding }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var number = 0
        for (index, cue) in cues.enumerated() {
            try Task.checkCancellation()
            let text = snapshot.text(for: cue).components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
            if !text.isEmpty {
                number += 1
                // Outward millisecond rounding preserves sub-millisecond cues.
                let start = CMTimeConvertScale(cue.interval.start.cmTime, timescale: 1_000, method: .roundTowardZero)
                let end = CMTimeConvertScale(cue.interval.end.cmTime, timescale: 1_000, method: .roundAwayFromZero)
                guard start.isNumeric, end.isNumeric, start.value >= 0, end.value > start.value else { throw IOSExportError.invalidRequest }
                let block = "\(number)\n\(stamp(start.value)) --> \(stamp(end.value))\n\(text)\n\n"
                try handle.write(contentsOf: Data(block.utf8))
            }
            if index % 25 == 0 {
                await progress.report(fractionCompleted: Double(index + 1) / Double(max(1, cues.count)) * 0.95,
                                      message: "Writing edited subtitles…")
            }
        }
        guard number > 0 else { throw IOSExportError.noCaptions }
        try handle.synchronize()
    }

    private static func stamp(_ milliseconds: Int64) -> String {
        String(format: "%02lld:%02lld:%02lld,%03lld", milliseconds / 3_600_000,
               (milliseconds / 60_000) % 60, (milliseconds / 1_000) % 60, milliseconds % 1_000)
    }
}
