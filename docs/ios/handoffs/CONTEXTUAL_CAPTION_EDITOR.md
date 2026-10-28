# Contextual caption editor — source handoff

2026-10-28. Base develop `ba5b422e6229758d87c4c888ebf22741928af386`.
New branch `feat/ios-contextual-caption-editor` targets develop; keep its PR open
without auto-merge. Other scope requires its own confirmed plan.

2026-10-28. The user also confirmed the timeline width adjustment in #50:

- [x] Remove the shared editor container's 12-point horizontal padding; apply it
  individually to preview, playback controls, timeline header, errors and prompts.
  Timeline ruler/tracks now receive the full editor width. Preview sizing and
  the existing vertical spacing remain unchanged.
- [x] Preserve the native timeline's internal start/end scroll space, centered
  playhead, seek/pinch/timing logic and viewport-driven thumbnail/caption drawing.
- [x] Source/diff/whitespace and exact remote blob/tree publication review only;
  no builds, tests or UI/device execution. Device layout remains unverified.

- [x] Top-level Timing removed; other bottom tools and toolbar Export retained.
- [x] Second tap on a selected timeline caption opens Edit caption without another seek.
- [x] Row text taps retain selection/highlight/seek and do not push. Only the
  selected row's top-left Edit caption (former Editing caption label position)
  pushes in Captions' existing NavigationStack. Native Back/swipe-back and Done
  return to the same list without closing the sheet or seeking.
- [x] No inline text editing, Split / Words or deletion controls in the list.
  The dedicated captionTextEditor owns the text field and existing draft/edit
  binding. CaptionTranscriptRow has no focus binding or caption mutation path.
- [x] Captions root has bounded top video preview and play/pause/time/Undo/Redo,
  with no scrubber/timeline. The list scrolls independently beneath the header.
- [x] Always highlight the current playback cue with stronger fill/accent marker,
  independently of edit selection. Remove the follow toggle/state and playback
  scroll observer; retain manual scrolling and keyboard-focus accommodation.
- [x] Reuse the session player and caption renderer; hand off the video layer from
  main editor to Captions, detach on contextual push/manual authoring, restore on pop.
- [x] Full-caption correction, native words, split/merge, precise caption/word timing,
  phrase provenance and manual deletion retain the existing edit/history/save paths.
- [x] No player, scrubber, transport or duplicate inline timing in Edit caption.
  Manual phrases use one caption field and do not expose invented word controls.
- [x] From timeline entry, Done or swipe dismissal returns to the timeline,
  paused 0.25 seconds before the surviving edited caption (clamped to zero), with
  selection retained. Navigation does not dirty the document or add history.
- [x] Captured target prevents editing a replacement selection after target removal.
  Split follows the existing right-cue selection; successful manual deletion pops
  back to Captions for transcript entry or closes the standalone timeline editor.
- [x] Scope, entry points, design/architecture and source handoff updated.

Source ownership: EditorWorkspace defines primary versus contextual routes;
ProjectEditorView owns presentation, captured target, focused controls and dismissal;
CaptionTranscriptRow exposes distinct select/seek and top-left edit actions;
EditorSession.prepareCaptionPlayback only restores presentation selection/seek.

Existing output-versus-original timing conversion remains unchanged. No schema,
renderer, native recognition, speech model/allowance, queue/export, purchases, Mac,
dependency, project-generation or CI changes. Other consolidation remains deferred.

Validation is source/call-site/diff/whitespace and remote publication review only.
No builds, typechecks, tests/fixtures, CI dispatches, generation, native media/exports
or UI/device/accessibility execution were run. Compilation, native sheet/navigation,
keyboard, split/merge/retime/reopen and real playback/output acceptance remain
unverified. Source completion is not runtime acceptance.
