# Preview handoff fix

2026-10-28. User confirmed the proposed fix in a stacked PR. Start at PR #50 head
`5c9f9eb247cb6339d2c41fb05f55f721b3a4dc03`, branch fix/ios-preview-handoff, target
feat/ios-contextual-caption-editor. Keep both PRs open without auto-merge.

- Preserve a current video frame before disconnecting the covered live surface.
- Keep the covered preview mounted with a bounded still and matching caption
  snapshot/clock. Preserve geometry while sheets animate and playhead/style changes
  occur elsewhere. One player and one live layer owner; no reload or extra decoder.
- Return with the outgoing host's latest still, then expose live video only after
  AVPlayerLayer readiness. Reject callbacks from earlier handoffs/items/teardown.
- Apply the same adapter to main/Captions/fullscreen, Customize and manual authoring.
- Keep audio-only caption playback live; retain existing no-frame/source-error states.
- Preserve every #50 row/select/seek/top-left edit, push/pop, preview/control and
  no-auto-scroll behavior; preserve caption timing/history/save and immutable outputs.
- No renderer implementation, schema, shared packages, speech/model/allowance,
  queue/export/commerce, Mac, CI or further consolidation changes.

Source-only: no builds/typechecks/tests/fixtures, CI/generation/models, native media
processing/exports, UI/device/accessibility execution or deployment. Source
integration is not runtime acceptance. Other edit plans await user confirmation.
