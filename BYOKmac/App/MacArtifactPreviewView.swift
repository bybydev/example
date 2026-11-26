import AppKit
import SwiftUI
import WebKit

enum MacArtifactPreviewSupport {
  enum Kind: Equatable, Sendable {
    case html
    case svg
  }

  static func kind(for language: String?, content: String) -> Kind? {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else { return nil }
    let normalized = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    switch normalized {
    case "html", "htm":
      return .html
    case "svg":
      return .svg
    case "xml":
      return trimmedContent.localizedCaseInsensitiveContains("<svg") ? .svg : nil
    default:
      return nil
    }
  }

  /// Wraps HTML or SVG source with a strict Content Security Policy that blocks
  /// all network requests, external scripts, external images, and frames.
  static func sandboxedDocument(
    for content: String,
    kind: Kind,
    isDark: Bool
  ) -> String {
    let csp =
      #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:;">"#
    let colorSchemeMeta = #"<meta name="color-scheme" content="\#(isDark ? "dark" : "light")">"#
    let injectedHead = "\(csp)\n\(colorSchemeMeta)"

    switch kind {
    case .svg:
      return """
      <!doctype html>
      <html>
      <head>
      <meta charset="utf-8">
      \(injectedHead)
      <style>
        html, body {
          margin: 0;
          padding: 12px;
          box-sizing: border-box;
          width: 100%;
          min-height: 100%;
          display: flex;
          align-items: center;
          justify-content: center;
          background: transparent;
          font-family: -apple-system, BlinkMacSystemFont, sans-serif;
        }
        svg {
          max-width: 100%;
          height: auto;
        }
      </style>
      </head>
      <body>
      \(content)
      </body>
      </html>
      """

    case .html:
      if let headRange = content.range(of: "<head>", options: .caseInsensitive) {
        var result = content
        result.insert(contentsOf: "\n\(injectedHead)\n", at: headRange.upperBound)
        return result
      }
      if let htmlRange = content.range(of: "<html", options: .caseInsensitive),
        let closeAngle = content.range(of: ">", range: htmlRange.upperBound..<content.endIndex)
      {
        var result = content
        result.insert(contentsOf: "\n<head>\(injectedHead)</head>\n", at: closeAngle.upperBound)
        return result
      }
      return """
      <!doctype html>
      <html>
      <head>
      <meta charset="utf-8">
      \(injectedHead)
      <style>
        html, body {
          margin: 0;
          padding: 14px;
          box-sizing: border-box;
          font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          color: \(isDark ? "#e6e6e6" : "#1d1d1f");
          background: transparent;
        }
      </style>
      </head>
      <body>
      \(content)
      </body>
      </html>
      """
    }
  }
}

@MainActor
struct MacSandboxedArtifactWebView: NSViewRepresentable {
  let content: String
  let kind: MacArtifactPreviewSupport.Kind
  var isInline: Bool = true

  @Environment(\.colorScheme) private var colorScheme

  fileprivate struct LoadKey: Equatable {
    let content: String
    let kind: MacArtifactPreviewSupport.Kind
    let isDark: Bool
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> MacPassthroughArtifactWKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.defaultWebpagePreferences.allowsContentJavaScript = (kind == .html)

    let webView = MacPassthroughArtifactWKWebView(frame: .zero, configuration: config)
    webView.forwardsVerticalScroll = isInline
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
    loadContent(into: webView, coordinator: context.coordinator)
    return webView
  }

  func updateNSView(_ nsView: MacPassthroughArtifactWKWebView, context: Context) {
    nsView.forwardsVerticalScroll = isInline
    loadContent(into: nsView, coordinator: context.coordinator)
  }

  private func loadContent(
    into webView: MacPassthroughArtifactWKWebView,
    coordinator: Coordinator
  ) {
    let key = LoadKey(content: content, kind: kind, isDark: colorScheme == .dark)
    guard coordinator.lastKey != key else { return }
    coordinator.lastKey = key
    let html = MacArtifactPreviewSupport.sandboxedDocument(
      for: content,
      kind: kind,
      isDark: colorScheme == .dark
    )
    webView.loadHTMLString(html, baseURL: nil)
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    fileprivate var lastKey: LoadKey?

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      if navigationAction.navigationType == .other,
        navigationAction.request.url?.absoluteString == "about:blank"
      {
        return .allow
      }
      if navigationAction.navigationType == .linkActivated,
        let url = navigationAction.request.url,
        MacAnswerContentParser.isValidBrowsableURL(url)
      {
        NSWorkspace.shared.open(url)
      }
      return .cancel
    }
  }
}

@MainActor
final class MacPassthroughArtifactWKWebView: WKWebView {
  var forwardsVerticalScroll: Bool = true

  override func scrollWheel(with event: NSEvent) {
    if forwardsVerticalScroll, !event.modifierFlags.contains(.shift) {
      nextResponder?.scrollWheel(with: event)
      return
    }
    super.scrollWheel(with: event)
  }
}
