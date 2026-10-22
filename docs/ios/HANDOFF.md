# Live Inkribe iOS v1 handoff — 2026-10-22

Scope: current PLAN/FEATURES, 29 V1 items, P0–P7. Old exhaustive catalog is historical. No excluded services/features.

P0 #23, P1 #24, P2 #25 and P3 #26 are squash merged. P3 merge: 11902e67cc74321f4ae4530e4914db4203bec95a. The user requested P4 next. [PR #27](https://github.com/hoangbkit/Inkribe/pull/27), branch feat/ios-p4-caption-styles, starts at that latest develop. **Leave PR #27 open for review; no merge/auto-merge until asked.**

P4 source integrates V1.STYLE, POSITION and PRESETS: four built-in fonts, size/text/accent/outline/background colors, normalized output position, four editable templates and timing-driven highlight/karaoke/pop/fade. The Style/Templates panels preserve the existing player/selection/clock. Style edits use the same serialized saves and bounded undo as caption edits. Schema v4 reads v1–v3, supplies defaults for missing styles and preserves styles on duplicate.

One Core Text layout/draw path serves preview, transparent sRGB bitmap output and a concrete CI frame-composition adapter. No separate SwiftUI text/animation approximation remains in the shipping preview. Render data uses edited words/timing; native anchors/raw recognition/originals are preserved. Compilation, real shaping, memory/latency and pixel output remain unverified.

Read [handoffs/P4.md](handoffs/P4.md) for exact font/template values, renderer interfaces, bounds, compatibility and remaining user scenarios. [handoffs/P3.md](handoffs/P3.md) records editor/save contracts; its old review hold is historical. [handoffs/P2.md](handoffs/P2.md) retains exact model setup/hash. No builds/typechecks/tests, CI, project regeneration, model downloads, deployment or device validation occurred.

Next action is P4 source review/fixes or user testing, not automatic P5. P5 must freeze the saved edited document, call the shared renderer, implement MP4/SRT/delivery/export jobs and resolve actual free/Pro policy/plans/prices with the user. P6 remains trim/crop/volume; no extra editor/service scope.
