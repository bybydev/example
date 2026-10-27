import CoreMedia
import Foundation

/// User-authored phrases are project data, never native recognition or quota work.
/// The interval uses the original project clock; trim only changes its output view.
struct ManualCaption: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let clipID: UUID
    var text: String
    var interval: MediaInterval

    func validate(clips: [ProjectClip]) throws {
        guard let clip = clips.first(where: { $0.id == clipID }),
              text.count <= 4_096,
              interval.start >= clip.timelineInterval.start,
              interval.end <= clip.timelineInterval.end else { throw ManualCaptionError.invalidCaption }
    }

    static func overlaps(_ a: MediaInterval, _ b: MediaInterval) -> Bool {
        a.start < b.end && b.start < a.end
    }
}

enum ManualCaptionError: LocalizedError {
    case invalidCaption, emptyText, overlap, limit
    var errorDescription: String? {
        switch self {
        case .invalidCaption: "Use start and end times inside one clip, with the end after the start, and keep text within 4,096 characters."
        case .emptyText: "Enter the caption text."
        case .overlap: "This range overlaps another manual caption. Adjust its timing or edit that caption instead."
        case .limit: "This project has reached the limit of 10,000 manual captions."
        }
    }
}

/// A sorted interval index keeps conflict resolution bounded during snapshot creation.
struct ManualCaptionIndex: Sendable {
    let captions: [ManualCaption]
    private let prefixEnd: [MediaTime]
    init(_ captions: [ManualCaption]) {
        self.captions = captions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.interval.start < $1.interval.start }
        var end = MediaTime.zero
        prefixEnd = self.captions.map { end = max(end, $0.interval.end); return end }
    }
    func overlapping(_ interval: MediaInterval) -> [ManualCaption] {
        var low = 0, high = captions.count
        while low < high {
            let middle = (low + high) / 2
            if captions[middle].interval.start < interval.end { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        var result: [ManualCaption] = []
        while index >= 0, prefixEnd[index] > interval.start {
            if Self.overlaps(captions[index].interval, interval) { result.append(captions[index]) }
            index -= 1
        }
        return result
    }
    private static func overlaps(_ a: MediaInterval, _ b: MediaInterval) -> Bool { ManualCaption.overlaps(a, b) }
}

struct ManualCaptionConflict: Sendable, Identifiable {
    let cue: CaptionCue
    let text: String
    let manuals: [ManualCaption]
    var id: UUID { cue.id }
}

/// A small compare-and-apply undo payload; speech publications are left untouched.
struct ManualCaptionPatch: Sendable {
    let id: UUID
    let before: ManualCaption?
    let after: ManualCaption?

    func applying(to project: ProjectDocument, forward: Bool) throws -> ProjectDocument {
        var copy = project
        var captions = copy.manualCaptions ?? []
        guard captions.first(where: { $0.id == id }) == (forward ? before : after) else {
            throw CaptionEditError.missingCaption
        }
        captions.removeAll { $0.id == id }
        if let value = forward ? after : before { captions.append(value) }
        captions.sort {
            $0.interval.start == $1.interval.start ? $0.id.uuidString < $1.id.uuidString : $0.interval.start < $1.interval.start
        }
        copy.manualCaptions = captions.isEmpty ? nil : captions
        return copy
    }
    var estimatedBytes: Int { 512 + (before?.text.utf8.count ?? 0) + (after?.text.utf8.count ?? 0) }
}
