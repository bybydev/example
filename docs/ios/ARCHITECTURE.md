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

## P3 as-built editor contracts

IOSEditorSession is the sole open-document writer, including title edits. A 600 ms debounce feeds one uncancelled drain; each write captures a draft sequence and committed revision. Returned revision metadata updates the current draft without replacing newer text. Undo/redo retain atomic word/cue patches (up to 50 with an 8 MiB estimated payload budget, retaining one oversized command; consecutive same-field typing coalesced); playback/selection do not dirty content. Failure retains the draft/history and blocks normal Back/duplicate/trash until saved. Explicit discard/reload clears history. Same-revision background refresh preserves history; changed external revisions never silently overwrite dirty work.

Schema v3 reads v1/v2 without eager migration. IOSCaptionWord.sourceInterval/timingProvenance/rawWindowID remain native anchors. Optional adjustedSourceInterval stores manual timing; effectiveSourceInterval maps to projectInterval. Blank timed text is hidden. Repository validates raw/model/job/native-word anchors and stable word identities before atomic publication. Duplicates remap all IDs and retain corrections/manual timing. Originals remain unchanged.

IOSCaptionEdits validates whole command results; text changes do not infer new timings. Cue retiming explicitly scales existing word intervals, word retiming expands its cue, split preserves left cue ID/creates right ID, merge preserves first cue ID. Native overlap is retained; lookup uses latest active cue start with stable UUID ties. All intervals remain half-open. The immutable IOSCaptionSnapshot has a unique draft identity and revision tag; evaluate(at:) is pure. savedDocument() first drains all saves and refuses a dirty snapshot; later export freezes that returned value/assets/profile.

IOSPreviewComposition builds one AVMutableComposition/AVPlayerItem for the media graph, mapping source/track intersections to project time, first audio/video tracks, orientation and aspect-fit canvas (preview render capped at 1080 longest edge). Gaps are silence/black; source PTS/VFR time ranges are preserved, with a 30 fps display composition. No source mutation, trim/crop or audio mix introduced. Caption edits and panel/selection changes do not replace the player/item. Late load/seek/item callbacks have generation guards; periodic callbacks read current player time and never seek. Pause on background/disappearance and detach observers. P3 originally used a plain caption overlay; P4 replaces it with the shared Core Text renderer described below.

## P4 as-built style/render contracts

Schema v4 adds optional project-wide IOSCaptionStyle: four font enums, size as a fraction of the shorter project-canvas edge, sRGB RGBA colors, outline width as a fraction of font size, background toggle/color, effect enum, and normalized top-left center coordinates. Missing style uses .standard; reads of v1–v3 do not write, and later mutations write v4 with a prior-valid backup. Earlier schema headers containing style data are rejected. Duplicates copy style values. Raw recognition/native word anchors/original media are unchanged.

IOSEditorSession extends the existing history with atomic before/after style changes interleaved with caption patches. Continuous slider/color changes coalesce by control; slider gesture end, tool switch, selection or another command ends a group. One save drain preserves the newest complete title/caption/style draft across acknowledgements; failed saves retain it. Styling and panel changes do not prepare a new player item, seek or replace selection. Templates apply ordinary editable properties and preserve current position.

IOSCaptionSnapshot now freezes canvas/style alongside edited words/cues and revision. IOSCaptionMotion derives all effect state from actual project word intervals at one requested timestamp: active-word highlight, word-duration karaoke progress, a <=12% pop pulse for <=180 ms after a word start, or <=200 ms fades across the visible word envelope. It never modifies timestamps. Content motion is identical in preview/bitmap output and only plays when the user plays/scrubs media; no autoplay decorative animation. Surrounding UI retains Reduce Motion handling.

IOSCaptionRenderer is confined to one render owner/queue. It caches three Core Text line variants and glyph fragments for only the active cue/snapshot (including fit failures); UTF-16 indices, native line breaks, glyph advances and run direction retain Unicode shaping. Fonts have explicit installed-script/emoji/system cascades. Draw uses project coordinates, clamps the caption box to a 2% safe inset with pop headroom, and aspect-fits into output bounds. Text/outline/background/highlight/karaoke/pop/fade use one paint path. Limits are 16,384 UTF-16 units and eight lines; oversize/nonfitting captions fail visibly instead of being truncated.

Preview flips UIKit coordinates into a bottom-left CGContext and calls draw. overlay(snapshot:at:canvas:) makes transparent sRGB CGImage output; composedFrame(orientedFrame:snapshot:at:canvas:) fits an oriented frame into the project canvas/output, adds black letterboxing and composites that same overlay. Existing RenderCanvas bounds cover <=1920 per edge and <=1080*1920 pixels. P5 must pass final project timestamps, freeze savedDocument()/IOSCaptionSnapshot/assets/profile, own media decode/audio/writer/jobs and fail on render errors. No exported MP4/SRT or measured preview/export parity is claimed in P4. The old P0 fixture compositor is marked historical, not an alternate style path.
