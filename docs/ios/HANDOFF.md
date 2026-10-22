# Live Inkribe iOS v1 handoff — 2026-10-22

Scope: current PLAN/FEATURES, 29 items, P0–P7. Old exhaustive catalog is historical. No excluded services/features.

P0 #23 and P1 #24 are squash merged. P1 merge: 97d364502daa53b7838904fc8d80652bf1012b15. Its autosave/URL-cap fixes are included. P2 is source-integrated in [PR #25](https://github.com/hoangbkit/Inkribe/pull/25), branch feat/ios-p2-local-transcription from that develop SHA. **Leave #25 open, no merge/auto-merge.**

P2 integrates local Whisper/language selection, <=28-second PCM windows, actual token-to-word timing, JobQueue progress/cancel/retry/recovery, atomic schema-v2 raw/word/cue results, v1 reads, duplicate remapping and a read-only result UI. All four P2 V1 items are source-integrated, not compiled/runtime-verified. P3–P7 have not started.

Read [handoffs/P2.md](handoffs/P2.md) for model placement/hash, code contracts, source findings and exact pending user scenarios. No model downloads, builds/tests/typechecks, CI, Xcode generation, deployment or device validation. Native iOS linking and real accuracy/performance remain unverified. No Qwen/diarization/cloud engine added; Mac default behavior preserved through opt-in shared additions.

Next action is source review/fixes in #25 or user testing, not automatic P3 implementation. Start P3 only on request from latest develop after appropriate P2 disposition. Preserve raw recognition and latest title drafts; honor current UI approval/merge instructions.
