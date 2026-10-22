# Live Inkribe iOS v1 handoff — 2026-10-22

Scope: current PLAN/FEATURES, 29 items, P0–P7. Old exhaustive catalog is historical. No excluded services/features.

P0 #23, P1 #24 and P2 #25 are squash merged. P2 merge: 97d647ec7a17b269ac4727dafe15db543613d801. The user requested P3 implementation next. [PR #26](https://github.com/hoangbkit/Inkribe/pull/26), branch feat/ios-p3-caption-editor, starts at that latest develop. **Leave PR #26 open for review; no merge/auto-merge until asked.**

P3 source integrates V1.TEXT, TIMING, SPLIT_MERGE, UNDO and PREVIEW: compact footage, one transport/project clock, cue overview/scrubber, caption selection/correction, cue/word timing, same-clip split/merge, session undo/redo and serialized title/caption autosave. Raw recognition/native word anchors/original media remain immutable. Schema v3 retains v1/v2 reads and adds optional manual timing; older clients reject new documents. Compilation/runtime remain unverified.

Read [handoffs/P3.md](handoffs/P3.md) for exact behavior, source review, compatibility, P4/P5 input and pending user scenarios. [handoffs/P2.md](handoffs/P2.md) remains the model placement/hash and native-transcription reference; P2's old review hold is historical. No model downloads, builds/tests/typechecks, CI, Xcode generation, deployment or device validation occurred.

Next action is source review/fixes in the P3 PR or user testing. Start P4 only on user request after P3 disposition. P4 owns fonts/styles/position/templates/motion and shared preview/export typography; P3's plain SwiftUI caption overlay is not a completed styled renderer/export path. P5 owns export/commerce; commercial policy remains undecided. Preserve Mac and the compact v1 boundaries.
