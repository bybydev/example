# BYOKchat for macOS

## Status

The native macOS app is implemented on top of the shared `BYOKchatProviderCore` runtime.

Purchases, Pro entitlement, shared macOS themes, and first-party macOS app analytics are implemented with **MacAppFoundation 1.5.0**, pinned exactly in `project.yml`. The Mac app reuses the same BYOK Pro product identifiers and non-theme resource limits as iOS; StoreKit entitlement state and Mac theme access are owned by MacAppFoundation rather than duplicated in BYOKchat.

## Architecture boundary

The platform boundary is intentional:

- `BYOKmac/**` owns the native macOS app lifecycle, orchestration, navigation, views, Settings, menus, desktop interaction behavior, and app-specific Pro policy composition.
- `BYOKchat/**` remains the iOS app layer.
- `Sources/BYOKchatProviderCore/**` owns platform-neutral providers, conversations, persistence, projects, Library, MCP/tools, usage analytics, telemetry, portability, and file storage.
- `MacAppFoundation` owns reusable macOS StoreKit 2 commerce, entitlement evaluation, paywall/Plan primitives, purchase simulation, developer purchase tooling, and first-party app analytics.
- `project.yml` is the source of truth for target/package configuration.

Mac UI must not depend on the iOS app layer, and shared core should not accumulate Mac-only conditionals for view concerns.

## Product hierarchy

The primary window is conversation-first:

- compact collapsible conversation sidebar with pinned and recent conversations;
- centered transcript with a maximum readable width;
- document-style assistant responses;
- compact right-aligned user messages;
- wide, permanently expanded composer near the bottom;
- provider/model/reasoning/tool controls kept close to the composer;
- contextual message actions rather than permanent action rows;
- Projects, Library, Analytics, provider management, and MCP management presented as focused sheets from the sidebar utility grid;
- native Settings remains a separate Settings scene.

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

Full conversation shards remain lazy until selected. Analytics uses the shared `ConversationStore.allConversations()` full-corpus path and bounded local telemetry only when its surface opens, for both Free and Pro.

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

Streaming deltas are presentation-coalesced. A non-main incremental renderer freezes stable blocks and leaves one bounded mutable tail, so normal token updates do not reparse the growing response on the main actor. Syntax highlighting, Mermaid, math, and other rich enhancement are deferred until a block becomes stable. Transcript construction uses lazy message construction so completed rich messages are not rebuilt eagerly for long histories.

The transcript follows the latest response only while the reader has follow intent. User scrolling disables follow, and the jump-to-bottom control restores it without reintroducing per-token scroll commands.

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

BYOK Pro policy matches iOS: free users can create one project and save unlimited Library files. Existing projects remain accessible/editable if Pro expires; project creation beyond the free limit is blocked. Saving, importing, restoring, and reusing Library files never require Pro.

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

Tool UI remains contextual to chat and management surfaces rather than becoming permanent diagnostics chrome. Free users can create one MCP server; existing servers remain usable/editable after entitlement loss.

## Purchases and BYOK Pro

The Mac purchase layer is deliberately thin and app-owned only where product policy belongs.

`MacPurchaseStore` defines the same universal BYOK Pro catalog used by iOS:

- `com.hoangbkit.byokchat.pro.monthly`;
- `com.hoangbkit.byokchat.pro.yearly`;
- `com.hoangbkit.byokchat.pro.lifetime`.

MacAppFoundation `PurchaseManager` is the entitlement source of truth. The main scene applies `managesPurchases`, which prepares StoreKit, observes transactions, and refreshes entitlements when the app becomes active. BYOKchat does not persist its own production `hasPro` flag.

The app provides:

- a native BYOK Pro paywall window using `ProPaywallView`;
- purchase and restore through MacAppFoundation;
- a `Plan` tab in native Settings using `ProPlanPane`;
- privacy/terms/redeem-code presentation;
- Debug-only MacAppFoundation Developer Tools and simulated purchase controls.

Free/Pro resource limits mirror iOS, while macOS theme access is defined by the MAF catalog:

- GitHub Dark Dimmed and GitHub Light are Free; System and the other ten built-in MAF themes require Pro;
- 1 provider connection free, unlimited with Pro;
- 1 project free, unlimited with Pro;
- 1 MCP server free, unlimited with Pro;
- unlimited saved Library files for everyone;
- every Analytics feature free for Today; Pro unlocks 7D, 30D, Month, and All date ranges.

Creation is gated at the model boundary so every entry point observes the same rule. Existing user-created data remains accessible by default after entitlement loss.

## Analytics

BYOKchat has two intentionally separate analytics layers. User-facing usage/performance analytics remain local/shared runtime capabilities, while MacAppFoundation provides privacy-bounded first-party app telemetry for product health and commerce funnels.

The Mac app creates one `AppAnalyticsClient` with app ID `byokchat`, uses `Bundle.main.bundleIdentifier` (`com.hoangbkit.byokchat`) as the native app key, and sends to `https://analytics.133043.xyz`. The same client is shared through `.managesAnalytics(analytics)` across app scenes, so MAF lifecycle/session accounting and automatic `ProPaywallView` commerce events use one installation identity. This telemetry does not include prompts, message text, filenames, provider credentials, StoreKit receipts, transaction IDs, or arbitrary error text.

Mac failures are also reported through MAF's bounded error stream using stable snake-case codes plus low-cardinality components. Coverage includes startup/recovery, chat persistence and generation, provider/MCP/workspace mutations, attachment handling, Library/project file operations, data portability, and diagnostics/export failures. Cancellation and normal user-validation paths are not intentionally reported, and raw `Error` text is never sent.

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

Free and Pro users receive the same analytics capabilities: usage, cached/reasoning/tool totals, performance/reliability, failures, provider/model and per-conversation breakdowns, local telemetry statistics, and monthly budget controls. Free access is restricted to Today; Pro unlocks 7D, 30D, Month, and All. Every calculation clamps stale range selections after entitlement loss. Free budget evaluation uses today's usage only and explains that earlier spending is excluded.

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

The approved BYOKchat artwork in the iOS asset catalog remains the source artwork for the Mac AppIcon/Icon Composer asset.

## MacAppFoundation dependency lock

The macOS app is implemented against the exact public `MacAppFoundation` tag **1.5.0**. Do not silently move this dependency to `master` or a later tag as part of unrelated work. Upgrade it explicitly when BYOKchat intentionally adopts a newer MacAppFoundation release.
