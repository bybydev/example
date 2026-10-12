import Foundation
import SwiftReadability
import SwiftSoup

nonisolated struct WebArticleExtracted: Sendable {
    let document: NormalizedImportDocument
    let siteName: String?
    let language: String?
    let publishedTime: String?
}

nonisolated struct WebArticleImportAdapter: Sendable {
    func importDocument(
        data: Data,
        finalURL: URL,
        progress: (@Sendable (ReadAloudImportProgress) -> Void)?
    ) throws -> WebArticleExtracted {
        try Task.checkCancellation()
        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252) else {
            throw ArticleURLError.unreadableEncoding
        }
        progress?(ReadAloudImportProgress(
            stage: .extracting, detail: "Finding the article"
        ))
        // Construct and use Readability only within the detached import worker.
        let article = try Readability(html: html, url: finalURL).parse()
        try Task.checkCancellation()
        guard let article else { throw ArticleURLError.unreadableArticle }

        progress?(ReadAloudImportProgress(
            stage: .normalizing, detail: "Preserving paragraphs"
        ))
        let text = try spokenText(from: article.contentHTML)
        let normalizedText = ReadAloudContentNormalizer.normalizeSpokenText(text)
        guard normalizedText.count >= 40 else {
            throw ArticleURLError.unreadableArticle
        }
        try Task.checkCancellation()

        let title = try ReadAloudContentNormalizer.sanitizedTitle(
            article.title, fallback: finalURL.host ?? "Web Article"
        )
        let document = NormalizedImportDocument(
            kind: .article,
            title: title,
            author: nonempty(article.byline),
            items: [
                NormalizedImportItem(
                    title: title,
                    order: 0,
                    normalizedText: normalizedText,
                    sourceLocator: ProjectSourceLocator(
                        kind: .article,
                        value: finalURL.absoluteString
                    )
                )
            ],
            artwork: nil,
            diagnostics: []
        )
        return WebArticleExtracted(
            document: document,
            siteName: nonempty(article.siteName),
            language: nonempty(article.lang),
            publishedTime: nonempty(article.publishedTime)
        )
    }

    // DOM textContent may concatenate adjacent paragraphs. Retain structural
    // breaks from clean article HTML instead, without executing embedded content.
    private func spokenText(from cleanedHTML: String) throws -> String {
        let document = try SwiftSoup.parseBodyFragment(cleanedHTML)
        let selectors = "h1, h2, h3, h4, h5, h6, p, li, blockquote, pre, figcaption, dt, dd, tr"
        let blockTags: Set<String> = [
            "h1", "h2", "h3", "h4", "h5", "h6",
            "p", "li", "blockquote", "pre", "figcaption", "dt", "dd", "tr"
        ]
        var blocks: [String] = []
        for element in try document.select(selectors) {
            try Task.checkCancellation()
            // Avoid duplicate text from nested blocks such as p inside li.
            var ancestor = element.parent()
            var nested = false
            while let parent = ancestor {
                if blockTags.contains(parent.tagName().lowercased()) {
                    nested = true
                    break
                }
                ancestor = parent.parent()
            }
            guard !nested else { continue }
            let line = try element.text()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { blocks.append(line) }
        }
        if blocks.isEmpty {
            let fallback = try document.text()
            if !fallback.isEmpty { blocks.append(fallback) }
        }
        return blocks.joined(separator: "\n\n")
    }

    private func nonempty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
