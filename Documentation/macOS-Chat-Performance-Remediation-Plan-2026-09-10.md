# macOS Chat Performance Remediation Plan

Date: 2026-09-10

Base: `docs/ios-macos-development-review-2026-09-08` (PR #21)

Goal: make the macOS chat architecture follow the same performance principles as the known-smooth iOS implementation: isolate rapid live updates, lazily materialize history, keep composer edits local, and prevent completed rich messages from redoing work because unrelated state changed.

This plan contains only work that can be implemented and reviewed in the repository. Device-only profiling, Instruments sessions, manual performance acceptance, and hardware-specific benchmarking are intentionally excluded.

## Performance contract

The implementation should enforce these structural invariants:

- Streaming updates only the active response path plus the minimum scroll-follow state required for the visible transcript.
- The root shell, sidebar, completed message rows, and unrelated conversations do not depend on stream-presentation revisions.
- No storage/bookkeeping operation is triggered from a high-frequency presentation revision.
- Typing in the composer does not rewrite hydrated conversation/message state per keystroke.
- Historical message rows are lazily materialized.
- Source-message navigation does not require transcript-wide scroll-target layout.
- Completed rich content has stable identity and does not reparse because an unrelated row streams or the draft changes.
- Stream-presentation tasks remain bounded and are cancelled/removed when no longer needed.

## Reference architecture

The iOS chat path is the primary internal reference because it is already smooth in production-style use:

- `ScrollViewReader` + `LazyVStack` for message history;
- local draft state with separate persistence synchronization;
- 50 ms stream-presentation coalescing;
- targeted `scrollTo` for message navigation;
- no root-shell dependency on `streamRevisions`.

The Mac implementation should reuse those principles without forcing identical UI structure where macOS-specific behavior requires otherwise.

## Phase 1 — Remove stream-driven shell work

### Problem

`MacShellView` observes global `chats.streamRevisions` and uses that presentation signal to perform pending-attachment cleanup. A presentation revision is a high-frequency UI event and must not drive storage bookkeeping or root-shell work.

### Implementation

- Remove `.onChange(of: chats.streamRevisions)` from `MacShellView`.
- Move pending-attachment cleanup to a precise one-shot lifecycle transition tied to successful persistence of the sent user turn.
- Add a model-level signal/result for persisted sent attachments if the existing send lifecycle does not expose a sufficiently precise transition.
- Ensure cleanup is idempotent and runs at most once for a sent attachment set.
- Preserve pending attachments when send/persistence fails before the user turn is committed.
- Ensure background generation in another conversation cannot trigger selected-shell cleanup.
- Do not introduce polling or unstructured main-actor tasks driven by stream presentation.

### Repository validation

- Unit-test successful sent-attachment cleanup.
- Unit-test failure retention.
- Unit-test idempotent repeated persistence notification.
- Unit-test that advancing stream revisions alone does not clear pending attachments.

### Completion criteria

- `MacShellView` contains no dependency on stream-presentation revisions.
- Attachment cleanup is event-driven from persistence state only.

## Phase 2 — Align Mac streaming cadence and observation scope with iOS

### Problem

Mac currently presents stream updates more aggressively than iOS and rapid live state must remain scoped to the active response row.

### Implementation

- Align Mac stream-presentation coalescing to the iOS 50 ms interval.
- Preserve immediate flush at completion, cancellation, failure, and tool-round boundaries.
- Audit the observation boundaries in:
  - `MacChatPaneView`;
  - `MacRichMessageView`;
  - `MacLiveMessagePresentation`;
  - `MacStreamingRenderedContentView`;
  - shell/composer containers.
- Keep `MacLiveMessagePresentation` as the observable object for mutable live response state.
- Ensure completed rows consume immutable stored messages rather than broad live dictionaries/revisions.
- Ensure unrelated conversations cannot invalidate the active transcript through a global stream dictionary observation.
- Preserve `MacStreamingAnswerRenderer` as the off-main-actor incremental parsing actor.
- Keep at most one pending presentation task per live message and cancel/remove it on terminal lifecycle transitions.

### Repository validation

- Unit-test stream coalescing behavior at the bounded cadence.
- Unit-test immediate terminal flush.
- Unit-test stale/pending presentation task cleanup.
- Unit-test independent simultaneous conversation revisions where practical at model level.

### Completion criteria

- High-frequency mutable state is owned by the live row path.
- The shell and historical rows do not observe global streaming cadence.

## Phase 3 — Restore lazy transcript rendering and targeted scrolling

### Problem

The Mac transcript eagerly materializes all rich message rows using `VStack`. It also relies on transcript-wide scroll-target layout for exact source-message navigation. The iOS implementation already demonstrates a better architecture using `LazyVStack` and `ScrollViewReader`.

### Implementation

- Replace the eager transcript message `VStack` with `LazyVStack`.
- Wrap transcript navigation with `ScrollViewReader`.
- Give each message a stable explicit ID.
- Use `proxy.scrollTo(messageID, anchor: .center)` for source-message navigation.
- Use a dedicated bottom sentinel ID for follow-latest behavior.
- Remove transcript-wide `.scrollTargetLayout()` when no longer required.
- Remove persistent scroll-position machinery that exists only to support transcript-wide target layout if `ScrollViewReader` fully replaces it.
- Port the iOS follow-latest state machine where appropriate:
  - follow while already near the bottom;
  - stop following after deliberate user scrolling;
  - resume when user requests latest;
  - do not animate every streaming height change.
- Address the historical Mac lazy-stack blanking issue structurally rather than falling back to eager materialization:
  - stable row IDs;
  - targeted bottom sentinel;
  - no conflicting simultaneous scroll-position systems;
  - deterministic conversation-change initialization.

### Repository validation

- Add view/model helper tests for source-target selection and follow-state transitions where logic can be extracted from SwiftUI.
- Add tests ensuring the requested source message ID is retained until navigation can consume it.
- Add tests for conversation switching/reset of follow state.

### Completion criteria

- Historical rows are represented by `LazyVStack`.
- Exact source navigation uses targeted `scrollTo`.
- `.scrollTargetLayout()` is not required across the full transcript.

## Phase 4 — Isolate composer draft state from hydrated conversation state

### Problem

The Mac composer currently writes through `MacChatSessionModel.setDraft` while typing. That path mutates chat-model state associated with hydrated conversations and can propagate invalidations into transcript consumers even though message history has not changed.

### Implementation

- Keep the active editor string as local `@State` in the composer/chat pane, following the iOS pattern.
- Restore the draft once when conversation identity changes.
- Synchronize local draft to `MacChatSessionModel` through a debounced persistence API.
- Separate persisted draft values from hydrated message arrays so draft mutation does not rewrite a `ChatConversation` merely to update `draftText`.
- Preserve fresh-chat draft behavior.
- Preserve per-conversation drafts while switching chats.
- Preserve revision-safe/cancellable debounced store writes.
- Flush or otherwise safely finalize a pending draft write at lifecycle boundaries that already require persistence correctness.

### Repository validation

- Unit-test per-conversation draft independence.
- Unit-test debounce cancellation/replacement.
- Unit-test fresh-chat draft independence.
- Unit-test restored draft after model reload.
- Unit-test that changing a draft does not alter stored message history or message identities.

### Completion criteria

- Keystrokes mutate local composer state first.
- Draft persistence does not rewrite hydrated message history.

## Phase 5 — Freeze completed rich-message work

### Problem

Completed assistant rows can contain MarkdownUI, code highlighting, LaTeX, Mermaid, attachments, context menus, and selection state. Once a message is final, unrelated model changes should not cause its expensive content parsing/render preparation to execute again.

### Implementation

- Introduce a stable completed-message content boundary keyed by message identity plus immutable final content inputs.
- Use `Equatable` view boundaries for completed message content where equality is well-defined.
- Separate live-response rendering from completed-response rendering explicitly instead of making historical rows inspect mutable global chat state.
- Cache top-level `MacAnswerContentParser.parse` output for completed content with a bounded cache keyed by stable message/content identity, or move parsed completed blocks into a stable presentation object owned outside repeated body evaluation.
- Invalidate cached structural parse data only when the source content actually changes.
- Keep visual environment values such as theme outside structural parse caching so theme changes still restyle correctly.
- Keep MarkdownUI as the authoritative Markdown/table parser.
- Preserve the existing asynchronous code highlighting and incremental streaming renderer architecture.
- Avoid caching SwiftUI views themselves.

### Repository validation

- Unit-test completed-content cache hit/miss/invalidation behavior.
- Unit-test identical content does not reparse.
- Unit-test changed content invalidates structural parse data.
- Unit-test bounded cache eviction if a cache is introduced.
- Keep existing Markdown/code/math/Mermaid parser correctness tests green.

### Completion criteria

- Completed message structural parsing is keyed to content changes, not unrelated observable-state changes.
- Live and completed rendering paths have explicit observation boundaries.

## Phase 6 — Remove remaining avoidable derived work from hot view bodies

### Problem

After the primary architecture is corrected, secondary derived work should not be repeatedly recomputed in frequently invalidated views. Current candidates include sidebar pin-set construction, repeated conversation sorting, repeated project lookup, and composer model/tool derivations.

### Implementation

- Audit computed properties in shell, sidebar, transcript, and composer for repeated O(n) transforms performed from `body`.
- Move stable derived collections to narrow presentation helpers/models when their inputs change infrequently.
- Avoid reconstructing identical Sets/dictionaries/sorted arrays several times in one render pass.
- Ensure sidebar rows depend on conversation-summary/project changes, not chat streaming state.
- Precompute or memoize provider/model lookup inputs used by the composer when their source collections have not changed.
- Do not add caching where the cost is trivial or correctness becomes harder to reason about.

### Repository validation

- Add unit tests for any extracted derivation helper.
- Confirm no new broad observation dependencies are introduced.
- Keep sidebar search, pinning, project assignment, model selection, and tool counts behavior unchanged.

### Completion criteria

- Frequently updated chat views contain no obvious repeated full-history/full-sidebar transforms unrelated to the change being rendered.

## Phase 7 — Source-level regression hardening

This phase replaces device-only acceptance work with checks that can be encoded in the repository.

### Implementation

- Add focused regression tests for the architecture established in Phases 1–6.
- Add debug-only assertions where useful for bounded streaming tasks and invalid lifecycle state.
- Keep/add lightweight `os_signpost` events only where they have negligible runtime cost and are useful for future diagnosis; do not make external Instruments profiling a completion requirement.
- Document the final Mac performance architecture and its invariants in this file or the existing macOS handoff document.
- Update stale comments that still justify eager history or global scroll targeting after those mechanisms are removed.

### Required regression coverage

- stream revisions cannot trigger shell attachment cleanup;
- terminal stream events cancel/remove presentation tasks;
- only one pending presentation task exists per live message;
- draft persistence remains revision-safe;
- source-message navigation state survives async conversation hydration;
- conversation switching resets the appropriate local scroll/composer state;
- completed parse caching invalidates only on content change;
- existing rich-content parser/render unit tests remain green.

### Completion criteria

- Performance-sensitive behavior has automated regression coverage where it can be expressed without UI-device timing assertions.
- Documentation matches the implemented architecture.

## Explicitly deferred from this PR

The following are intentionally not phases because they require device/runtime measurement or are not yet justified by source architecture:

- manual Instruments profiling;
- FPS/CPU/memory acceptance thresholds measured on a Mac;
- manual resize/minimize/full-screen smoothness testing;
- subjective typing/scrolling smoothness acceptance;
- 100/250/500-message hardware benchmarks;
- history pagination/windowing based only on speculation;
- device-only leak hunting after repeated long sessions.

If long-history pressure remains after this implementation is merged, history windowing/pagination should be considered in a separate follow-up backed by runtime evidence.

## Files expected to change

Primary candidates:

- `BYOKmac/App/MacShellView.swift`
- `BYOKmac/App/MacChatPaneView.swift`
- `BYOKmac/App/MacChatSessionModel.swift`
- `BYOKmac/App/MacRichMessageView.swift`
- `BYOKmac/App/MacLiveMessagePresentation.swift`
- `BYOKmac/App/MacStreamingRenderedContentView.swift`
- focused files under `Tests/BYOKmacTests`
- documentation comments/handoff affected by the final architecture

Do not alter unrelated iOS behavior merely to make the Mac implementation symmetrical.

## Explicit non-goals

- no custom Markdown table parser;
- no table redesign beyond the accepted MarkdownUI styling;
- no provider/MCP/business-model changes;
- no App Store/release metadata work;
- no multi-main-window architecture work;
- no speculative rewrite of `MacStreamingAnswerRenderer`;
- no history pagination/windowing without separate runtime evidence.

## Implementation rule

Each phase should be implemented in its own focused commit or small commit series and covered by source-level/unit/CI validation before moving to the next phase. Device-only testing is outside this plan and is not a blocker for completing the repository work in this PR.
