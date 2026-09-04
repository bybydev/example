# BYOKchat for macOS

## Status

The native macOS app is implemented on top of the shared `BYOKchatProviderCore` runtime.

Purchases, paywalls, and Pro entitlement are intentionally deferred until **MacAppFoundation** provides the macOS purchase/paywall layer. Do not add a temporary Mac-only StoreKit entitlement stack in the meantime.

## Architecture boundary

The platform boundary is intentional:

- `BYOKmac/**` owns the native macOS app lifecycle, orchestration, navigation, views, Settings, menus, and desktop interaction behavior.
- `BYOKchat/**` remains the iOS app layer.
- `Sources/BYOKchatProviderCore/**` owns platform-neutral providers, conversations, persistence, projects, Library, MCP/tools, usage analytics, telemetry, portability, and file storage.
- `project.yml` is the source of truth for target/package configuration.

Mac UI must not depend on the iOS app layer, and shared core should not accumulate Mac-only conditionals for view concerns.

## Product hierarchy

The primary window is conversation-first:

- compact collapsible conversation sidebar with pinned and recent conversations;
- centered transcript with a maximum readable width;
- document-style assistant responses;
- compact right-aligned user messages;
- floating composer near the bottom;
- provider/model/reasoning/tool controls kept close to the composer;
- contextual message actions rather than permanent action rows;
- Projects, Library, Analytics, provider management, MCP management, data management, and diagnostics presented as focused secondary surfaces.

The current `chat.byok.pro` desktop implementation remains the visual reference when evolving the main chat experience, with native Mac conventions taking precedence where browser interaction does not translate directly.

## Runtime composition

`MacAppModel` composes the secure shared `BYOKCoreServices` graph and owns only Mac-level lifecycle state.

Startup prepares and loads, in order:

1. storage and file metadata;
2. providers/connections;
3. projects;
4. MCP/tool state;
5. conversation index summaries;
6. Library state;
7. project/conversation reconciliation and orphan-file cleanup;
8. telemetry maintenance and diagnostics surfaces.

Full conversation shards remain lazy until selected. Analytics intentionally uses the shared `ConversationStore.allConversations()` full-corpus path only when the Analytics surface opens, so normal startup and sidebar browsing stay index-backed.

Startup recovery can move a damaged workspace aside and start fresh while keeping the previous workspace discoverable in Finder. Full reset uses the stronger data-management path that also handles credentials and telemetry cleanup.

## Providers and chat

The Mac app reuses the shared provider registry/workspace/account manager/runtime and supports:

- built-in providers;
- OpenAI-compatible/self-hosted endpoints;
- Keychain-backed credentials;
- endpoint overrides, custom paths, auth modes, headers, and OpenRouter metadata;
- model discovery/manual models, favorites, hidden models, and defaults;
- per-conversation provider/account/model affinity;
- reasoning effort where supported.

`MacChatSessionModel` owns the Mac presentation state around `ConversationStore` and `ChatRuntime`:

- index-backed conversation summaries;
- lazy hydration;
- debounced drafts;
- create/select/rename/delete/search;
- pinned/recent presentation state;
- send/edit/regenerate/stop;
- interrupted-response recovery;
- coalesced streaming presentation;
- live tool-call state.

New chats are virtual until the first send. Project-created chats stage their project, initial prompt, and provider/model defaults before that first send.

## Rich responses

The transcript supports:

- streaming-safe Markdown;
- syntax-highlighted fenced code;
- math;
- Mermaid;
- collapsible Markdown reasoning;
- copy/share/export/edit/retry/regenerate/details actions;
- persisted tool rounds/results;
- selectable text and native links.

Streaming deltas are presentation-coalesced and the transcript uses lazy message construction so completed rich messages are not rebuilt eagerly for long histories.

## Attachments

Native input supports Files picker, Finder drag/drop, clipboard images/files, Project files, and Library items.

Limits are enforced before or during import:

- maximum 8 attachments per message;
- maximum 20 MB per attachment;
- maximum 40 MB combined;
- imported images are auto-oriented and normalized to JPEG with a bounded 4096-pixel maximum dimension.

Pending attachments are retained per conversation until their IDs are observed in persisted message history, preventing pre-turn send failures from silently losing selected files.

## Projects and Library

Projects support:

- instructions;
- provider/model defaults;
- reference files;
- conversation membership;
- reusable prompt presets;
- MCP/tool defaults and tool presets.

Project instructions become the new chat system prompt, falling back to the app default system prompt when empty.

Library uses the shared blob store and supports browsing, previewing, importing, exporting, sharing, renaming, deleting, attaching items to chat, and saving chat responses/attachments back to Library without unnecessary blob duplication.

## MCP and tools

The Mac app uses the shared MCP runtime, workspace, approval center, and elicitation center.

Supported desktop workflows include:

- MCP server configuration and discovery;
- Keychain credentials;
- project tool defaults;
- per-chat inheritance and overrides;
- per-tool permission policy;
- approvals, including persistent Always Allow;
- structured and URL elicitation;
- live tool-call state;
- persisted tool call/result/error inspection.

Tool UI remains contextual to chat and management surfaces rather than becoming permanent diagnostics chrome.

## Analytics

Usage and performance analytics are shared runtime capabilities rather than a Mac-specific implementation.

`ChatBilling`, `TelemetryAnalytics`, and the shared `UsageAnalytics` presentation model provide:

- time ranges: Today, 7D, 30D, Month, and All;
- spend reconstruction from provider-reported or model-price metadata;
- model request, input/output, cached-input, reasoning-token, and tool-call totals;
- median/P95 time-to-first-token and request duration;
- median output-token speed;
- provider, tool, and MCP reliability;
- privacy-safe failure breakdowns;
- provider and model breakdowns;
- per-conversation usage/performance snapshots.

The native Mac Analytics surface adds a desktop overview, conversation sidebar, local telemetry statistics, refresh, and monthly budget/warning preferences. Usage/spend come from persisted message history, while performance/reliability come from bounded local telemetry.

Purchase-based analytics gating is intentionally not duplicated in the Mac app while MacAppFoundation is pending. When that layer arrives, apply the same iOS free/Pro policy to this existing Analytics surface rather than changing the analytics runtime.

## Data and diagnostics

Data management reuses the shared portability formats:

- full backup export/import;
- merge or replace restore;
- provider configuration export/import;
- delete all conversations;
- delete provider/MCP credentials;
- safe full reset with bounded recovery copies.

Secrets are not included in configuration/backup exports unless a future explicitly designed format changes that contract.

Diagnostics expose local telemetry health, storage/retention, maintenance/retry, filtering, event details, sanitized JSON export, and clear operations through the shared fail-open telemetry recorder.

## Native Mac contract

Key desktop behavior:

- Command-N: New Chat;
- Command-K: Search Conversations;
- Command-Period: stop active generation;
- Command-Comma: native Settings;
- Return: send;
- Shift-Return: newline;
- Escape: normal sheet/dialog dismissal;
- native context menus, text selection, drag/drop, paste, file panels, ShareLink, focus, and Sidebar commands;
- explicit animations honor Reduce Motion;
- primary controls expose VoiceOver labels/hints/values where native labels are insufficient.

## Sandboxing and metadata

The macOS target uses:

- App Sandbox;
- Hardened Runtime;
- outbound network client access;
- no incoming network entitlement;
- user-selected file read/write access;
- no unused camera/microphone/contacts/calendar/location/Bluetooth/printing/USB access;
- explicit local-network usage disclosure;
- ATS local-network allowance for explicitly configured private-network HTTP endpoints;
- `ITSAppUsesNonExemptEncryption = false`, matching iOS.

Current release identity remains:

- display name: BYOKchat;
- category: Productivity;
- bundle ID: `com.hoangbkit.byokchat`;
- deployment target: macOS 15.0;
- marketing version: 0.1 until intentionally promoted.

The approved BYOKchat artwork in the iOS asset catalog remains the source artwork for the eventual Mac AppIcon/Icon Composer asset.

## Deferred purchase layer

When MacAppFoundation is ready, add purchases as one cross-platform entitlement/business-rule layer using the existing product IDs and universal-purchase model. At that point add Mac purchase, restore, paywall, and Pro gating without changing the native Mac architecture above.
