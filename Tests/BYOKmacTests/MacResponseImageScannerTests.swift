import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BYOKmac

@Suite("macOS response image scanning")
struct MacResponseImageScannerTests {
  @Test("Detects and extracts remote and data-URI images across markdown and tables while skipping code blocks")
  func scansMarkdownAndTablesSkippingCode() {
    let pngPrefix = Data(repeating: 0xAA, count: 48)
    let firstPayload = (pngPrefix + Data([0x01, 0x02])).base64EncodedString()
    let secondPayload = (pngPrefix + Data([0x03, 0x04])).base64EncodedString()

    let markdown = """
    ```markdown
    ![IgnoredCode](https://example.com/in-code-block.png)
    ```

    Inline code `![IgnoredInline](https://example.com/inline.png)` should not match.

    ![First](data:image/png;base64,\(firstPayload))
    ![Second](data:image/png;base64,\(secondPayload))
    ![DuplicateFirst](data:image/png;base64,\(firstPayload))

    | Item | Preview |
    | --- | --- |
    | Diagram | ![Chart](https://example.com/charts/summary_(v1).png "Summary") |
    | Repeat | ![Chart Again](https://example.com/charts/summary_(v1).png) |
    """

    #expect(MacResponseImageScanner.hasImageCandidates(in: markdown))

    let candidates = MacResponseImageScanner.imageCandidates(in: markdown)
    #expect(candidates.count == 3)
    #expect(candidates[0].label == "First")
    #expect(candidates[1].label == "Second")
    #expect(candidates[0].id != candidates[1].id)
    #expect(candidates[2].label == "Chart")
    if case .url(let url) = candidates[2].source {
      #expect(url.absoluteString == "https://example.com/charts/summary_(v1).png")
    } else {
      Issue.record("Expected third candidate to be a remote URL")
    }
  }

  @Test("Fast presence check ignores non-image text, code blocks, hostless URLs, and malformed data URIs")
  func fastPresenceCheckEdgeCases() {
    #expect(!MacResponseImageScanner.hasImageCandidates(in: ""))
    #expect(!MacResponseImageScanner.hasImageCandidates(in: "Just plain text with [a link](https://example.com)."))
    #expect(
      !MacResponseImageScanner.hasImageCandidates(
        in: """
        ```
        ![InFence](https://example.com/a.png)
        ```
        """
      )
    )
    #expect(!MacResponseImageScanner.hasImageCandidates(in: "Inline `![Code](https://example.com/a.png)`"))
    #expect(!MacResponseImageScanner.hasImageCandidates(in: "![Broken](https://)"))
    #expect(!MacResponseImageScanner.hasImageCandidates(in: "![BadScheme](file:///tmp/image.png)"))
    #expect(!MacResponseImageScanner.hasImageCandidates(in: "![EmptyData](data:image/png;base64,)"))
    #expect(MacResponseImageScanner.hasImageCandidates(in: "![](https://example.com/photo.jpg)"))
    #expect(MacResponseImageScanner.hasImageCandidates(in: "![](data:image/jpeg;base64,/9j/4AAQ)"))
  }

  @Test("Derives sanitized filenames and sniffs image MIME types from payload bytes")
  func filenamesAndMimeSniffing() throws {
    let urlWithExt = try #require(URL(string: "https://example.com/assets/diagram-01.png"))
    #expect(
      MacResponseImageScanner.suggestedFilename(for: .url(urlWithExt), fallbackIndex: 1)
        == "diagram-01.png"
    )

    let urlWithoutExt = try #require(URL(string: "https://example.com/render/preview"))
    #expect(
      MacResponseImageScanner.suggestedFilename(
        for: .url(urlWithoutExt),
        fallbackIndex: 2,
        resolvedMimeType: "image/webp"
      ) == "preview.webp"
    )

    let dataSource = MacResponseImageCandidate.Source.data(Data([0x01]), fileExtension: "png")
    #expect(MacResponseImageScanner.suggestedFilename(for: dataSource, fallbackIndex: 3) == "image-3.png")

    #expect(MacResponseImageScanner.sanitizeFilename("my/weird:file?name.png") == "myweirdfilename.png")

    #expect(
      MacResponseImageScanner.mimeType(
        for: Data([0xFF, 0xD8, 0xFF, 0xE0]),
        filename: "photo.png"
      ) == "image/jpeg"
    )
    #expect(
      MacResponseImageScanner.mimeType(
        for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        filename: "photo.jpg"
      ) == "image/png"
    )
    #expect(
      MacResponseImageScanner.mimeType(
        for: Data("GIF89a".utf8),
        filename: "anim.bin"
      ) == "image/gif"
    )
    #expect(
      MacResponseImageScanner.mimeType(
        for: Data("RIFF0000WEBP".utf8),
        filename: "pic.bin"
      ) == "image/webp"
    )
  }

  @Test("Validates real image bytes via ImageIO and rejects non-image payloads")
  func validatesImageBytes() throws {
    let pngData = try makeSolidPNGData(width: 2, height: 3)
    let dimensions = try #require(MacResponseImageScanner.validateImageData(pngData))
    #expect(dimensions.width == 2)
    #expect(dimensions.height == 3)
    #expect(MacResponseImageScanner.isValidImageData(pngData))

    let htmlBytes = Data("<html><body>404 Not Found</body></html>".utf8)
    #expect(MacResponseImageScanner.validateImageData(htmlBytes) == nil)
    #expect(!MacResponseImageScanner.isValidImageData(htmlBytes))
    #expect(!MacResponseImageScanner.isValidImageData(Data()))
  }

  @Test("Respects maxByteCount when fetching inline data candidates")
  func fetchDataRespectsSizeCap() async {
    let payload = Data(repeating: 0x42, count: 64)
    let source = MacResponseImageCandidate.Source.data(payload, fileExtension: "png")

    let allowed = await MacResponseImageScanner.fetchData(for: source, maxByteCount: 64)
    #expect(allowed == payload)

    let rejected = await MacResponseImageScanner.fetchData(for: source, maxByteCount: 32)
    #expect(rejected == nil)

    let empty = await MacResponseImageScanner.fetchData(
      for: .data(Data(), fileExtension: "png"),
      maxByteCount: 64
    )
    #expect(empty == nil)
  }

  private func makeSolidPNGData(width: Int, height: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw NSError(domain: "MacResponseImageScannerTests", code: 1)
    }
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let cgImage = context.makeImage() else {
      throw NSError(domain: "MacResponseImageScannerTests", code: 2)
    }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      throw NSError(domain: "MacResponseImageScannerTests", code: 3)
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw NSError(domain: "MacResponseImageScannerTests", code: 4)
    }
    return output as Data
  }
}
