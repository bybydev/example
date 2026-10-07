import Foundation

nonisolated struct PasteImportAdapter {
    func importDocument(
        text: String,
        suggestedTitle: String?
    ) throws -> NormalizedImportDocument {
        let normalized = ReadAloudContentNormalizer.normalizeSpokenText(text)
        guard !normalized.isEmpty else {
            throw ReadAloudImportError.emptyContent
        }

        return NormalizedImportDocument(
            kind: .paste,
            title: try ReadAloudContentNormalizer.sanitizedTitle(
                suggestedTitle,
                fallback: defaultTitle(for: normalized)
            ),
            author: nil,
            items: [
                NormalizedImportItem(
                    title: "Text",
                    order: 0,
                    normalizedText: normalized,
                    sourceLocator: ProjectSourceLocator(
                        kind: .paste,
                        value: "block:0"
                    )
                )
            ],
            artwork: nil,
            diagnostics: []
        )
    }

    private func defaultTitle(for text: String) -> String {
        let firstLine = text
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        guard !firstLine.isEmpty else { return "Pasted Text" }
        guard firstLine.count > 60 else { return firstLine }
        return String(firstLine.prefix(60)) + "…"
    }
}
