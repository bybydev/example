import Foundation

public enum TranscriptLibrarySort: String, CaseIterable, Codable, Hashable, Sendable {
    case newest
    case oldest
    case title
}

public enum TranscriptLibraryQuery {
    public static func apply(
        to transcripts: [Transcript],
        searchText: String,
        sort: TranscriptLibrarySort
    ) -> [Transcript] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [Transcript]

        if query.isEmpty {
            filtered = transcripts
        } else {
            filtered = transcripts.filter { transcript in
                transcript.title.localizedCaseInsensitiveContains(query)
                    || transcript.editedText.localizedCaseInsensitiveContains(query)
                    || transcript.rawText.localizedCaseInsensitiveContains(query)
            }
        }

        return filtered.sorted { lhs, rhs in
            switch sort {
            case .newest:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            case .oldest:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            case .title:
                let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            }
        }
    }
}
