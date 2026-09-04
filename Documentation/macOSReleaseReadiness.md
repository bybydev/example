# BYOKchat macOS Release Readiness

This is the release checklist for the currently implemented native macOS product surface.

Purchases, paywalls, and Pro entitlement are intentionally excluded until **MacAppFoundation** provides the macOS purchase/paywall layer. Do not add a temporary Mac-only StoreKit stack.

## Primary window

- Conversation-first workspace: sidebar + transcript + compact composer.
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
- Analytics performs its explicit full-corpus hydration only when the Analytics surface opens.
- Sidebar search is debounced and store-backed.
- Provider stream deltas are presentation-coalesced rather than published for every token fragment.
- Transcript construction uses `LazyVStack`.
- Auto-follow runs only while the reader is near the live tail.
- Rich Markdown/code/math/Mermaid rendering remains transcript-local and avoids token-by-token animation.
- Attachment import enforces count/byte limits while loading and bounds normalized image dimensions.

## Analytics

- Today, 7D, 30D, Month, and All ranges use the shared `UsageAnalytics` filtering model.
- Spend/request/token/tool totals are reconstructed from persisted assistant messages.
- TTFT, duration, speed, reliability, failures, provider/model breakdowns, and per-conversation performance use shared local telemetry.
- Clearing telemetry does not erase message-history usage/spend.
- Monthly budget warnings remain local advisory thresholds only.
- Pro/free analytics gating is intentionally deferred with MacAppFoundation; do not add a second entitlement implementation around this surface.

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

Provider and MCP credentials remain in Keychain. Backup/configuration exports exclude secrets.

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
8. Analytics ranges → provider/model breakdowns → per-conversation analytics → monthly budget warning;
9. stop, retry/regenerate, edit-and-resend, interrupted-response recovery;
10. single conversation deletion and bulk conversation deletion;
11. full backup export/import and merge/replace restore;
12. credential deletion and safe full reset/recovery-folder reveal;
13. keyboard-only navigation and VoiceOver/Reduce Motion pass.

Purchase/entitlement regression is deferred with MacAppFoundation.
