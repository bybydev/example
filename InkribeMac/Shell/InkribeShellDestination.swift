import InkribeCore

/// Sidebar destinations are intentionally separate from the main detail route.
/// A transcript opens in the main column without becoming a second sidebar item.
enum InkribeShellDestination: String, CaseIterable, Identifiable {
    case library
    case record
    case `import`

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .record: "Record"
        case .import: "Import"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "books.vertical"
        case .record: "record.circle"
        case .import: "square.and.arrow.down"
        }
    }
}

enum InkribeShellRoute: Equatable {
    case library
    case record
    case `import`
    case transcript(TranscriptID)

    var sidebarDestination: InkribeShellDestination? {
        switch self {
        case .library: .library
        case .record: .record
        case .import: .import
        case .transcript: nil
        }
    }

    var title: String {
        switch self {
        case .library: "Library"
        case .record: "Record"
        case .import: "Import"
        case .transcript: "Transcript"
        }
    }
}
