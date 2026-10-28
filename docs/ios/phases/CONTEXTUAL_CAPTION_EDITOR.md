# Contextual caption editor

2026-10-28. User-authorized single feature in a new PR from develop `ba5b422`,
targeting develop, left open without auto-merge. V1.TEXT, V1.TIMING, V1.SPLIT_MERGE,
V1.UNDO and EDITOR.CONTEXTUAL_CAPTION. No other consolidation is authorized.

- Latest user correction: Captions has a bounded video preview above the list,
  play/pause/time readout and Undo/Redo, with no scrubber/timeline. Always highlight
  the current playback row without selecting it or automatically scrolling.
  Remove the optional follow toggle. The list remains manually scrollable.
  Reuse the sole player/renderer with covered-layer handoff on sheet/push/pop.
- Remove the top-level Timing action. Retain Clips, Captions, Styles, Media and Customize.
- Timeline first tap selects a caption; second tap opens Edit caption without seeking again.
- Row text taps select/highlight/seek, without pushing. The selected row's top-left
  Edit caption button, in the former Editing caption label position, pushes in
  Captions' existing navigation stack. No inline text editing or Split / Words.
  Back/swipe-back/Done returns to the same
  transcript and scroll context; no second sheet or seek on pop.
- Keep full-caption text, native word correction, split/merge, expandable precise
  caption/word timing, honest phrase provenance and manual deletion. Avoid duplicate
  caption timing and duplicate manual phrase fields.
- No player, scrubber, overview or transport in Edit caption. The user checks the
  result after returning through the list or directly to the main timeline,
  depending on entry. Keep other inspectors unchanged.
- From timeline entry, Done or swipe dismissal closes the sheet and restores the edited
  caption's selection. Seek 0.25 seconds before its retained-clock start, clamped
  to zero. Do not autoplay or change canonical time values for navigation.
- Successful manual deletion returns to the list for transcript entry, or closes
  the standalone editor for timeline entry. The list has no text field/focus binding;
  only the dedicated editor owns caption text editing.
- Preserve native/manual IDs, word timing semantics, hidden trim portions, history,
  atomic autosave, transcription/allowance, export snapshots and all Mac behavior.
- Keep Styles/Customize, Media, reset scope and displayed-clock consolidation deferred.

Source-only: no builds/typechecks/tests/fixtures, CI setup/runs, generation/models,
native processing/exports, UI/device/accessibility execution or deployment.
