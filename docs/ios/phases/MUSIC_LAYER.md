# Music layer — approved scope

2026-10-31. Base: develop 723f333bd7a635edbfe1bc5078e094ba4839d4cd.
One PR: feat/ios-music-layer -> develop. Keep open without auto-merge.

## Pass 1: MUSIC.FOUNDATION / OUTPUT / OWNERSHIP / ORIGINAL_MUTE

One project-level audio file, imported from Files through the existing coordinated,
bounded copy and native inspection. Keep it separate from assets/clips used by
recognition; never change caption source anchors, speech admission/allowance or
project duration. A replacement keeps volume, mute, loop, offset and fades while
resetting the source section to the new file's full duration. Remove/replace keep
older owned files for existing in-memory Undo and frozen export pins.

Store one optional ProjectMusic and independent originalAudioMuted in schema 12;
read schemas 1–11 without migration/reparse/inference. Keep wrapper versions.
The soundtrack stores a rational source interval and rational zero-based output
start, loop enabled by default, initial volume 20%, independent mute and fade-in/out
seconds (off initially). Music never extends the retained video. Without looping,
play the selected section once and leave silence afterward. With looping, repeat
that section from the saved output start, truncating the final repetition at video
end. Offset/section stay intact through trim/reorder/duration changes. An offset
beyond a shortened video becomes silent until the video grows again.

Preview and MP4 use the same independent audio lane/mix with source-track gaps
preserved. Fades apply only at the whole soundtrack's playback endpoints; overlapping
fades meet proportionally. No crossfade between repeated sections is promised.
Composition work is cancellation-aware and bounded to 10,000 repetitions; a section
that would exceed that limit is rejected with a longer-section message.

Controls commit before adoption, with one music-only expected-state history entry.
Failed saves keep the caller's local draft. Only append-only speech publication may
rebase; other concurrent changes conflict. Original master mute is independent of
project defaults and sparse clip volume overrides. Unmuting restores those levels.

Integrate owned media into package source validation, integrity/relink, duplication,
availability/storage and frozen MP4 media links/copies. Exports already prepared
keep their own song/settings. SRT and transcription remain caption/clip-only.

## Pass 2: MUSIC.TIMELINE / SHEET — authorized and source-integrated

Video -> Music -> Captions. At the leading row heads: unboxed speaker plus Mute clip
audio label, compact square music control, matching caption control opening the
existing Captions sheet. Empty music lane: + Add music; import then open controls.
One waveform block with a loop indicator. Controls-only Music sheet: file name,
Replace/Remove, volume/mute, source section/start, loop-to-fit, fades, Done. No video
preview or playback controls in this sheet. Preview afterward in the unchanged main
editor. No unrelated design changes. Do not add other proposed controls implicitly.

The user's next-pass signal authorizes this in existing PR #54 from b345f71c.
Leading controls live before time zero in the existing scroll padding, not in a
fixed sidebar. Row geometry adds 48 points for music; original video/caption row
heights, ruler/center playhead/pinch/scrub/timing behavior remain. The native controls
are excluded from canvas/parent timing recognizers and join VoiceOver traversal.

MusicDraft stages copied/inspected selections and local settings. Replace resets
only the source section; volume/mute/loop/offset/fades stay local. Done saves file
and controls together before one history adoption. Failed saves preserve the draft;
Cancel/swipe cancels copying and releases unpublished staging. No Music preview,
transport, sample player or new bottom action. The main editor stays paused/held
behind Music and returns through its existing single-player ownership.

The optional waveform streams the first source audio track into 2,048 normalized
peak bins with one reader, cancellation checks, a 4 MiB per-buffer ceiling and no
whole-song PCM array. It maps selected source sections/repetitions to the shared
output ruler, draws only visible bars, suspends while covered/backgrounded and
ignores stale results. Loading/unavailable labels never fake a waveform or block
music controls/playback. No model/inference or persistent waveform files.

## Pass 3: integration review — authorized and source-complete

Review replacement/removal, reopen/duplication, duration changes, mute interactions,
stale/cancel/failed-save/history behavior and export consistency. Existing execution
restrictions apply; source completion never claims native/runtime acceptance.

The user's final next-pass signal authorizes this from PR #54 head 73a2323c.
Keep the settled design. Draft staging now belongs to the actual Music presentation
binding, so a child Files picker never ends the draft's lifetime. A dismissal during
an admitted save marks the draft closed and defers file cleanup until publication
finishes; a late completion cannot dismiss a newer presentation. Repeat-limit checks
and repeated boundaries use rational CMTime instead of floating quotient/cumulative
addition. Converted fades are clipped to nonoverlapping native playback intervals.
Fade controls keep bounds fixed for the lifetime of the draft. Zero-volume music
uses the same muted timeline/VoiceOver feedback as its independent mute toggle.
Copied ingress checks isReadable/isComposable/hasProtectedContent before a source
can be accepted by the Music draft. Those checks load metadata only, not inference,
playback or an output render. Compilation/native acceptance remains unverified.

## Protected scope

No changes to editor appearance/navigation/bottom tools in pass 1, no music catalog,
multiple songs/layers, effects/beats, speech/model/commerce/dependency/CI/Mac changes.
No builds/typechecks/tests/fixtures, generation/models, native media processing,
exports, UI/device execution or deployment. Review source/call sites/diff/publication.
