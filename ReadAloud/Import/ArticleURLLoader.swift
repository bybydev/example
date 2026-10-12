import Foundation

nonisolated enum ArticleURLError: Error, LocalizedError, Sendable {
    case invalidURL
    case requestFailed(Int)
    case unsupportedContent
    case tooLarge
    case unreadableEncoding
    case unreadableArticle

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a public HTTP or HTTPS article URL."
        case .requestFailed(let status):
            "The website returned HTTP \(status). Check the URL and try again."
        case .unsupportedContent:
            "This link does not contain a supported article or document."
        case .tooLarge:
            "The webpage or document is too large to import."
        case .unreadableEncoding:
            "This article uses an unsupported text encoding."
        case .unreadableArticle:
            "No readable article could be extracted from this page."
        }
    }
}

nonisolated struct ProjectWebProvenance: Sendable {
    let originalURL: URL
    var siteName: String? = nil
    var language: String? = nil
    var publishedTime: String? = nil
}

nonisolated struct ArticleFetchResult: Sendable {
    let finalURL: URL
    let data: Data
    // "html" denotes article extraction. Other extensions use existing file importers.
    let fileExtension: String
}

nonisolated final class ArticleRedirectLimiter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirectCount = 0

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirectCount += 1
        let permitted = redirectCount <= 5
        lock.unlock()
        completionHandler(
            permitted && ArticleURLLoader.isPublicURL(request.url) ? request : nil
        )
    }
}

nonisolated struct ArticleURLLoader: Sendable {
    static let maxHTMLBytes = 5 * 1_024 * 1_024
    static let maxDocumentBytes = 25 * 1_024 * 1_024

    func fetch(
        _ url: URL,
        progress: (@Sendable (ReadAloudImportProgress) -> Void)?
    ) async throws -> ArticleFetchResult {
        guard Self.isPublicURL(url) else { throw ArticleURLError.invalidURL }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 20
        request.setValue(
            "text/html,application/xhtml+xml,application/pdf,application/epub+zip,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )

        let (bytes, response) = try await withTaskCancellationHandler {
            try await session.bytes(for: request, delegate: ArticleRedirectLimiter())
        } onCancel: {
            session.invalidateAndCancel()
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw ArticleURLError.requestFailed(
                (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        guard Self.isPublicURL(http.url) else { throw ArticleURLError.invalidURL }

        let mime = (http.mimeType ?? "").lowercased()
        guard let ext = Self.fileExtension(mimeType: mime, url: http.url) else {
            throw ArticleURLError.unsupportedContent
        }
        let limit = ext == "html" ? Self.maxHTMLBytes : Self.maxDocumentBytes
        guard response.expectedContentLength <= Int64(limit) else {
            throw ArticleURLError.tooLarge
        }

        progress?(ReadAloudImportProgress(
            stage: .extracting, detail: http.url?.host ?? "Downloading"
        ))
        var data = Data()
        data.reserveCapacity(min(512 * 1_024, limit))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw ArticleURLError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard !data.isEmpty else { throw ReadAloudImportError.emptyContent }

        // Do not forward an error page or mislabeled archive to a file parser.
        if ext == "pdf" && !data.starts(with: Data("%PDF".utf8)) {
            throw ArticleURLError.unsupportedContent
        }
        if ["epub", "docx", "odt", "pptx"].contains(ext)
            && !data.starts(with: [0x50, 0x4b]) {
            throw ArticleURLError.unsupportedContent
        }
        return ArticleFetchResult(
            finalURL: http.url ?? url,
            data: data,
            fileExtension: ext
        )
    }

    static func isPublicURL(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.user == nil, url.password == nil,
              let hostname = url.host?.lowercased(), !hostname.isEmpty,
              hostname != "localhost", !hostname.hasSuffix(".localhost"),
              !hostname.hasSuffix(".local"), !hostname.hasSuffix(".internal")
        else { return false }

        if hostname == "::1" || hostname.hasPrefix("fe80:") ||
            hostname.hasPrefix("fc") || hostname.hasPrefix("fd") {
            return false
        }
        let parts = hostname.split(separator: ".")
        if parts.count == 4 {
            let octets = parts.compactMap { UInt8($0) }
            if octets.count == 4 {
                let first = octets[0], second = octets[1]
                if first == 0 || first == 10 || first == 127 || first >= 224 ||
                    (first == 169 && second == 254) ||
                    (first == 172 && (16...31).contains(second)) ||
                    (first == 192 && second == 168) ||
                    (first == 100 && (64...127).contains(second)) {
                    return false
                }
            }
        }
        return true
    }

    private static func fileExtension(mimeType: String, url: URL?) -> String? {
        let pathExt = url?.pathExtension.lowercased() ?? ""
        let knownDocuments: Set<String> = [
            "epub", "pdf", "txt", "text", "md", "markdown",
            "rtf", "srt", "vtt", "docx", "odt", "pptx"
        ]
        switch mimeType {
        case "text/html", "application/xhtml+xml":
            return "html"
        case "application/pdf":
            return "pdf"
        case "application/epub+zip":
            return "epub"
        case "text/plain":
            return knownDocuments.contains(pathExt) ? pathExt : "txt"
        case "text/markdown", "text/x-markdown":
            return "md"
        case "application/rtf", "text/rtf":
            return "rtf"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            return "docx"
        case "application/vnd.oasis.opendocument.text":
            return "odt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
            return "pptx"
        case "application/octet-stream", "application/zip", "":
            return knownDocuments.contains(pathExt) ? pathExt : nil
        default:
            return nil
        }
    }
}
