import Foundation
import TextExtractorWeb

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
        progress?(ReadAloudImportProgress(
            stage: .extracting, detail: "Finding the article"
        ))
        // Runs in the existing detached import worker. TextExtractorWeb owns
        // decoding, article selection and ordered semantic-block extraction.
        let article: WebArticleResult
        do {
            article = try WebArticleExtractor().extract(
                html: data,
                sourceURL: finalURL,
                options: WebArticleExtractionOptions(
                    maxInputBytes: ArticleURLLoader.maxHTMLBytes
                )
            )
        } catch let error as WebArticleExtractionError {
            switch error {
            case .invalidSourceURL:
                throw ArticleURLError.invalidURL
            case .unreadableEncoding:
                throw ArticleURLError.unreadableEncoding
            case .unreadableArticle:
                throw ArticleURLError.unreadableArticle
            case .inputTooLarge, .tooManyBlocks, .tooManyDOMElements, .domTooDeep:
                throw ArticleURLError.tooLarge
            }
        }
        try Task.checkCancellation()

        progress?(ReadAloudImportProgress(
            stage: .normalizing, detail: "Preserving paragraphs"
        ))
        // `text` is the package's projection of its canonical typed blocks.
        // Keep ReadAloud's existing one-item storage and speech normalization.
        let normalizedText = ReadAloudContentNormalizer.normalizeSpokenText(article.text)
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
            author: nonempty(article.metadata["author"]),
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
            siteName: nonempty(article.metadata["siteName"]),
            language: nonempty(article.metadata["language"]),
            publishedTime: nonempty(article.metadata["publishedTime"])
        )
    }

    private func nonempty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

