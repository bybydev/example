import Foundation

nonisolated enum ReadAloudDisplay {
    static func byteCount(
        _ bytes: Int64
    ) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }

    static func sourceType(
        _ type: ProjectSourceType
    ) -> String {
        switch type {
        case .epub:
            "EPUB"
        case .pdf:
            "PDF"
        case .document:
            "Document"
        case .paste:
            "Text"
        }
    }
}
