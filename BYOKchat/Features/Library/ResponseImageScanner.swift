import Foundation

/// One savable image found inside an assistant reply.
struct ResponseImageCandidate: Identifiable, Equatable {
  enum Source: Equatable {
    case url(URL)
    case data(Data, fileExtension: String)
  }

  let id: String
  let label: String
  let source: Source
}

enum ResponseImageScanner {
  private static let markdownImagePattern =
    #"!\[([^\]]*)\]\(([^)\s]+)[^)]*\)"#

  /// Finds markdown image references and inline data-URI images. Results are
  /// de-duplicated by location so the same image linked twice offers once.
  static func imageCandidates(in content: String) -> [ResponseImageCandidate] {
    guard !content.isEmpty else { return [] }

    var candidates: [ResponseImageCandidate] = []
    var seen = Set<String>()

    if let regex = try? NSRegularExpression(pattern: markdownImagePattern) {
      let range = NSRange(content.startIndex..., in: content)
      for match in regex.matches(in: content, range: range) {
        guard
          let altRange = Range(match.range(at: 1), in: content),
          let urlRange = Range(match.range(at: 2), in: content)
        else { continue }
        let alt = String(content[altRange])
        let rawURL = String(content[urlRange])

        guard seen.insert(rawURL).inserted else { continue }

        if let url = URL(string: rawURL),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
        {
          let derived = sanitizeFilename(url.lastPathComponent)
          candidates.append(
            ResponseImageCandidate(
              id: rawURL,
              label: alt.isEmpty ? (derived.isEmpty ? "image" : derived) : alt,
              source: .url(url)
            )
          )
        } else if let decoded = decodeDataURI(rawURL) {
          seen.insert(rawURL)
          candidates.append(
            ResponseImageCandidate(
              id: "data::\(rawURL.prefix(64))",
              label: alt.isEmpty ? "image-\(candidates.count + 1).\(decoded.extension)" : alt,
              source: .data(decoded.data, fileExtension: decoded.extension)
            )
          )
        }
      }
    }
    return candidates
  }

  /// Fetches bytes for a remote candidate. Returns nil on failure or when the
  /// payload exceeds the library size cap.
  static func fetchData(
    for source: ResponseImageCandidate.Source,
    session: URLSession = .shared,
    maxByteCount: Int
  ) async -> Data? {
    switch source {
    case .data(let data, _):
      return data.count <= maxByteCount ? data : nil
    case .url(let url):
      var request = URLRequest(url: url)
      request.timeoutInterval = 15
      guard let (data, response) = try? await session.data(for: request),
        let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode),
        data.count <= maxByteCount
      else { return nil }
      return data
    }
  }

  static func suggestedFilename(
    for source: ResponseImageCandidate.Source,
    fallbackIndex: Int
  ) -> String {
    switch source {
    case .url(let url):
      let name = sanitizeFilename(url.lastPathComponent)
      if !name.isEmpty, name.contains(".") { return name }
      return name.isEmpty ? "image-\(fallbackIndex).jpg" : "\(name).jpg"
    case .data(_, let fileExtension):
      return "image-\(fallbackIndex).\(fileExtension)"
    }
  }

  static func sanitizeFilename(_ name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
    let cleaned = name.components(separatedBy: allowed.inverted).joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(cleaned.prefix(80))
  }

  private static func decodeDataURI(_ value: String) -> (data: Data, extension: String)? {
    guard value.lowercased().hasPrefix("data:image/") else { return nil }
    guard let semicolon = value.firstIndex(of: ";") else { return nil }
    let mimeType = String(value[value.index(value.startIndex, offsetBy: 5)..<semicolon])
    let payload = String(value[value.index(after: semicolon)...])
    guard payload.lowercased().hasPrefix("base64,") else { return nil }
    let encoded = String(payload.dropFirst("base64,".count))
    guard let data = Data(base64Encoded: encoded), !data.isEmpty else { return nil }
    let subtype = mimeType.split(separator: "/").last.map(String.init) ?? "jpg"
    let fileExtension = subtype == "jpeg" ? "jpg" : subtype
    return (data, fileExtension)
  }
}
