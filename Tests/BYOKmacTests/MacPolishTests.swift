import AppKit
import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import SwiftUI
import Testing

@testable import BYOKmac

@Suite("macOS minor polish guards and helpers")
struct MacPolishTests {
  // MARK: - Code Block Collapse Policy

  @Test("Code block collapse thresholds match macOS polish contract")
  func codeBlockThresholds() {
    #expect(MacHighlightedCodeBlock.collapseLineThreshold == 18)
    #expect(MacHighlightedCodeBlock.collapseCharacterThreshold == 1_800)
  }

  @Test("Short code blocks stay uncollapsed")
  func codeBlockShortContentUncollapsed() {
    let shortCode = (1...18).map { "let line\($0) = \($0)" }.joined(separator: "\n")
    let preview = MacHighlightedCodeBlock.preview(for: shortCode, isExpanded: false)
    #expect(!preview.isLong)
    #expect(preview.displayedContent == shortCode)
    #expect(preview.lineCount == 18)
  }

  @Test("Code blocks exceeding 1,800 characters collapse even on a single line")
  func codeBlockCharacterCapCollapse() {
    let atLimit = String(repeating: "a", count: 1_800)
    let atLimitPreview = MacHighlightedCodeBlock.preview(for: atLimit, isExpanded: false)
    #expect(!atLimitPreview.isLong)
    #expect(atLimitPreview.displayedContent == atLimit)

    let overLimit = String(repeating: "x", count: 1_801)
    let collapsed = MacHighlightedCodeBlock.preview(for: overLimit, isExpanded: false)
    #expect(collapsed.isLong)
    #expect(collapsed.displayedContent == String(repeating: "x", count: 1_800) + "\n…")
    #expect(collapsed.toggleLabel == "Show all")

    let expanded = MacHighlightedCodeBlock.preview(for: overLimit, isExpanded: true)
    #expect(expanded.isLong)
    #expect(expanded.displayedContent == overLimit)
    #expect(expanded.toggleLabel == "Show less")
  }

  @Test("Code blocks exceeding 18 lines collapse with line-count toggle and character cap")
  func codeBlockLineCapCollapse() {
    let lines = (1...25).map { "line \($0)" }.joined(separator: "\n")
    let collapsed = MacHighlightedCodeBlock.preview(for: lines, isExpanded: false)
    #expect(collapsed.isLong)
    #expect(collapsed.lineCount == 25)
    #expect(collapsed.toggleLabel == "Show all 25 lines")
    let expectedPrefix = (1...18).map { "line \($0)" }.joined(separator: "\n") + "\n…"
    #expect(collapsed.displayedContent == expectedPrefix)

    let expanded = MacHighlightedCodeBlock.preview(for: lines, isExpanded: true)
    #expect(expanded.displayedContent == lines)
    #expect(expanded.toggleLabel == "Show less")

    let streaming = MacHighlightedCodeBlock.preview(for: lines, isExpanded: false, isStreaming: true)
    #expect(streaming.displayedContent == lines)
  }

  @Test("Code blocks exceeding both line and character limits enforce both caps")
  func codeBlockCombinedLineAndCharacterCap() {
    let longLines = (1...20).map { _ in String(repeating: "b", count: 200) }.joined(separator: "\n")
    let collapsed = MacHighlightedCodeBlock.preview(for: longLines, isExpanded: false)
    #expect(collapsed.isLong)
    #expect(collapsed.displayedContent.hasSuffix("\n…"))
    let bodyWithoutEllipsis = String(collapsed.displayedContent.dropLast(2))
    #expect(bodyWithoutEllipsis.count == 1_800)
  }

  // MARK: - Connection URL Validation

  @Test("Empty URL is not flagged as an inline error and resolves built-in defaults")
  func urlValidatorEmptyInput() {
    #expect(MacConnectionURLValidator.validationError(for: "", kind: .openAICompatible) == nil)
    #expect(MacConnectionURLValidator.validationError(for: "   ", kind: .ollama) == nil)
    #expect(MacConnectionURLValidator.resolvedEndpoint(for: "", kind: .openAICompatible) == nil)
    #expect(
      MacConnectionURLValidator.resolvedEndpoint(for: "", kind: .openai)
        == ProviderKind.openai.defaultEndpoint
    )
    #expect(
      MacConnectionURLValidator.resolvedEndpoint(for: "", kind: .ollama)
        == ProviderKind.ollama.defaultEndpoint
    )
  }

  @Test("Valid HTTP and HTTPS URLs pass validation and normalize local server paths")
  func urlValidatorValidHTTPAndHTTPS() {
    #expect(
      MacConnectionURLValidator.validationError(
        for: "https://api.example.com/v1",
        kind: .openAICompatible
      ) == nil
    )
    #expect(
      MacConnectionURLValidator.validationError(
        for: "http://192.168.1.20:11434",
        kind: .ollama
      ) == nil
    )
    #expect(
      MacConnectionURLValidator.resolvedEndpoint(
        for: "http://192.168.1.20:11434",
        kind: .ollama
      )?.absoluteString == "http://192.168.1.20:11434/v1"
    )
    #expect(
      MacConnectionURLValidator.resolvedEndpoint(
        for: "  https://proxy.internal/v1  ",
        kind: .openAICompatible
      )?.absoluteString == "https://proxy.internal/v1"
    )
  }

  @Test("Invalid non-empty URLs return an inline validation error")
  func urlValidatorInvalidInput() {
    let invalidInputs = [
      "localhost:11434",
      "ftp://example.com/v1",
      "https://",
      "http://",
      "not a url at all",
      "://missing-scheme",
    ]
    for raw in invalidInputs {
      #expect(
        MacConnectionURLValidator.validationError(for: raw, kind: .openAICompatible)
          == MacConnectionURLValidator.invalidURLMessage
      )
      #expect(
        MacConnectionURLValidator.resolvedEndpoint(for: raw, kind: .openAICompatible) == nil
      )
      #expect(
        MacConnectionURLValidator.validationError(for: raw, kind: .ollama)
          == MacConnectionURLValidator.invalidURLMessage
      )
    }
  }

  @Test("Transport security rules reject cleartext HTTP on cloud and public hosts and embedded credentials")
  func urlValidatorTransportSecurity() {
    #expect(
      MacConnectionURLValidator.validationError(for: "http://api.openai.com/v1", kind: .openai)
        == MacConnectionURLValidator.httpsRequiredMessage
    )
    #expect(
      MacConnectionURLValidator.resolvedEndpoint(for: "http://api.openai.com/v1", kind: .openai) == nil
    )

    #expect(
      MacConnectionURLValidator.validationError(for: "http://example.com/v1", kind: .openAICompatible)
        == MacConnectionURLValidator.privateNetworkHTTPMessage
    )
    #expect(
      MacConnectionURLValidator.resolvedEndpoint(for: "http://example.com/v1", kind: .openAICompatible) == nil
    )

    #expect(
      MacConnectionURLValidator.validationError(for: "https://user:pass@api.example.com/v1", kind: .openAICompatible)
        == MacConnectionURLValidator.credentialsNotAllowedMessage
    )
    #expect(
      MacConnectionURLValidator.resolvedEndpoint(for: "https://user:pass@api.example.com/v1", kind: .openAICompatible)
        == nil
    )
  }

  // MARK: - Edit & Resend Guard

  @Test("Empty and whitespace-only edits are blocked")
  func editAndResendBlocksEmptyAndWhitespace() {
    #expect(
      MacEditAndResendGuard.blockReason(draft: "", original: "Hello") == .empty
    )
    #expect(!MacEditAndResendGuard.canResend(draft: "", original: "Hello"))

    #expect(
      MacEditAndResendGuard.blockReason(draft: "  \n\t  ", original: "Hello") == .empty
    )
    #expect(!MacEditAndResendGuard.canResend(draft: "  \n\t  ", original: "Hello"))
  }

  @Test("Unchanged edits (including surrounding whitespace) are blocked")
  func editAndResendBlocksUnchanged() {
    #expect(
      MacEditAndResendGuard.blockReason(draft: "Hello", original: "Hello") == .unchanged
    )
    #expect(!MacEditAndResendGuard.canResend(draft: "Hello", original: "Hello"))

    #expect(
      MacEditAndResendGuard.blockReason(draft: "  Hello\n", original: "Hello") == .unchanged
    )
    #expect(!MacEditAndResendGuard.canResend(draft: "  Hello\n", original: "Hello"))
  }

  @Test("Changed edits with broken configuration or active generation are blocked")
  func editAndResendBlocksBrokenConfigurationAndGenerating() {
    let issues: [MacChatConfigurationIssue] = [
      .providerMissing,
      .accountMissing,
      .accountDisabled(label: "OpenAI"),
      .accountRestricted(label: "Anthropic"),
      .missingCredential(label: "OpenAI"),
      .modelMissing(modelID: "gpt-4o"),
      .modelUnavailable(modelName: "GPT-4o"),
    ]
    for issue in issues {
      #expect(
        MacEditAndResendGuard.blockReason(
          draft: "Updated prompt",
          original: "Original prompt",
          configurationIssue: issue
        ) == .configurationIssue(issue.message)
      )
      #expect(
        !MacEditAndResendGuard.canResend(
          draft: "Updated prompt",
          original: "Original prompt",
          configurationIssue: issue
        )
      )
    }

    #expect(
      MacEditAndResendGuard.blockReason(
        draft: "Updated prompt",
        original: "Original prompt",
        configurationIssue: nil,
        isGenerating: true
      ) == .generating
    )
    #expect(
      !MacEditAndResendGuard.canResend(
        draft: "Updated prompt",
        original: "Original prompt",
        configurationIssue: nil,
        isGenerating: true
      )
    )
  }

  @Test("Changed edits with valid configuration are allowed")
  func editAndResendAllowsValidChangedEdit() {
    #expect(
      MacEditAndResendGuard.blockReason(
        draft: "Updated prompt",
        original: "Original prompt",
        configurationIssue: nil,
        isGenerating: false
      ) == nil
    )
    #expect(
      MacEditAndResendGuard.canResend(
        draft: "Updated prompt",
        original: "Original prompt",
        configurationIssue: nil,
        isGenerating: false
      )
    )
  }

  // MARK: - Active vs Disabled Partitioning

  @Test("Partitioning separates active and disabled items while preserving order")
  func activeDisabledPartitioning() {
    struct Item: Equatable, Sendable {
      let id: String
      let isEnabled: Bool
    }

    let empty = MacActiveDisabledPartition([Item](), isEnabled: \.isEnabled)
    #expect(empty.active.isEmpty)
    #expect(empty.disabled.isEmpty)
    #expect(!empty.showsSectionHeaders)

    let allActive = MacActiveDisabledPartition(
      [Item(id: "a", isEnabled: true), Item(id: "b", isEnabled: true)],
      isEnabled: \.isEnabled
    )
    #expect(allActive.active.map(\.id) == ["a", "b"])
    #expect(allActive.disabled.isEmpty)
    #expect(!allActive.showsSectionHeaders)

    let mixed = MacActiveDisabledPartition(
      [
        Item(id: "a", isEnabled: true),
        Item(id: "b", isEnabled: false),
        Item(id: "c", isEnabled: true),
        Item(id: "d", isEnabled: false),
      ],
      isEnabled: \.isEnabled
    )
    #expect(mixed.active.map(\.id) == ["a", "c"])
    #expect(mixed.disabled.map(\.id) == ["b", "d"])
    #expect(mixed.showsSectionHeaders)

    let allDisabled = MacActiveDisabledPartition(
      [Item(id: "x", isEnabled: false), Item(id: "y", isEnabled: false)],
      isEnabled: \.isEnabled
    )
    #expect(allDisabled.active.isEmpty)
    #expect(allDisabled.disabled.map(\.id) == ["x", "y"])
    #expect(allDisabled.showsSectionHeaders)
  }

  @Test("Partitioning works with ProviderAccount and MCPRemoteServer collections")
  func activeDisabledPartitioningDomainModels() throws {
    let activeAccount = ProviderAccount(
      kind: .openai,
      id: "acct-active",
      label: "OpenAI",
      isEnabled: true
    )
    let disabledAccount = ProviderAccount(
      kind: .ollama,
      id: "acct-disabled",
      label: "Local Ollama",
      isEnabled: false
    )
    let accountPartition = MacActiveDisabledPartition(
      [activeAccount, disabledAccount],
      isEnabled: \.isEnabled
    )
    #expect(accountPartition.active.map(\.id) == ["acct-active"])
    #expect(accountPartition.disabled.map(\.id) == ["acct-disabled"])
    #expect(accountPartition.showsSectionHeaders)

    let endpoint = try #require(URL(string: "https://example.com/mcp"))
    let activeServer = MCPRemoteServer(
      id: "mcp-1",
      name: "Docs",
      endpoint: endpoint,
      isEnabled: true
    )
    let disabledServer = MCPRemoteServer(
      id: "mcp-2",
      name: "Legacy",
      endpoint: endpoint,
      isEnabled: false
    )
    let serverPartition = MacActiveDisabledPartition(
      [activeServer, disabledServer],
      isEnabled: \.isEnabled
    )
    #expect(serverPartition.active.map(\.id) == ["mcp-1"])
    #expect(serverPartition.disabled.map(\.id) == ["mcp-2"])
    #expect(serverPartition.showsSectionHeaders)
  }

  // MARK: - Theme Appearance Policy

  @Test("Theme appearance policy maps light and dark themes to NSAppearance and leaves system nil")
  func themeAppearancePolicyMapping() {
    #expect(
      MacThemeAppearancePolicy.appearanceName(
        effectiveThemeID: .system,
        preferredColorScheme: nil
      ) == nil
    )
    #expect(
      MacThemeAppearancePolicy.appearanceName(
        effectiveThemeID: .system,
        preferredColorScheme: .dark
      ) == nil
    )
    #expect(
      MacThemeAppearancePolicy.appearanceName(
        effectiveThemeID: .githubDarkDimmed,
        preferredColorScheme: .dark
      ) == .darkAqua
    )
    #expect(
      MacThemeAppearancePolicy.appearanceName(
        effectiveThemeID: .githubLight,
        preferredColorScheme: .light
      ) == .aqua
    )
    #expect(
      MacThemeAppearancePolicy.appearanceName(
        effectiveThemeID: .githubLight,
        preferredColorScheme: nil
      ) == nil
    )
  }

  // MARK: - Message Export Filename

  @Test("Message export filenames sanitize conversation titles and fall back cleanly")
  func messageExportFilenameFormatting() {
    let assistantMessage = ChatMessage(role: .assistant, content: "Hello", status: .completed)
    let userMessage = ChatMessage(role: .user, content: "Hi", status: .completed)

    #expect(
      MacMessageExportSupport.filename(
        for: assistantMessage,
        conversationTitle: "Swift 6 Concurrency: Notes!"
      ) == "Swift-6-Concurrency-Notes-response.md"
    )
    #expect(
      MacMessageExportSupport.filename(
        for: userMessage,
        conversationTitle: "Swift 6 Concurrency: Notes!"
      ) == "Swift-6-Concurrency-Notes-message.md"
    )
    #expect(
      MacMessageExportSupport.filename(
        for: assistantMessage,
        conversationTitle: "New Chat"
      ) == "assistant-response.md"
    )
    #expect(
      MacMessageExportSupport.filename(
        for: userMessage,
        conversationTitle: "   "
      ) == "message.md"
    )
    #expect(
      MacMessageExportSupport.filename(
        for: assistantMessage,
        conversationTitle: nil
      ) == "assistant-response.md"
    )
  }
}
