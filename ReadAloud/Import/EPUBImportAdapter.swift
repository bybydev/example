import EpubKit
import Foundation

nonisolated struct EPUBImportAdapter: ReadAloudDocumentImporting {
    func importDocument(
        from url: URL,
        progress: (@Sendable (ReadAloudImportProgress) -> Void)?
    ) async throws -> NormalizedImportDocument {
        let parser = EPUBParser()
        let document = try await parser.parseAsync(
            fileURL: url,
            options: .default,
            priority: .userInitiated
        ) { value in
            progress?(
                ReadAloudImportProgress(
                    stage: .extracting,
                    fractionCompleted: value.fractionCompleted,
                    detail: value.currentPath
                )
            )
        }

        progress?(
            ReadAloudImportProgress(
                stage: .normalizing,
                fractionCompleted: 0
            )
        )

        let sections = document.readableSections.sorted {
            $0.order < $1.order
        }
        var itemIDByPath: [String: UUID] = [:]
        var itemIDs: [UUID] = []
        itemIDs.reserveCapacity(sections.count)
        for section in sections {
            let id = UUID()
            itemIDs.append(id)
            itemIDByPath[canonicalEPUBPath(section.sourcePath), default: id] = id
        }
        let parentPathByPath = tocParentPaths(document.tableOfContents)

        let items = try sections.enumerated().map { index, section in
            let text = ReadAloudContentNormalizer.normalizeSpokenText(
                section.text
            )
            guard !text.isEmpty else {
                throw ReadAloudImportError.normalizationFailed(
                    "EPUB section became empty after normalization: \(section.sourcePath)"
                )
            }

            let itemID = itemIDs[index]
            let parentID = parentPathByPath[canonicalEPUBPath(section.sourcePath)]
                .flatMap { itemIDByPath[$0] }
                .flatMap { $0 == itemID ? nil : $0 }

            return NormalizedImportItem(
                id: itemID,
                title: try ReadAloudContentNormalizer.sanitizedTitle(
                    section.title,
                    fallback: "Chapter \(index + 1)"
                ),
                order: index,
                normalizedText: text,
                sourceLocator: ProjectSourceLocator(
                    kind: .epub,
                    value: section.sourcePath
                ),
                parentID: parentID
            )
        }

        let artwork = document.cover.map {
            NormalizedImportArtwork(
                data: $0.data,
                fileExtension: Self.coverExtension(
                    mediaType: $0.mediaType,
                    href: $0.href
                )
            )
        }

        let diagnostics = document.diagnostics.map {
            ReadAloudImportDiagnostic(
                severity: $0.severity == .info ? .info : .warning,
                code: "epub.\($0.severity.rawValue)",
                message: $0.message,
                sourceLocator: $0.path
            )
        }

        return NormalizedImportDocument(
            kind: .epub,
            title: try ReadAloudContentNormalizer.sanitizedTitle(
                document.metadata.title,
                fallback: url.deletingPathExtension().lastPathComponent
            ),
            author: nonempty(
                document.metadata.creators.joined(separator: ", ")
            ),
            items: items,
            artwork: artwork,
            diagnostics: diagnostics
        )
    }

    private func tocParentPaths(
        _ roots: [EPUBTOCItem]
    ) -> [String: String] {
        var result: [String: String] = [:]

        func visit(
            _ items: [EPUBTOCItem],
            parentPath: String?
        ) {
            for item in items {
                let ownPath = item.href.map(canonicalEPUBPath)
                if let ownPath, let parentPath {
                    result[ownPath] = parentPath
                }
                visit(
                    item.children,
                    parentPath: ownPath ?? parentPath
                )
            }
        }

        visit(roots, parentPath: nil)
        return result
    }

    private func canonicalEPUBPath(_ raw: String) -> String {
        raw.components(separatedBy: "#").first ?? raw
    }

    private func nonempty(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func coverExtension(
        mediaType: String,
        href: String
    ) -> String {
        switch mediaType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        default:
            let ext = URL(fileURLWithPath: href).pathExtension.lowercased()
            return ext.isEmpty ? "img" : ext
        }
    }
}

