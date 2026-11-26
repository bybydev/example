import AppKit
import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import SwiftUI
import Testing
@testable import BYOKmac

@Suite("Mac Transcript Renderer Improvements")
struct MacTranscriptRendererSupportTests {
  @Test("Transcript font size preference clamps, persists, and resets")
  @MainActor
  func transcriptFontSizePreferences() {
    let suiteName = "MacTranscriptRendererSupportTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = MacPreferencesModel(defaults: defaults)
    #expect(preferences.transcriptFontSize == MacPreferencesModel.defaultTranscriptFontSize)

    preferences.increaseTranscriptFontSize()
    #expect(preferences.transcriptFontSize == 16)

    for _ in 0..<20 {
      preferences.increaseTranscriptFontSize()
    }
    #expect(preferences.transcriptFontSize == MacPreferencesModel.maximumTranscriptFontSize)
    #expect(!preferences.canIncreaseTranscriptFontSize)

    let reloaded = MacPreferencesModel(defaults: defaults)
    #expect(reloaded.transcriptFontSize == MacPreferencesModel.maximumTranscriptFontSize)

    reloaded.resetTranscriptFontSize()
    #expect(reloaded.transcriptFontSize == MacPreferencesModel.defaultTranscriptFontSize)

    for _ in 0..<20 {
      reloaded.decreaseTranscriptFontSize()
    }
    #expect(reloaded.transcriptFontSize == MacPreferencesModel.minimumTranscriptFontSize)
    #expect(!reloaded.canDecreaseTranscriptFontSize)
  }

  @Test("In-conversation find indexes matches across message content and reasoning")
  func inChatFindIndexesMatches() {
    let first = ChatMessage(role: .user, content: "Explain Swift concurrency", status: .complete)
    let second = ChatMessage(
      role: .assistant,
      content: "Swift uses structured concurrency. SWIFT actors isolate state.",
      reasoning: "Need to mention swift tasks",
      status: .complete
    )

    let index = MacTranscriptFindSupport.search(query: "swift", in: [first, second])
    #expect(index.totalMatches == 4)
    #expect(index.countsByMessageID[first.id] == 1)
    #expect(index.countsByMessageID[second.id] == 3)
    #expect(index.matches[0] == MacTranscriptFindMatch(messageID: first.id, occurrenceInMessage: 0))
    #expect(index.matches[3] == MacTranscriptFindMatch(messageID: second.id, occurrenceInMessage: 2))

    #expect(MacTranscriptFindSupport.search(query: "   ", in: [first, second]).totalMatches == 0)
  }

  @Test("Streaming tail formatter stabilizes unfinished links/math and formats inline Markdown")
  func streamingTailFormatting() {
    let stabilizedLink = MacStreamingTailFormatter.stabilizedSource(
      "Check [Swift Docs](https://swift.org/doc"
    )
    #expect(stabilizedLink == "Check Swift Docs…")

    let stabilizedMath = MacStreamingTailFormatter.stabilizedSource("Value is $x + 1")
    #expect(stabilizedMath == "Value is …")

    let formatted = MacStreamingTailFormatter.formattedAttributedString(
      "## Summary\n- Use `Task` with **actors**",
      textSize: 15,
      foregroundColor: .primary,
      mutedColor: .secondary,
      accentColor: .accentColor,
      codeBackground: .gray.opacity(0.1)
    )
    let plain = String(formatted.characters)
    #expect(plain.contains("Summary"))
    #expect(plain.contains("• Use Task with actors"))
    #expect(!plain.contains("**"))
    #expect(!plain.contains("##"))
  }

  @Test("Structured provider citations merge cleanly with extracted links and annotate offsets")
  func structuredCitationsMergeAndAnnotate() {
    let structured = [
      ChatCitation(
        url: "https://swift.org/concurrency",
        title: "Swift Concurrency",
        snippet: "Structured concurrency in Swift.",
        startIndex: 0,
        endIndex: 25
      ),
      ChatCitation(
        url: "https://developer.apple.com/documentation/swift",
        title: "Apple Developer",
        snippet: nil,
        startIndex: nil,
        endIndex: nil
      ),
    ]
    let extracted = [
      MacAnswerSource(url: URL(string: "https://swift.org/concurrency")!, title: nil),
      MacAnswerSource(url: URL(string: "https://example.com/extra")!, title: "Extra"),
    ]

    let merged = MacCitationSupport.mergedSources(
      structuredCitations: structured,
      extractedSources: extracted
    )
    #expect(merged.count == 3)
    #expect(merged[0].displayTitle == "Swift Concurrency")
    #expect(merged[0].snippet == "Structured concurrency in Swift.")
    #expect(merged[0].isProviderCitation)
    #expect(merged[1].displayTitle == "Apple Developer")
    #expect(merged[2].displayTitle == "Extra")

    let annotated = MacCitationSupport.annotateInlineCitations(
      in: "Swift supports structured concurrency natively.",
      citations: structured,
      mergedSources: merged
    )
    #expect(annotated.contains("[1](https://swift.org/concurrency)"))
  }

  @Test("Cross-block selectable Markdown builds attributed document and extracts Copy as Markdown")
  @MainActor
  func selectableMarkdownBuilderAndCopyAsMarkdown() {
    let markdown = """
    ## Overview

    First paragraph with **bold** and `inline`.

    ```swift
    let x = 1
    ```
    """
    #expect(MacSelectableMarkdownBuilder.canRenderNatively("## Overview\n\nSimple text."))
    #expect(!MacSelectableMarkdownBuilder.canRenderNatively("![img](https://example.com/a.png)"))
    #expect(!MacSelectableMarkdownBuilder.canRenderNatively("Equation $x^2$ here"))

    let style = MacSelectableMarkdownBuilder.Style(
      textSize: 15,
      muted: false,
      isDark: false,
      themeID: .githubLight,
      textColor: .labelColor,
      mutedColor: .secondaryLabelColor,
      accentColor: .controlAccentColor,
      codeBackgroundColor: .quaternaryLabelColor,
      codeBlockBackgroundColor: .textBackgroundColor,
      separatorColor: .separatorColor,
      findQuery: "bold",
      activeFindOccurrence: 0
    )
    let attributed = MacSelectableMarkdownBuilder.attributedString(
      for: markdown,
      includeStructuredBlocks: true,
      style: style
    )
    #expect(attributed.string.contains("Overview"))
    #expect(attributed.string.contains("let x = 1"))

    let fullRange = NSRange(location: 0, length: attributed.length)
    let copiedMarkdown = MacSelectableMarkdownBuilder.markdownSnippet(
      from: attributed,
      selectedRange: fullRange
    )
    #expect(copiedMarkdown.contains("## Overview"))
    #expect(copiedMarkdown.contains("```swift"))
  }

  @Test("ChatMessage citations field decodes backwards-compatibly when omitted")
  func chatMessageCitationsBackwardsCompatibility() throws {
    let original = ChatMessage(
      role: .assistant,
      content: "Hello",
      citations: [ChatCitation(url: "https://example.com", title: "Example")],
      status: .complete
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: encoded)
    #expect(decoded.citations?.count == 1)
    #expect(decoded.citations?.first?.url == "https://example.com")

    let legacy = ChatMessage(role: .assistant, content: "Legacy", status: .complete)
    let legacyData = try JSONEncoder().encode(legacy)
    let decodedLegacy = try JSONDecoder().decode(ChatMessage.self, from: legacyData)
    #expect(decodedLegacy.citations == nil)
  }

  @Test("User message link detection handles uppercase schemes, ignores filenames, and trims trailing punctuation")
  func userMessageLinkDetectionEdgeCases() {
    let prompt = "Check (HTTPS://SWIFT.ORG/docs). Also edit README.md and App.swift, or visit www.apple.com/macos!"
    let matches = MacUserMessageTextSupport.linkMatches(in: prompt)

    #expect(matches.count == 2)
    #expect(matches[0].url.absoluteString == "HTTPS://SWIFT.ORG/docs")
    #expect(matches[1].url.absoluteString == "https://www.apple.com/macos")
  }
}
