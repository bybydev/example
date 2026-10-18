import Foundation

nonisolated enum ReadAloudContentNormalizer {
    static func normalizeSpokenText(_ raw: String) -> String {
        let normalizedNewlines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let paragraphs = normalizedNewlines
            .components(separatedBy: "\n")
            .map { line in
                line
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

        var output: [String] = []
        var pendingBlank = false

        for paragraph in paragraphs {
            if paragraph.isEmpty {
                pendingBlank = !output.isEmpty
                continue
            }
            if pendingBlank, !output.isEmpty {
                output.append("")
            }
            output.append(paragraph)
            pendingBlank = false
        }

        return output
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitizedTitle(
        _ raw: String?,
        fallback: String
    ) throws -> String {
        let candidate = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = fallback.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let value = candidate.isEmpty ? fallback : candidate
        guard !value.isEmpty else {
            throw ReadAloudImportError.invalidTitle
        }
        return value
    }

    static func makeContent(
        from normalizedItems: [NormalizedImportItem]
    ) throws -> (
        manifest: ProjectContentManifest,
        items: [ProjectContentItem]
    ) {
        try Task.checkCancellation()
        guard !normalizedItems.isEmpty else {
            throw ReadAloudImportError.emptyContent
        }

        let ordered = normalizedItems.sorted { $0.order < $1.order }
        var seenOrders = Set<Int>()
        var seenIDs = Set<UUID>()
        var items: [ProjectContentItem] = []
        var manifestEntries: [ContentManifestItem] = []

        for input in ordered {
            try Task.checkCancellation()
            guard input.order >= 0,
                  seenOrders.insert(input.order).inserted,
                  seenIDs.insert(input.id).inserted else {
                throw ReadAloudImportError.normalizationFailed(
                    "Import produced duplicate or invalid item identity/order."
                )
            }

            let text = normalizeSpokenText(input.normalizedText)
            // Keep a PDF chapter's identity even when defaults exclude all its
            // blocks. Including those blocks later must not create a new item.
            guard !text.isEmpty || input.sourceLocator.kind == .pdf else {
                throw ReadAloudImportError.normalizationFailed(
                    "Import produced an empty normalized content item."
                )
            }

            let item = ProjectContentItem(
                id: input.id,
                title: try sanitizedTitle(
                    input.title,
                    fallback: "Section \(input.order + 1)"
                ),
                order: input.order,
                text: text,
                contentRevision: ProjectContentRevision.item(
                    normalizedText: text
                ),
                sourceLocator: input.sourceLocator
            )
            items.append(item)
            manifestEntries.append(
                ContentManifestItem(
                    id: item.id,
                    order: item.order,
                    relativePath: ProjectPackagePaths.relativeItemPath(item.id),
                    parentID: input.parentID
                )
            )
        }

        guard !items.isEmpty else {
            throw ReadAloudImportError.emptyContent
        }

        try Task.checkCancellation()
        let revision = try ProjectContentRevision.project(
            manifestItems: manifestEntries,
            items: items
        )
        return (
            ProjectContentManifest(
                contentRevision: revision,
                items: manifestEntries
            ),
            items
        )
    }
}
