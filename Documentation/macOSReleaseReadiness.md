# BYOKchat macOS Release Readiness

This is the release checklist for the currently implemented native macOS product surface.

Purchases, paywalls, Pro entitlement, shared themes, restore, Plan settings, Debug purchase tooling, and first-party app analytics are provided by **MacAppFoundation 1.5.0**, pinned exactly in `project.yml`. The Mac app uses the same BYOK Pro product identifiers and non-theme resource limits as iOS; it does not maintain a second entitlement or theme-access store.

## Primary window

- Conversation-first workspace: sidebar + transcript + expanded desktop composer.
- Default size: 1180 × 760; minimum content size: 760 × 520.
- Sidebar uses native Sidebar commands/collapse behavior and separates pinned/recent conversations.
- Main scene identity remains `main`.
- No permanent dashboard or inspector chrome without a concrete workflow need.

## Keyboard

- Command-N: New Chat.
- Command-K: Search Conversations.
- Command-Period: stop active generation.
- Command-Comma: Settings.
- Return: send when available.
- Shift-Return: newline.
- Escape: normal sheet/dialog dismissal.

## Accessibility

- Conversation title is exposed as a header.
- Composer, send/stop, provider/model, tools, attachments, conversation actions, and jump-to-latest have explicit accessibility semantics where needed.
- Analytics metric cards expose combined labels/values instead of forcing VoiceOver through decorative children.
- Decorative empty-state artwork is hidden from accessibility.
- Explicit sidebar/transcript animations honor Reduce Motion.
- Response text remains selectable.
- Secondary surfaces use native Form/List/NavigationSplitView controls for system keyboard and VoiceOver behavior.

## Performance

- Startup loads conversation summaries before full shards.
- Full conversations remain lazy until selected.
- Free Analytics hydrates persisted conversation history only; Pro Analytics also loads bounded local telemetry when its surface opens.
- Sidebar search is debounced and store-backed.
- Provider stream deltas are presentation-coalesced rather than published for every token fragment.
- Transcript construction uses `LazyVStack`.
- Auto-follow runs only while the reader intends to follow the live tail.
- Streaming Markdown is split into immutable stable blocks plus one cheap mutable tail; rich code/math/Mermaid enhancement is deferred until blocks become stable.
- Attachment import enforces count/byte limits while loading and bounds normalized image dimensions.

## Purchases and BYOK Pro

- `MacAppFoundation` is pinned to exact tag `1.5.0`.
- macOS and iOS use the same product IDs: monthly, yearly, and lifetime BYOK Pro.
- `PurchaseManager` is the production entitlement source of truth and is prepared/refreshed through `managesPurchases`.
- The app owns the BYOK Pro paywall window and Plan settings tab while MacAppFoundation owns StoreKit purchase/restore behavior.
- Free theme access is MAF-owned: GitHub Dark Dimmed and GitHub Light are Free; System and the other ten built-in themes require Pro.
- Other Free limits match iOS: 1 provider connection, 1 project, 1 MCP server, and 10 saved Library files.
- Existing provider connections, projects, MCP servers, and Library files remain accessible/editable after entitlement loss; creation beyond the free limits is gated.
- Advanced Analytics is Pro; free users retain basic monthly spend/request/input/output analytics.
- Debug builds expose MacAppFoundation purchase simulation and Developer Tools without replacing Release StoreKit behavior.

## Analytics

- Product telemetry uses one MAF `AppAnalyticsClient` with app ID `byokchat`, app key `com.hoangbkit.byokchat` from the runtime bundle identifier, and `https://analytics.133043.xyz` as the server.
- `.managesAnalytics(analytics)` is attached to the Mac scenes, including the Pro paywall, so lifecycle/session telemetry and bounded MAF commerce-funnel events share the same client.
- Product telemetry remains separate from BYOKchat's user-facing local usage analytics and must not include prompts, message text, filenames, credentials, receipts, transaction IDs, or arbitrary error text.
- App failures use MAF `trackError` with stable error codes/components across startup, chat, provider/MCP/workspace, attachments, Library/projects, data portability, and export/diagnostic boundaries; raw `Error` descriptions are never uploaded.
- Free: Month only, with spend, model requests, input tokens, and output tokens reconstructed from persisted messages.
- Pro: Today, 7D, 30D, Month, and All ranges through the shared `UsageAnalytics` filtering model.
- Pro adds cached/reasoning/tool totals, TTFT, duration, speed, reliability, failures, provider/model breakdowns, per-conversation analytics, local telemetry statistics, and monthly budgets.
- Clearing telemetry does not erase message-history usage/spend.
- Monthly budget warnings remain local advisory thresholds only.

## Sandboxing and privacy

The Mac target is configured for:

- App Sandbox;
- Hardened Runtime;
- outbound network client access;
- no incoming network entitlement;
- user-selected file read/write access;
- camera, microphone, contacts, calendars, location, Bluetooth, printing, and USB disabled;
- local-network usage disclosure for configured LAN providers and MCP servers;
- ATS local-network allowance for explicitly configured private-network HTTP endpoints;
- `ITSAppUsesNonExemptEncryption = false`.

Provider and MCP credentials remain in Keychain. Backup/configuration exports exclude secrets. StoreKit entitlements are verified by MacAppFoundation rather than persisted as an app-owned `hasPro` flag.

## Metadata

- Display name: BYOKchat.
- Category: Productivity.
- Deployment target: macOS 15.0.
- Bundle identifier: `com.hoangbkit.byokchat`.
- Marketing version: 0.1 until intentionally promoted.

## App icon handoff

Use the approved BYOKchat source artwork at `BYOKchat/Resources/AppIcon.icon/Assets/AppIcon-1024.png` as the source for the shared iOS and macOS AppIcon/Icon Composer asset. Do not invent a separate Mac brand identity.

## Regression surface

Exercise these workflows together before distribution because they cross the most state boundaries:

1. first launch → provider setup → first streamed chat;
2. pin/unpin conversations and verify pinned/recent ordering survives relaunch;
3. long Markdown/code/math/Mermaid response while switching conversations;
4. attachment picker, Finder drop, clipboard paste, and oversized/multi-file rejection;
5. project defaults/reference files → new project chat;
6. Library attach/save/export;
7. MCP discovery → chat tool enablement → approval/elicitation → persisted tool result;
8. free Analytics monthly summary → Pro upgrade → advanced ranges/breakdowns/budget;
9. stop, retry/regenerate, edit-and-resend, interrupted-response recovery;
10. single conversation deletion and bulk conversation deletion;
11. full backup export/import and merge/replace restore;
12. credential deletion and safe full reset/recovery-folder reveal;
13. free limits for theme/provider/project/MCP/Library creation, then simulated Pro unlock;
14. purchase, restore, lifetime/subscription entitlement refresh, and foreground refresh;
15. keyboard-only navigation and VoiceOver/Reduce Motion pass.
