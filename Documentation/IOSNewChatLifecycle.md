# iOS new-chat lifecycle

Issue #38 replaces standalone pre-send configuration staging with real
conversation-backed editing. Project chats retain their push/back navigation.

## Identity and visibility

- `ChatManagementModel.newChat(projectID:)` coalesces creation requests and
  reuses the active unsent conversation in the same scope.
- Each new logical session receives a new UUID. First send uses the same UUID.
- `isIOSNewChat` is an optional ownership marker written with the initial shard
  and included in the lightweight index. Existing records decode with nil;
  macOS creation defaults remain unchanged.
- `historyConversations` is the iOS history predicate. Managed chats enter
  history only once the committed index contains a user message. Sidebar
  Recent/Pinned/search, project lists, and project counts use this predicate.
- Selecting, renaming, typing, attaching files, or changing configuration does
  not expose an empty row. A saved user message survives provider errors/stops.
- The top-right menu uses the same history predicate: unsent chats expose
  Chat Settings, Tools, and applicable project settings/prompts.
  Usage, Rename, Export Markdown, and Delete appear after a saved user message.
- App Settings is accessed from the sidebar, not a chat's top-right menu.

## Configuration and first send

Both unsent and sent conversations use the same Tools, target, prompt, and draft
paths. Configuration operations register with the chat lifecycle coordinator.
Send is unavailable during a pending write or after a failed setting until that
setting is retried successfully. MCP writes are serialized in invocation order.

The composer retains its text and attachment bytes until user-message
persistence is confirmed. Debounced draft work is drained before send
preparation; edits made during preparation are buffered. Failure restores the
authoritative shard before draft saves/retry, preventing an unsaved cached user
message from becoming durable through an unrelated draft write.

## Abandonment and recovery

Explicit navigation/session changes abandon an owned unsent session. Opening
the sidebar or a sheet, foregrounding/backgrounding, and view disappearance
alone do not discard it. Navigation request revisions reject stale creation
results; same-scope duplicate requests share the result without duplicate pushes.

Cleanup reserves the ID before awaiting, refuses new writes/sends to it, drains
draft work, and waits for configuration/generation to settle. Eligibility is
checked against the persisted shard. A durable user message always protects the
conversation. Cleanup removes MCP/project references first and the owning shard
last, retaining durable ownership until companion cleanup succeeds. Partial
failures remain hidden and retry on foreground or the next launch.

Startup recovery runs after stores load, before reconciliation/file sweeping,
and only examines records explicitly owned by this iOS lifecycle. It does not
delete every empty conversation or remove shared library/project file blobs.

## Review scenarios

1. Open standalone/project New Chat, edit Tools/model, and inspect sidebar:
   no empty history row; first send uses the same conversation.
2. Tap New Chat repeatedly, including while creation is pending: one active
   unsent ID and one destination, with existing draft/settings preserved.
3. Navigate elsewhere during creation or back from a project draft: no stale
   navigation and no eligible owned leftovers after cleanup.
4. Open/close Tools, Settings, and the sidebar; background/foreground: same ID.
5. Force a first-send persistence failure: retain composer text/attachments;
   retry must not duplicate an unsaved cached message.
6. Fail the provider after user-message persistence or stop the turn: preserve
   history. Navigate during first-send preparation: cleanup cannot delete it.
7. Terminate with an unsent chat, or between shard and index persistence:
   relaunch removes only eligible owned drafts and preserves saved messages.
8. Fail cleanup midway: retry companion cleanup before deleting the owner.
9. Start without a usable provider/model: connection setup remains available
   and creates at most one conversation once ready.

Tests/builds/CI were not run during implementation; these are review scenarios,
not executed results. The separate explicit-empty MCP inheritance bug is outside
this change.
