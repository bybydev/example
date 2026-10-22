# Inkribe iOS v1 architecture

Current scope is PLAN/FEATURES. This replaces the broad product architecture. No account/provider/backend layer is needed.

## Ownership

Independent InkribeMac and Inkribe targets; preserve Mac product/module IDs, purchases, entitlements, storage and behavior. iOS owns navigation, AppFoundation, caption projects/editor/export policy. Reuse portable audio/runtime/subtitle code where useful. No new shared package without a real consumer.

One repository actor owns project truth; one editor session owns open document, playback/selection/undo. JobQueue owns work lifecycle, not editable content. A serialized local recognition runtime runs off MainActor. No cloud fallback or speculative provider adapters.

## Persistence and edits

Versioned documents, stable UUIDs/revisions, validated relative paths, app-owned immutable originals, staged adoption, atomic writes and prior-valid recovery. Preserve valid data on errors/future schemas. Separate required assets from reproducible caches/temporary output. Cleanup/deletion must respect duplicates and jobs.

Raw recognition and edited captions stay distinct. Persist stable words/cues, genuine intervals and provenance. Async results apply only to expected project/session/revision. Older saves must not overwrite newer typing. UI playback/selection does not dirty content. No persisted AVPlayer, native handles/tasks/security scopes.

## Time and local recognition

Rational media time, half-open intervals, explicit source/output mapping. Honor orientation, VFR and audio offsets. P6 trim clips caption boundaries and maps output timing consistently.

P2 selects compatible local model/packaging from source evidence. Bounded decode/windowed inference, absolute offsets and overlap reconciliation throughout; no whole-file PCM accumulation. Unicode-aware token-to-word mapping uses genuine timestamps. Missing required timing is a blocker, not permission to fabricate boundaries or use cloud fallback. Diarization and forced-alignment engines are outside v1. Manual corrections retain timing until user adjustment.

## Editor/render/export

Atomic caption commands and undo; one synchronized list/timeline/preview mapping. Avoid seek loops, focus theft, stale callbacks and rebuilding player/document when panels open.

One deterministic caption evaluator at a project timestamp feeds preview and export. Saved position uses output coordinates. Curated templates combine implemented fonts/styles/highlight/karaoke/pop/fade. Unicode-safe shaping and explicit fallback; no preview-only effect counted complete.

Freeze revision/assets/profile per export. MP4/H.264 720p/1080p, source audio and burned captions; separate edited SRT. P6 trim/crop/volume uses the same composition. Finalize actual output before success, clean cancellation, respect iOS suspension. No separate typography/mix path that diverges from preview.

## Commerce/permissions

AppFoundation paywall/restore, one verified iOS StoreKit entitlement policy in app layer. User decides free limits/plans/prices. Keep projects readable after entitlement changes. No credits/account/server ledger. Scoped Photos/Files and native outbound share only; no extension/App Group.

All code is source-reviewed, not runtime verified. No builds/tests/device checks authorized. See HANDOFF/RISKS.

## P2 as-built contracts — PR #25

- Link WhisperRuntime, InkribeModelAssets and existing JobQueue 1.0.0 directly to iOS. Do not link InkribeTranscription's Mac/diarization pipeline. Only Models/whisper/ggml-small.bin is an iOS model resource; optional source membership permits a clear missing-model runtime state rather than silent fallback.
- IOSSpeechDecoder allocates one <=30-second Float buffer (normal read windows <=28 seconds), places PCM using source PTS and pads audio gaps with silence. One job/runtime executes at once; no audio-prefetch list/full-file PCM.
- NativeWhisperRuntime's captureTokenBytes defaults false, preserving existing Mac behavior. iOS opts into raw BPE bytes and unclamped native timestamps/validity. Reconstruct Unicode before segmentation; do not split durations evenly among words.
- 24-second ownership cores plus two seconds of context each side; retain words by actual midpoint, reconcile repeated cross-window acoustic intervals and store all raw windows separately. Approximate token-union timing and boundary recognition quality await user testing.
- Schema v2 adds optional IOSRecognition. Read v1 without a destructive rewrite; first later mutation writes v2 with a prior-valid backup. Project repository enforces immutable raw recognition and original media. Words/cues are editable data for P3, with stable IDs and source/project intervals; raw windows remain bounded by original asset duration, allowing later non-destructive trims without rewriting raw recognition.
- saveRecognition revision-checks the complete result and atomically publishes it before queue success. Same job ID is idempotent after interrupted queue completion. Explicit retries can refresh revision/language only while no result exists; existing recognition/manual edits are never silently replaced. Renaming during work may make its final revision stale and require explicit retry.
- Duplicates copy recognition with fresh recognition/window/clip/word/cue IDs. Existing P1 rename returns full committed documents, preserving recognized content.
