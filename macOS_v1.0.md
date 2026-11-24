# macOS v1.0 — Feature Parity Checklist (vs. iOS)

Prioritized checklist to bring `BYOKmac` to feature parity with `BYOKchat` (iOS). Excludes purely iOS hardware integrations (`PhotosPicker`, haptics, `BackgroundActivityKeeper`, `ScreenshotStudio`).

---

## P0 — Functional Bugs & Broken Core Parity

- [x] **Optional API keys for local & OpenAI-compatible servers** (`BYOKmac/App/MacProviderViews.swift`, `BYOKmac/App/MacProviderModel.swift`, `BYOKmac/App/MacProviderWorkspaceView.swift`)
  - Switch `requiresCredential` / `isReady(_:)` checks from `authentication != .none` to `ProviderDefinition.requiresCredential` so Ollama, LM Studio, and OpenAI-compatible servers work without an API key.
  - Add **Remove API Key** flow (`clearCredential`) and auto-clear stored Keychain secrets when switching custom auth to `.none`.
- [x] **Local server (Ollama / LM Studio) setup & ATS local networking** (`BYOKmac/App/MacProviderViews.swift`, `project.yml`)
  - Expose dedicated Base URL field (not buried in Advanced) with Ollama/LM Studio placeholders, apply `kind.normalizedBaseURL(_:)` (`/v1`), and add `NSAllowsLocalNetworking: true` to `BYOKmac` Info.plist / `project.yml` so `http://` LAN servers aren't blocked by ATS.
- [x] **MCP project-reference cleanup & `preserveEmpty` chat overrides** (`BYOKmac/App/MacMCPModel.swift`)
  - Call `projectWorkspace.removeMCPServerReferences(...)` when deleting an MCP server.
  - Pass `inheritedBase:` + `preserveEmpty: inherited != nil` when editing chat MCP configs so disabling all inherited project tools doesn't silently revert.
- [x] **Fix Anthropic default max-tokens cap in target picker** (`BYOKmac/App/MacProviderViews.swift`)
  - Use `AnthropicMessagesAdapter.defaultMaxTokens` instead of hardcoded `4_096`, with full min/max/output-cap budget hints.
- [x] **Surface swallowed status/warning messages (Toasts / Banners)** (`BYOKmac/App/MacWorkspaceModel.swift`, `BYOKmac/App/MacMCPModel.swift`)
  - `workspace.statusMessage` and `mcp.statusMessage` are written but never rendered; add a toast or banner overlay (matching `BYOKchat/App/BYOKToastCenter.swift`).
- [x] **Keep `"From Library…"` visible in composer when saved Library is empty** (`BYOKmac/App/MacChatPaneView.swift`)
  - Currently hidden when `workspace.libraryEntries.isEmpty`, making the `"From Chats"` picker tab unreachable.

---

## P1 — Major Missing User-Facing Features

- [x] **Per-Chat Settings sheet** (iOS ref: `ChatSettingsView` in `BYOKchat/Features/Chats/ChatView.swift`)
  - Per-chat System Prompt (with Reset to Project / Reset to Default / Clear), Temperature & Top-P toggles/sliders, Max Output Tokens with validation, and OpenRouter Routing options (Sort, Data Collection, Fallbacks, ZDR, Provider Order, Reset).
- [x] **Active-Chat Header Context & Overflow Menu** (`BYOKmac/App/MacChatPaneView.swift`)
  - Show active project badge/shortcut in `MacChatHeader` and a chat menu: Prompts, Chat Settings, Tools, Project Settings, Chat Usage/Analytics, Rename, Export Markdown, Delete.
- [x] **Export Full Conversation as Markdown** (`BYOKmac/App/MacChatPaneView.swift`, `BYOKmac/App/MacCommands.swift`)
  - Wire `ConversationMarkdownFormatter.render(_:accountLabel:)` (currently macOS only exports single messages).
- [x] **Layer 2 Remote Model Catalog (`ModelCatalogStore`)** (`BYOKmac/App/MacProviderModel.swift`)
  - Integrate `services.modelCatalog` (`refreshModelCatalogIfNeeded`, force refresh, cache clear, applying catalog updates to workspace) + 24h TTL / 15m failure-throttled per-account refresh.
- [x] **Provider Editor & Target Picker Discovery** (`BYOKmac/App/MacProviderViews.swift`, `BYOKmac/App/MacProviderWorkspaceView.swift`)
  - Pre-save **Test Connection** & **Fetch Models** (`previewModels`), searchable Default Model picker with capability badges (context window, Vision, Files), unsaved-changes discard guard, and **Delete/Remove manual models**.
  - In `MacTargetPickerView`: allow manual Model ID entry/removal, in-picker Refresh + last-checked timestamp, unready-account/unavailable-model warnings, and capability badges.
- [x] **Pre-send MCP Tools configuration** (`BYOKmac/App/MacChatPaneView.swift`, `BYOKmac/App/MacMCPViews.swift`)
  - Allow configuring MCP tools before the first message is sent (currently gated on `conversationID != nil`).
- [x] **Citations / Sources Sheet** (iOS ref: `BYOKchat/Features/Chats/AnswerContentParser.swift`, `BYOKchat/Features/Chats/AnswerPresentationViews.swift`)
  - Extract deduplicated links from assistant responses and add `"Sources"` action + sheet.
- [x] **Response Image Scanner & Save-Images Sheet** (iOS ref: `BYOKchat/Features/Library/ResponseImageScanner.swift`, `BYOKchat/Features/Library/ResponseImageSaveSheet.swift`)
  - Scan markdown/tables for remote + `data:image/` images and expose `"Save Images…"` to Library with multi-select and message provenance.
- [x] **Context-Omitted Banner, Configuration Repair Banner & Guided Setup Hero** (iOS ref: `BYOKchat/Features/Chats/ChatView+Content.swift`, `BYOKchat/Features/Chats/ChatComponents.swift`)
  - Surface omitted-context warnings (`lastContextOmittedMessageCount > 0`), broken target/credential/model repair banners, and actionable empty-chat setup cards.

---

## P2 — Markdown, Chat & Workspace UX Parity

- [x] **Custom Markdown Table Renderer** (`BYOKmac/App/MacAnswerContentParser.swift`, `BYOKmac/App/MacMarkdownMessageContent.swift`)
  - Parse `.table` blocks with dimensions header, edge fades, inline math/images/links in cells, **Copy as Markdown / TSV**, and full-screen 2D-scrollable viewer.
- [x] **Inline Response Image Provider** (`BYOKmac/App/MacMarkdownMessageContent.swift`)
  - Decode `data:image/*;base64,...`, cache bytes/thumbnails, show loading/unavailable states, and support click-to-zoom preview.
- [x] **Mermaid Diagram Parity** (`BYOKmac/App/MacMarkdownMessageContent.swift`)
  - Recognize `mermaidjs`/`mermaid-js` + attribute suffixes, strip YAML frontmatter & extract `title`, handle unsupported diagram types gracefully, match active app theme, add inline **Show Source / Show Diagram** toggle, click-to-expand, and zoom/pan + **Save/Share Image** in full screen.
- [x] **Paragraph-Level Inline Math Splitting & Currency Guards** (`BYOKmac/App/MacAnswerContentParseCache.swift`, `BYOKmac/App/MacAnswerContentParser.swift`)
  - Split markdown blocks per paragraph (instead of disabling inline math whenever a block has headings/lists) and add digit guards around `$` to avoid currency false positives.
- [x] **Chat Attachment Preview & Context Menu** (`BYOKmac/App/MacAttachmentSupport.swift`)
  - Click-to-preview attachments (image viewer / Quick Look) and per-tile `"Save to Library"` context menu; add inline `+ Add` tile and import spinner in composer.
- [x] **Failed / Cancelled / Interrupted Message UX** (`BYOKmac/App/MacRichMessageView.swift`, `BYOKmac/App/MacChatPaneView.swift`)
  - Styled failure card with `Account · Provider · Model` context + inline Retry button, and show `MacAssistantMessageActions` on failed/cancelled/interrupted messages (not just `.complete`).
- [x] **Long User Message Collapsing & URL Auto-Linking** (`BYOKmac/App/MacRichMessageView.swift`)
  - Collapse >12-line / >900-char user messages with Show more/less and auto-link HTTP(S) URLs.
- [x] **Search Deep-Linking & Sidebar Polish** (`BYOKmac/App/MacChatSessionModel.swift`, `BYOKmac/App/MacShellView.swift`)
  - Keep `messageID` on `SearchItem` so clicking a search result scrolls to the matched message; add project icons, generating spinner, Draft/model indicators, date-bucket grouping (`Today`, `Yesterday`, `Previous 7/30 Days`), title-match preview fallback, and FTS indexing progress.
- [x] **Windowed Transcript Loading** (`BYOKmac/App/MacChatPaneView.swift`)
  - Load latest 30 messages with `"Load N earlier messages"` button for long conversations (matching `ChatMessageWindowPolicy`).
- [x] **Projects & Library Polish** (`BYOKmac/App/MacProjectsWorkspaceView.swift`, `BYOKmac/App/MacLibraryAttachmentPickerView.swift`, `BYOKmac/App/MacLibraryView.swift`)
  - Project file Quick Look preview, off-main-actor import validation (reject dirs/empty/>40 MB, HEIC→JPEG normalization, text-only token estimates), Rename/Move/Delete actions in Project Chats tab, inline duplicate/length validation + unavailable-default warning + tool-preset overwrite confirmation.
  - Cross-tab multi-select + remaining-slot/size preflight in `MacLibraryAttachmentPickerView`; invalid-character/extension warnings in `MacLibraryRenameSheet` and `"Clear Search & Filters"` in empty results.
- [x] **Target Label Formatter Sync** (`BYOKmac/App/MacTargetLabelFormatter.swift`)
  - Port newer model families (`o1`/`o3`/`o4`/`glm`/Mistral families), slash/Fireworks/hyphen normalization, all provider short names (`Z.ai`, `Moonshot`, `MiniMax`, `Qwen`, etc.), and compact reasoning labels (`Min`/`Med`/`X-High`, `4K`/`Auto`).
- [x] **Provider Brand SVG Logos & Grouped Searchable Picker** (`project.yml`, `BYOKmac/App/MacProviderWorkspaceView.swift`)
  - Share the 39 `provider.*.imageset` SVGs + `ProviderLogoCatalog` host/alias matching on macOS, group `MacProviderKindPickerSheet` into **Cloud Providers** vs **Local & Custom** with search, allow switching kind during creation, and add the **Supported Providers** catalog view.
- [x] **Structured Additional Headers & `HTTPHeaderValidator`** (`BYOKmac/App/MacProviderViews.swift`, `BYOKmac/App/MacMCPViews.swift`)
  - Replace raw header `TextEditor`s with key/value editor enforcing `HTTPHeaderValidationPolicy` for both Providers and MCP servers.
- [x] **MCP Tools Sheet & Approval/Elicitation Safety** (`BYOKmac/App/MacMCPViews.swift`)
  - Add unsupported-model warning, while-generating mutation lock, missing-credential guard, inline `"Add MCP Server"` empty CTA, active preset checkmark, always-available Refresh + protocol version + tool descriptions.
  - Add `isResolving` double-submit guards on Approval/Elicitation cards, demote `"Always Allow"` when `isDestructive`, add `"None"` option for optional enum elicitations, validate/display `allowedValues` for `.stringArray`, and display full host/URL before opening `.url` elicitations.

---

## P3 — Analytics, Message Info & Settings Parity

- [x] **Analytics Rollups, Off-Main Computation & Missing Metrics** (`BYOKmac/App/MacAnalyticsView.swift`)
  - Load `dailyRollups` & `dailyErrorRollups` via `telemetryRecorder.loadAnalytics(...)`, compute snapshots off-main-actor, handle `.unavailable` with Retry, and add **Top Chats** on Overview.
  - Add missing metrics (Active chats, Total tokens, Cache write tokens, Cached hit-rate %, Tool cancelled count, per-row median TTFT & tok/s), fix `macUsageDisplayName` for all `ProviderKind`s/UUIDs, fix cost formatting (`No requests` vs `Unavailable`, exact vs `~` vs `≥`, OpenRouter BYOK footnote), and preserve acronyms in error titles (`HTTP`, `MCP`, etc.).
- [x] **Per-Conversation Analytics & Context Window Fill** (`BYOKmac/App/MacAnalyticsView.swift`)
  - Query `loadConversationAnalytics`, make reachable from active chat header, and add **Context window fill bar + omitted-messages warning**, per-chat Errors, per-chat Providers/Models breakdowns, and Tool failures/cancelled counts.
- [x] **Rich Per-Message Details (`MessageInfoView` parity)** (`BYOKmac/App/MacRichMessageView.swift`)
  - Show human-readable Provider/Account names, `ChatBilling.snapshot` cost + footnotes, **Pricing snapshot** (rates, official link, catalog metadata), **Performance** (total duration, TTFT, tok/s), context trimmed count, finish reason, cache write/hit rate, and expose `"Details"` in `MacAssistantMessageActions`'s `...` menu.
- [x] **Storage Usage Breakdown & Cache Cleanup** (`BYOKmac/App/MacDataManagementView.swift`, `BYOKmac/App/MacDataManagementModel.swift`)
  - Display `BYOKStorageUsageReport` per-category sizes + low-space/large-storage/quarantine warnings, add **Clear Cached Thumbnails**, **Clear Search Index**, and **Remove Unreadable Shards**, and clear `byokchat.sidebar.pinnedConversationIDs` on Delete All / Reset.
- [x] **Privacy, About, Legal URLs & Preferences Sync** (`BYOKmac/App/MacSettingsView.swift`, `BYOKmac/App/MacAppAnalytics.swift`, `BYOKmac/App/MacPurchaseStore.swift`, `BYOKmac/App/MacPreferencesModel.swift`)
  - Add **Share Anonymous Usage Data** opt-out toggle in Settings.
  - Add **About / Support / Legal** section (Website, Contact, Privacy Policy, Terms, Version/Build) and update stale `https://byok.pro/terms|privacy` paywall URLs + simulated prices in `MacPurchaseStore.swift`.
  - Normalize Default System Prompt, add **Clear Prompt** confirmation, and sync changes to untouched empty drafts (`syncDefaultSystemPrompt`).

---

## P4 — Polish, Pro Flow & Debug/Diagnostics Parity

- [ ] **Pro Gating & Themes Alignment** (`BYOKmac/App/MacPurchaseStore.swift`, `BYOKmac/App/MacThemeModel.swift`)
  - Add `.themes` and `.chatSearch` (FTS5 gating) to `MacProFeature` + contextual Free-vs-Pro upsell flow before paywall; decide whether to port the 10 custom `BYOKchatThemes` palettes or keep `MacAppFoundation` themes.
- [ ] **Diagnostics & `#if DEBUG` Developer Tools** (`BYOKmac/App/MacDiagnosticsView.swift`, `BYOKmac/App/BYOKmacApp.swift`)
  - Diagnostics: show `Daily rollups` count, enable Clear All Telemetry when rollups exist even if `eventCount == 0`, add `Model requests`, `Tool calls`, and `ShareLink` in event detail, fix `"Mcp"` → `"MCP"`.
  - Debug tools (if needed for testing): Provider Console, AI Provider Simulator, Model Catalog Inspector, FTS5 Inspector, Seed Data, and Upsell replays.
- [ ] **Minor Polish**
  - Add `Created`/`Updated` timestamps, inline `Enabled` toggle, and inline URL error message in `MacConnectionEditorView`; group Active vs Disabled accounts/MCP servers; add `Refresh Models` to provider card menu; add `snapshot.refreshedAt` to MCP detail overview; add character-cap collapse (`1_800` chars) & shared `Highlighter` in `MacHighlightedCodeBlock`, `heading4`–`heading6` styles, unchanged-message & broken-config guards in `MacEditAndResendView`, and interactive onboarding demos if desired.
