# macOS Chat Renderer Assessment (`BYOKmac`)

An assessment of the current macOS chat message renderer (`MacMarkdownMessageContent`, `MacStreamingRenderedContentView`, `MacStreamingAnswerRenderer`, `MacAnswerContentParser`, `MacAnswerContentParseCache`, `MacHorizontalPassthroughScrollView`, `MacRichMessageView`, and `MacAnswerSourcesPopover`), including features expected in a best-in-class desktop AI chat renderer.

## Feature Assessment Matrix

| Feature | Status | Score | Current Implementation & Strengths | Gaps vs. a Perfect Renderer |
| --- | --- | :---: | --- | --- |
| **Core Markdown** | Supported | **8.5 / 10** | `MarkdownUI` + custom `chatTheme`, off-main-actor batch prewarming (`MacAnswerContentParseCache`), headings, lists, task lists, blockquotes, links, thematic breaks. | Headings/blockquotes use system `.primary`/`.secondary` rather than explicit `appTheme` tokens; no GFM alerts (`> [!NOTE]`), footnotes, or `<details>` support. |
| **Streaming Incremental Render** | Supported | **8.5 / 10** | Serialized `MacStreamingAnswerRenderer` actor freezes immutable prefix blocks (`Equatable`), keeps per-token parsing off main thread, stabilizes unfinished inline math. | Mutable tail renders raw Markdown syntax (`**bold**`, `[link](url)`) until the block completes, causing a brief visual "pop"; no progressive inline Markdown on the active paragraph. |
| **Code Blocks & Highlighting** | Supported | **8.0 / 10** | Async `Highlighter` actor, collapsible long blocks, full-screen sheet, Copy/Share, passthrough horizontal scroll with indicator. | Hardcoded `NSColor.textBackgroundColor` + `github`/`github-dark` instead of custom app themes; no line numbers, no soft-wrap toggle, no diff (`+`/`-`) highlighting, no live highlighting while streaming. |
| **Markdown Tables** | Supported | **9.0 / 10** | Custom `MacMarkdownTableView` with computed column widths, alignments, alternating themed rows, edge fades, passthrough horizontal scroll, collapse >12 rows, full-screen view, Copy as Markdown & TSV. | No column sorting/filtering, no CSV file export, occasional edge cases mixing inline math + Markdown inside a single cell. |
| **LaTeX / Math** | Supported | **7.5 / 10** | `LaTeXSwiftUI` for display (`$$`, `\[`) and inline (`$`, `\(`) math; streaming tail prevents raw `$` flicker. | Paragraphs mixing inline math with bold/links/code can't render both seamlessly together; wide display equations have no horizontal scroll; no click-to-copy LaTeX source. |
| **Mermaid Diagrams** | Supported | **8.5 / 10** | Async `BeautifulMermaid` rasterization + theme/scale cache, click-to-zoom full-screen canvas, source toggle, PNG save/share, error & unsupported-kind fallbacks. | Limited to diagram types supported by `BeautifulMermaid`; rasterized (no text selection inside nodes); no SVG export. |
| **Inline Images (Remote & Base64)** | Supported | **8.0 / 10** | `MacMarkdownResponseImageProvider` with memory + disk cache, `CGImageSource` downsampling, `MacImageGeometryCache` (prevents scroll jump), preview modal, Save to Library. | No animated GIF/WebP playback; no inline SVG rendering; no direct right-click **Copy Image** on inline images. |
| **Reasoning / Thinking Disclosure** | Supported | **8.5 / 10** | Inline collapsible disclosure with `2 pt` guide bar, muted Markdown, live `TimelineView` duration timer, inline Copy, bottom Collapse for long traces, lazy streaming render gating. | Elapsed thinking duration isn't persisted on `ChatMessage` (reopening chat shows `"Thought"` without time); no optional auto-collapse when the answer starts streaming. |
| **Sources & Citations** | Supported | **7.5 / 10** | Clean extraction from Markdown + tables (skips code/math/images, cleans titles, numeric citation fallback, case-sensitive dedup) + lightweight themed `MacAnswerSourcesPopover`. | Extracted from text only—no structured provider citation payloads (`url_citation`, Anthropic citations, Gemini grounding); no favicons; no hoverable inline `[1]` citation chips. |
| **MCP / Tool Call Rounds** | Supported | **7.5 / 10** | Collapsible `MacToolRoundsView` + interactive `MacMCPElicitationCard` forms/approvals. | JSON tool inputs/outputs lack syntax highlighting, collapsible tree view, and quick-copy per payload. |
| **User Messages** | Supported | **8.0 / 10** | Clean bubble, long-message collapse (>12 lines / 900 chars), cached URL detection, attachment strip, Edit & Resend. | Plain text only—pasted Markdown/code fences in user prompts don't format as code blocks. |
| **Error & Interrupted States** | Supported | **8.5 / 10** | Minimalist borderless left-bar error notice with provider/model context and inline `Retry` button in the action bar. | Could add expandable raw HTTP/error details inline for debugging without opening Message Details. |
| **Scroll & Layout Performance** | Supported | **8.5 / 10** | `List` virtualization, batch answer prewarming, cached image heights, `MacHorizontalPassthroughScrollView` preventing nested-scroll traps. | Very large single messages (dozens of code blocks/tables) still lay out all blocks inside one `List` row rather than per-block virtualization. |
| **Cross-Block Text Selection** | Partial | **3.0 / 10** | `.textSelection(.enabled)` works within each individual `Text` / Markdown / code block. | **Expected in a perfect macOS renderer:** drag-selecting smoothly across paragraphs, lists, code blocks, and tables in one sweep + **Copy as Markdown** for selections. |
| **Adjustable Reading Typography / Zoom** | Partial | **2.0 / 10** | `textSize` parameter already exists on `MacMarkdownMessageContent` (`BYOKmac/App/MacMarkdownMessageContent.swift`). | **Expected in a perfect macOS renderer:** `⌘+` / `⌘-` / `⌘0` transcript font scaling and compact/comfortable reading width preference. |
| **In-Conversation Find (`⌘F`)** | Missing | **0.0 / 10** | Only global conversation search (`⌘K`) exists. | **Expected in a perfect macOS renderer:** inline `⌘F` find bar inside the active chat with match highlighting and `⌘G` / `⇧⌘G` navigation. |
| **Interactive Artifacts (HTML / SVG / Charts)** | Missing | **0.0 / 10** | HTML/SVG renders as syntax-highlighted code only. | **Expected in a perfect macOS renderer:** sandboxed `WKWebView` live preview toggle for HTML/SVG/interactive snippets (with console/error isolation). |
| **GFM Callouts, Footnotes & `<details>`** | Missing | **1.0 / 10** | Standard blockquotes render cleanly; extensions fall back to plain text. | **Expected in a perfect macOS renderer:** styled `> [!NOTE]` / `[!WARNING]` callouts, clickable `[^1]` footnotes, and native collapsible `<details><summary>` blocks. |
| **Response Branching (`< 1 / 3 >`)** | Missing | **0.0 / 10** | Retry regenerates in place; edit truncates downstream history. | **Expected in a perfect macOS renderer:** inline version switcher on regenerated/edited turns without losing prior answers. |

## Overall Score

- **Current Supported Feature Set:** **8.2 / 10** — strong native SwiftUI/AppKit renderer (tables, Mermaid, streaming stability, passthrough scrolling, and reasoning are well above typical macOS SwiftUI chat apps).
- **Against a "Perfect" Desktop AI Renderer:** **6.8 / 10**

## Highest-Leverage Improvements Toward 10/10

1. **Cross-block text selection** — the biggest desktop ergonomics difference vs. web or unified `NSTextView`-backed renderers.
2. **Theme-matched code blocks with wrap toggle & line numbers** — quick, high-impact visual and usability polish.
3. **In-chat `⌘F` find + `⌘+`/`⌘-` font scaling** — core macOS reading expectations.
4. **Progressive inline Markdown on the streaming tail** — eliminates the formatting "pop" when a streaming paragraph completes.
5. **Structured provider web-search citations & inline chips** — native support for OpenAI `url_citation`, Anthropic citations, and Gemini grounding metadata with hoverable inline citation badges.
