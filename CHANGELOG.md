# Changelog

## [1.3] - 2026-11-24

### Added
- New built-in providers: Groq, Alibaba Qwen, Together AI, and Fireworks AI.
- SQLite FTS5 full-text search storage (`ConversationSearchIndexStore`) for conversations.
- 2-layer model catalog (`ModelCatalog.json` and `ModelCatalog`) unifying model capabilities and pricing.
- Additional HTTP headers support and validation (`HTTPHeaderValidation` and `AdditionalHeadersSection`).
- Expandable active provider row in Connections.
- Unified iOS seed data service (`BYOKSeedDataService`) and Developer Settings section (`DeveloperSettingsSection`) for Dev Tools seeding.
- Automated App Store screenshots workflow (`.github/workflows/screenshots.yml`), `BYOKchatScreenshots` scheme, and `xcode-27` / iOS 27 simulator support.

### Changed
- Updated connection editing and provider management UI (`ConnectionEditorView`, `ConnectionsView`, `ConnectionComponents`).
- Replaced `ModelPricingCatalog.json` with `ModelCatalog.json` and `BYOKScreenshotFixtures` with `BYOKSeedDataService`.

### Removed
- Model catalog status from Settings.

## [1.2] - 2026-11-23

### Added
- New built-in providers: z.ai, Moonshot AI (Kimi), MiniMax, Mistral AI, Ollama, and LMStudio.
- Chat settings (`cdb3d33`) and "All Chats" button in the sidebar (`cb0a06b`).
- Multi-year chat storage, memory management, and cleanup overhaul (`764d37c`).
- Expanded test suite covering `AnswerContentParser`, `AppStorageBootstrap`, `AttachmentBlobStore`, `ConversationLazyLoading`, `LibraryStoreTransaction`, `MCPRemoteRuntime`, `MCPWorkspaceTransaction`, `NativeProviderAdapter`, `OpenAIResponsesAdapter`, `ProjectWorkspace`, `ProviderTransportSecurity`, `TelemetryAnalytics`, `TelemetryStore`, `ToolCalling`, and `XAIResponsesAdapter`.

### Changed
- Updated existing providers: Gemini, Anthropic, OpenAI, xAI, DeepSeek, OpenRouter, and NVIDIA.
- Overhauled Chat UI, Markdown tables/images/diagrams, composer, sidebar two-phase handoff, image-decoding, and list performance (`ChatView`, `MarkdownMessageContent`, `AnswerContentParser`, `AnswerPresentationViews`).
- Updated AI providers list, connection editor, provider/model/reasoning picker, projects (with color picker), MCP servers, and Library views.
- Improved long-term analytics storage (`TelemetrySQLiteStore`), usage dashboard, and conversation analytics.
- Updated onboarding screens, themes, inset grouped styling across views, and errors/warnings/permission surfaces.
- Fixed Library file storage issues (`d4802d9`) and `ConversationToolsView` menu wiring (`a5b45c5`).

### Removed
- `#if DEBUG` monthly budget feature (`4950313`).

## [1.1] - 2026-11-18

### Added
- Product analytics integration (`8b269b3`).

### Changed
- Updated built-in model catalog/definitions (`8b269b3`).

## [1.0] - 2026-10-17

### Added
- Initial iOS 1.0 release with BYOKchat Pro plans, purchase store, paywall, and flexible onboarding (`BYOKPurchaseStore`, `BYOKOnboardingView`).
- Native OpenAI and xAI Responses support (`ae0afbf`) alongside built-in AI providers and custom provider management.
- Unified model capabilities and reasoning controls (`710d580`), compact chat composer, focused target picker, and reasoning sheet.
- Privacy-safe SQLite telemetry store (`TelemetrySQLiteStore`), analytics dashboard, conversation analytics drill-down, failure breakdowns, and diagnostics log viewer.
- Projects, Library file storage, and MCP (Model Context Protocol) tool support with always-allow permissions.
- Shared storage environment, lazy-loaded versioned conversation shards, background streaming, and title-only chat search.
- Redesigned app theme catalog (including Midnight) and custom app icon.
- Manual CI and release workflows (`b142282`, `5b01aa5`).
