# Music layer — source handoff

2026-10-31. Passes 1–3, based on develop 723f333, feat/ios-music-layer -> develop, PR #54.
Pass 2 extends b345f71c; pass 3 extends 73a2323c at the user’s explicit next-pass signals.

## Source delivery

- [x] ProjectMusic and schema 12 optional fields; old documents decode without music.
- [x] Copied/inspected one-file ingress, owned UUID paths and atomic publication.
- [x] Replacement preserves mix/loop/offset/fades, removal/Undo retain prior files.
- [x] Section repeat/single play, video endpoint clipping and output-relative start.
- [x] Independent music volume/mute, whole-track endpoint fades, bounded composition.
- [x] Shared PreviewComposition/MP4 audio graph and original-clip master mute.
- [x] Durable expected-state music controls, bounded Undo/Redo, save-before-source lookup.
- [x] Package source checks, reopen, integrity/relink, duplicate and frozen media pins.
- [x] Speech inputs, SRT, allowance, existing UI, Mac/packages/models/CI preserved.
- [x] Pass 2 Video/Music/Captions, scroll-leading native mute/music/caption buttons.
- [x] Empty Add music, source-derived waveform/loop and original mute feedback.
- [x] Controls-only Music sheet with staged file/replace/settings, Done/Cancel.
- [x] One atomic publication/history entry, staging cancellation and failed-save retry.
- [x] Pass 3 source review: ownership/lifecycle, state/history, duration/mute and frozen outputs.
- [x] Scoped cleanup/late-completion, rational timing, slider/mute and import-preflight fixes.
- [x] Approved editor/Music design, speech/Mac/schema/wrapper/dependencies/CI preserved.

## Ownership and concurrency evidence

ProjectMusic.asset is separate from ProjectDocument.assets/clips. Only ownedMediaAssets
joins them for file lifetime/preview/output. Music never contributes to sourceDuration.
Package save validates the referenced file before atomic document publication. Failed
install returns the moved source to staging; successful install performs no cancellable
work before adoption. Replaced/removed source files remain owned for in-memory history;
whole-project deletion/Trash retain their existing lifecycle.

EditorSession locks concurrent session mutations during durable music save/import;
only speech-only publication can rebase. Music history compares the expected soundtrack
and preserves unrelated captions/settings. Source-changing Undo flushes before resolving
the restored saved source; successful save Retry also refreshes the media graph.
MediaKey includes music and original mute so audio edits rebuild the sole player item.

MusicComposition feeds the same PreviewComposition used by MP4Exporter. A separate
music track preserves original clip volume inheritance. One originalAudioMuted switch
zeros only original-lane gain. Repeats use rational selected-section timing, clip the
last segment, check cancellation and cap segment work. Muted music retains its settings.
Fades occur at whole-track boundaries rather than restarting at every repetition.

Frozen MP4 preparation pins the soundtrack alongside retained clip sources; request.json
captures music/mute settings. Duplicate copies/remaps music identity independently;
SRT requests need no audio pins. Existing manifests remain wrapper 1 and old schema
values remain supported. No shared-package or native caption-renderer edits.

## Verification boundary

Source/call-site/diff/whitespace and publication consistency review only. No builds,
typechecks, tests/fixtures, native playback/exports, CI, UI/device runs or deployment.
Compilation, actual audio joins/fades, device performance and output acceptance remain
unverified. The 10,000-repetition ceiling is explicit; looping does not claim seamless
musical transitions. All three planned source passes are complete. Runtime/audio/UI
acceptance remains unverified.

## Pass 2 source evidence

ProjectTimelineSnapshot projects saved music/native duration and effective clip mute.
TimelineGeometry keeps existing video/caption heights and adds a music row between
them; the ruler, center playhead, gesture hit geometry and preview reservation share
these constants. TimelineTrackCanvas puts actual native controls before time zero,
with unboxed two-line original mute and subtle square music/caption buttons. They
scroll with project start and are excluded from tap/pan/hold/pinch handling. Music
row taps open controls; the caption head opens the existing Captions route. The
bottom actions, navigation, styles/themes and other editor flows are unchanged.

TimelineMusicWaveform owns one active background actor reader until cancellation
teardown, one cached 2,048-bin envelope and a bounded PCM buffer. It validates the
requested Float32 mono format, preserves source PTS/gaps, maps section/loop timing,
only draws viewport bars and stops while covered/backgrounded or dismantled. Failed
artwork is labeled unavailable; playback and the controls stay independent.

MusicDraft and MusicSheet hold file copies and controls locally. Initial Files
selection opens Music; replacements share the coordinated importer. The repository's
existing install path now accepts the submitted soundtrack settings so one Done
atomically publishes the file and controls, then records one history operation.
Cancellation cleans Pending staging; failed publication keeps the draft for retry.
The main player remains paused with its existing held-frame handoff, and Music
contains no preview or playback controls. Save/dismiss returns to main-editor preview.

Source/diff/whitespace/call-site review only. No compilation/typechecks/tests, native
media processing/exports, CI, or UI/device execution. Runtime acceptance remains
unverified; pass 3 below was explicitly authorized by the user.

## Pass 3 integration review and fixes

Source review only, extending 73a2323c. No builds, typechecks, tests/fixtures, native
media processing/exports, CI, UI/device runs, or deployment were executed.

| Path reviewed | Source evidence / result |
|---|---|
| Initial import / replace | Coordinated copy and inspection remain unpublished. Copied asset readability/composability/protection preflight now rejects unsuitable media before draft adoption. Replace resets source section and retains local mix/loop/offset/fades. |
| Cancel / child file picker | MusicSheetRoute owns MusicDraft. Only the actual Music presentation binding closes it; covering the sheet with Files no longer controls cleanup through onDisappear/choosingFile state. |
| Late save / dismiss | close marks the draft closed without removing files used by an admitted save. Save's defer cleans retained staging after failure; late success does not dismiss another presentation. |
| Failed / stale save | Expected saved music and exact revision or speech-only rebase gate publication. Failure keeps the live project/history and staged draft. Cancel still frees staging. |
| Undo / redo / removal | Music history changes only expected soundtrack values; replaced originals remain owned. Source-changing Undo saves before URL lookup and successful Retry refreshes the graph. Removal can publish without the removed file. |
| Reopen / schemas | Optional schema-12 fields decode absent music in schemas 1–11. Package sources include the active music file; source duration remains clip-only. |
| Duplicate / Trash | Duplicate physically copies and remaps the music asset, retaining settings; Trash moves the whole package, including earlier retained songs. |
| Longer / shorter video | Shared playback interval clips or extends loops at the retained video end. Saved offsets/sections survive; a start beyond a shortened video becomes silent. Repeat budget and every loop boundary now use rational times. |
| Music / original mute | Original master mute applies only to original lanes and preserves explicit clip levels. Music stays independent. Zero volume now matches muted timeline/VoiceOver feedback. |
| Fades | Proportional fades are converted once and clamped to the remaining native interval, avoiding overlapping/out-of-bounds short ramps. Native slider ranges stay fixed while editing. |
| Preview / frozen MP4 | Both use PreviewComposition plus MusicComposition. Frozen preparation pins captured music bytes and settings; later replace/remove/project deletion cannot redirect an existing request. |
| SRT / transcription / allowance | Speech continues using original assets/clips, and SRT needs no audio pins. Music/master mute never rewrite recognition/source anchors or charge speech usage. |
| Timeline / waveform / navigation | One shared output ruler and playhead; controls retain accepted positions/styles and no Music preview/transport is added. Waveform reader/buffer/envelope bounds and stale/cancellation gates remain. |

API preflight semantics were checked against Apple's official AVAsset async-property
and loading documentation:
- https://developer.apple.com/documentation/avfoundation/avasset-async-properties
- https://developer.apple.com/documentation/avfoundation/avasynchronouskeyvalueloading/load(_:isolation:)

All three source passes are complete. The PR stays open without auto-merge. Actual
compilation, device interactions, format-specific decoding/joins/fades, performance
and exported audio remain unverified; source review is not runtime acceptance.

## CI follow-up — 2026-10-31

The user reported the latest bybydev/example release run, 41165951086 (job
124433440128), built from PR head 312974fb and failed during unsigned iOS archive.
The sole compiler error in the fetched log is TimelineTrackCanvas.swift:244:
ambiguous subtraction between CGFloat and Double in the empty-caption label width.
The fix explicitly types its inset/left/right/width as CGFloat before constructing
the rectangle, preserving the same coordinates and design. Source/diff/whitespace
review only; no local build/typecheck/test or new CI dispatch was performed. The
replacement revision still needs a successful user-run archive.
