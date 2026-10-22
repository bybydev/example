# Inkribe iOS v1 architecture

> Current amendment (2026-10-22): PR #30 is squash merged as eb89f0f. The user has now authorized Pro locking and AF themes; [phases/PRO.md](phases/PRO.md) and [handoffs/PRO.md](handoffs/PRO.md) supersede historical Pro deferral, 28/29 accounting and PR #30 review holds below. The new phase stays open on feat/ios-pro-access-themes → develop. All 29 V1 items are source-integrated; compilation/runtime/user validation is unrun.

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

- Link WhisperRuntime, InkribeModelAssets and existing JobQueue 1.0.0 directly to iOS. Do not link InkribeTranscription's Mac/diarization pipeline. The iOS model-flow amendment in MODELS.md supersedes the old mandatory Small lookup: base project.yml carries no iOS weights; opt-in project-ios-bundled.yml adds required Small and disables download/cache fallback. iOS Tiny/Base/Small descriptors remain outside the Mac manifest. Bundled-first lookup, verified app-private downloads and captured durable job model IDs share the existing inference/window/word pipeline.
- SpeechDecoder allocates one <=30-second Float buffer (normal read windows <=28 seconds), places PCM using source PTS and pads audio gaps with silence. One job/runtime executes at once; no audio-prefetch list/full-file PCM.
- NativeWhisperRuntime's captureTokenBytes defaults false, preserving existing Mac behavior. iOS opts into raw BPE bytes and unclamped native timestamps/validity. Reconstruct Unicode before segmentation; do not split durations evenly among words.
- 24-second ownership cores plus two seconds of context each side; retain words by actual midpoint, reconcile repeated cross-window acoustic intervals and store all raw windows separately. Approximate token-union timing and boundary recognition quality await user testing.
- Schema v2 adds optional Recognition. Read v1 without a destructive rewrite; first later mutation writes v2 with a prior-valid backup. Project repository enforces immutable raw recognition and original media. Words/cues are editable data for P3, with stable IDs and source/project intervals; raw windows remain bounded by original asset duration, allowing later non-destructive trims without rewriting raw recognition.
- saveRecognition revision-checks the complete result and atomically publishes it before queue success. Same job ID is idempotent after interrupted queue completion. Explicit retries can refresh revision/language only while no result exists; existing recognition/manual edits are never silently replaced. Renaming during work may make its final revision stale and require explicit retry.
- Duplicates copy recognition with fresh recognition/window/clip/word/cue IDs. Existing P1 rename returns full committed documents, preserving recognized content.

## P3 as-built editor contracts

EditorSession is the sole open-document writer, including title edits. A 600 ms debounce feeds one uncancelled drain; each write captures a draft sequence and committed revision. Returned revision metadata updates the current draft without replacing newer text. Undo/redo retain atomic word/cue patches (up to 50 with an 8 MiB estimated payload budget, retaining one oversized command; consecutive same-field typing coalesced); playback/selection do not dirty content. Failure retains the draft/history and blocks normal Back/duplicate/trash until saved. Explicit discard/reload clears history. Same-revision background refresh preserves history; changed external revisions never silently overwrite dirty work.

Schema v3 reads v1/v2 without eager migration. CaptionWord.sourceInterval/timingProvenance/rawWindowID remain native anchors. Optional adjustedSourceInterval stores manual timing; effectiveSourceInterval maps to projectInterval. Blank timed text is hidden. Repository validates raw/model/job/native-word anchors and stable word identities before atomic publication. Duplicates remap all IDs and retain corrections/manual timing. Originals remain unchanged.

CaptionEdits validates whole command results; text changes do not infer new timings. Cue retiming explicitly scales existing word intervals, word retiming expands its cue, split preserves left cue ID/creates right ID, merge preserves first cue ID. Native overlap is retained; lookup uses latest active cue start with stable UUID ties. All intervals remain half-open. The immutable CaptionSnapshot has a unique draft identity and revision tag; evaluate(at:) is pure. savedDocument() first drains all saves and refuses a dirty snapshot; later export freezes that returned value/assets/profile.

PreviewComposition builds one AVMutableComposition/AVPlayerItem for the media graph, mapping source/track intersections to project time, first audio/video tracks, orientation and aspect-fit canvas (preview render capped at 1080 longest edge). Gaps are silence/black; source PTS/VFR time ranges are preserved, with a 30 fps display composition. No source mutation, trim/crop or audio mix introduced. Caption edits and panel/selection changes do not replace the player/item. Late load/seek/item callbacks have generation guards; periodic callbacks read current player time and never seek. Pause on background/disappearance and detach observers. P3 originally used a plain caption overlay; P4 replaces it with the shared Core Text renderer described below.

## P4 as-built style/render contracts

Schema v4 adds optional project-wide CaptionStyle: four font enums, size as a fraction of the shorter project-canvas edge, sRGB RGBA colors, outline width as a fraction of font size, background toggle/color, effect enum, and normalized top-left center coordinates. Missing style uses .standard; reads of v1–v3 do not write, and later mutations write v4 with a prior-valid backup. Earlier schema headers containing style data are rejected. Duplicates copy style values. Raw recognition/native word anchors/original media are unchanged.

EditorSession extends the existing history with atomic before/after style changes interleaved with caption patches. Continuous slider/color changes coalesce by control; slider gesture end, tool switch, selection or another command ends a group. One save drain preserves the newest complete title/caption/style draft across acknowledgements; failed saves retain it. Styling and panel changes do not prepare a new player item, seek or replace selection. Templates apply ordinary editable properties and preserve current position.

CaptionSnapshot now freezes canvas/style alongside edited words/cues and revision. CaptionMotion derives all effect state from actual project word intervals at one requested timestamp: active-word highlight, word-duration karaoke progress, a <=12% pop pulse for <=180 ms after a word start, or <=200 ms fades across the visible word envelope. It never modifies timestamps. Content motion is identical in preview/bitmap output and only plays when the user plays/scrubs media; no autoplay decorative animation. Surrounding UI retains Reduce Motion handling.

CaptionRenderer is confined to one render owner/queue. It caches three Core Text line variants and glyph fragments for only the active cue/snapshot (including fit failures); UTF-16 indices, native line breaks, glyph advances and run direction retain Unicode shaping. Fonts have explicit installed-script/emoji/system cascades. Draw uses project coordinates, clamps the caption box to a 2% safe inset with pop headroom, and aspect-fits into output bounds. Text/outline/background/highlight/karaoke/pop/fade use one paint path. Limits are 16,384 UTF-16 units and eight lines; oversize/nonfitting captions fail visibly instead of being truncated.

Preview flips UIKit coordinates into a bottom-left CGContext and calls draw. overlay(snapshot:at:canvas:) makes transparent sRGB CGImage output; composedFrame(orientedFrame:snapshot:at:canvas:) fits an oriented frame into the project canvas/output, adds black letterboxing and composites that same overlay. Existing RenderCanvas bounds cover <=1920 per edge and <=1080*1920 pixels. P5 must pass final project timestamps, freeze savedDocument()/CaptionSnapshot/assets/profile, own media decode/audio/writer/jobs and fail on render errors. No exported MP4/SRT or measured preview/export parity is claimed in P4. The old P0 fixture compositor is marked historical, not an alternate style path.

## P5 as-built export contracts

PreviewComposition.mediaGraph builds immutable AVComposition/AVVideoComposition copies, used independently by preview and the export task. Track/source intersections preserve PTS offsets; partial video intervals and project gaps have explicit black instructions. Both use the project-aspect rectangle, orientation transforms and an SDR Rec.709 composition. P6 should extend this builder for media mapping/crop/audio mix and the snapshot/SRT output-time mapping, not fork them.

ProjectRepository.prepareExport checks the canonical saved document/revision, publishes a version-1 export manifest, and hard-links immutable originals (copy fallback) into a separate Exports/UUID job directory while serialized against Trash/deletion. The canonical comparison uses the repository's ISO-8601 representation so fractional in-memory save dates do not falsely conflict. Export manifests are independent of project schema v4. No AV objects enter persistence.

ExportController owns one separate JobQueue export record, with a small project/profile payload. The worker reconstructs the frozen document/assets; reader/writer/Core Text/CI objects are confined to one non-main execution task (only AVAssetWriter's cancellation hook is dispatched separately). AVAssetReaderVideoCompositionOutput applies the shared footage composition. An interleaved AVAssetWriter loop emits fixed 30 fps H.264 frames and 48 kHz stereo AAC from the original first audio tracks. The exact P4 overlay uses each output PTS; audio-only projects and intentional gaps use black. Two decoded samples, a six-buffer output pool cap, one audio sample and one active caption layout bound app-owned media data. Backpressure waits for recycling; there is no whole-movie PCM/frame collection. Metadata still scales with transcript length. Native decode/encoder/GPU memory is unmeasured.

The writer must finalize and pass file size/duration/codec/dimensions/expected-audio validation before a same-volume rename into Result/title.ext. Partial output is removed on failure/cancel/restart. Frozen inputs survive failure/pause for retry, successful publication removes pins, and completed files remain for delivery. A published file is reused if queue acknowledgement was interrupted. Foreground transitions pause/restart the durable job; no uninterrupted background completion or frame checkpointing promised. One retained job prevents an export batch/history feature; explicit replacement/discard and startup orphan cleanup bound artifact retention. Delivery tokens prevent deletion while Photos/Files/share consumers use a file. Files are copied by UIDocumentPicker, never loaded into movie Data. Add-only Photos permission is requested solely for Save to Photos.

SRT exports visible edited cues in project time, preserving overlaps and stable start/UUID ordering, omitting hidden/empty cues and blank internal lines, and rounding start down/end up to milliseconds. Style/motion is MP4-only. P6 must apply its final timing map to SRT as well as MP4. Pro is explicitly deferred by the user; existing AppFoundation/empty StoreKit scaffolding is unchanged and no export gates exist yet. This is source integration, not compilation/media/runtime evidence.

## P6 as-built media contracts

Schema v5 adds optional MediaEdits; v1–v4 reads use defaults, with no eager migration. Full original ProjectClip and recognition/manual source/project intervals remain canonical. OutputTimeline stores retained start/end in that original project clock, intersects half-open intervals and maps retained time to zero. CaptionSnapshot clips/maps only its derived words/cues; original edited words supply effect timing at outputTime + trimStart. A cut through a word retains that timed unit's text and original animation phase, not invented sub-word alignment. Original cue-start order precedes UUID ties when clipping makes several starts zero. SRT consumes this same ordered output snapshot.

MediaEditState retains only media values/canvas/preset in the existing bounded history. Trim/crop/aspect/volume participate in one save drain and undo/redo. Slider gestures coalesce by control. Undo or media changes remap the playhead through original time. Caption timing correction fields deliberately show and edit original project seconds, with explicit UI explanation after trim; text corrections/split/merge remain canonical, and reset trim reveals retained canonical content. Output selection/list/timeline/transport use clipped output time.

Shared mediaGraph maps each retained clip intersection into source and output time, then applies actual track intersections/offsets. Framing uses preferred source orientation followed by fit/fill, zoom 1–3 and normalized pan, clamped by inverse-transformed source crop rectangles into the project viewport. Both raster media and caption overlay use the same even-sized viewport before project-aspect fitting. Whole-project aspect choices reuse canvas/preset; no clip reordering/speed/keyframes added. OriginalAudioMix(trackID:volume:) is used by AVPlayerItem and reader AudioMixOutput; volume-only edits update it live without changing the item or clock.

Actual trim/framing changes debounce player rebuilding by 120 ms, invalidate old load/seek/status/end generations and ignore old periodic callbacks during preparation. Resolve missing initial URLs in the current generation. Pure caption/style/panel changes do not rebuild media. A trim retaining no source samples receives a single tiny cached black clock frame stretched for native playback; it contributes no video interval/audio to export, which remains intentionally black/silent. Trailing retained gaps receive explicit black instructions.

Repository duplicates preserve media edits. Project-card duration uses retained duration; original-file information and derived source thumbnails still describe the originals. Export pinning includes only assets referenced by retained clips; schema-v5 media settings stay frozen in the existing version-1 manifest. MP4 finalization checks retained duration. Old v1–v4 projects and old frozen requests retain identity mapping. Original/recognition files, Mac schema, entitlements and purchases remain untouched. This is source integration only, not pixel/audio/native/runtime evidence.

## P7 recovery and race corrections

Library/thumbnail completion paths share a generation- and query/sort/filter-guarded publisher. Storage publishes its three asynchronously read values only for the latest request. Photos preparation has its own busy state; new selections/import/removal are blocked until preparation/import allows them. A repository-owned in-memory active-staging set excludes live transactions from recovery/cleanup; it is intentionally absent after process death so committed staging can recover. Uncommitted ingress-only copies are cleaned once at model initialization, independent of project originals.

Both queue controllers distinguish a successfully started queue from a queue object whose initial load/rewrite failed. Retry starts/loads the latter again; only a fully started queue can persist its current records during retry. This avoids replacing durable jobs with empty pre-start memory. Foreground speech pause cancels execution through JobQueue's existing pause/requeue semantics; native shutdown errors under cancellation become CancellationError after unload/lease release. No background execution entitlement or frame/window checkpointing is introduced.

Trash uses the same prior-valid read as Projects while rejecting future schemas. Revisions/schema stay unchanged. updatedAt is nondecreasing despite wall-clock rollback, title duplication retains the 256-character limit, timing Apply preserves untouched rational boundaries and is a no-op for identical intervals, and output basenames preserve the legacy 80-character rule while bounding 251 UTF-8 bytes plus the four-byte extension. Import rejects nonfinite/invalid dimensions before Int conversion. See handoffs/P7.md for exact limitations/user checks; no runtime verification occurred.

## Pro follow-up ownership

Pinned AF 0.1.8 owns verified StoreKit lifecycle, paywall/upsell and theme state/picker. ProAccess centralizes app gates and expiry; Commerce owns approved policy/IDs. ProjectRepository exclusively owns a separate atomic schema-1 weekly usage ledger. Durable job reservations precede enqueue and successful recognition IDs reconcile exactly-once charges across interruption. Accepted job policy is captured in an optional payload flag, preserving old queues; project schema stays v5. New export access is checked before replacing the retained artifact. Theme chrome is independent of shared media/caption rendering. See handoffs/PRO for storage and expiry contracts.
