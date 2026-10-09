# Listen crash investigation and safety fix

Baseline: develop `364dfc5a4ed52c61095ffa459cfbb1d36d617b50`.
Kokoro source baseline: `e1bbc57ebd0977dfdc7cc3998b62a05c83ee8bf0`.
Fixed dependency: `1d022abdad3c8551358c9bfa2fd54091be948b8e`
([KokoroCoreML PR #4](https://github.com/hoangbkit/KokoroCoreML/pull/4)).
`project.yml` pins this immutable revision. Owner-managed Xcode project and
Package.resolved were not regenerated or resolved during this pass; normal
XcodeGen/package resolution is required when building the changed dependency.

## Evidence and confidence

The initial investigation had no device crash report or failing EPUB and
identified resource risks through source review. The subsequent device report
confirms the EPUB Play crash described below. Start/Continue Listening opens
the Reader without invoking synthesis; an immediate crash there must still be
distinguished from a later Play crash.

### Confirmed crash: Now Playing artwork callback isolation

The supplied October 8 device report terminates with `EXC_BREAKPOINT` / `SIGTRAP`
on MediaPlayer's `*/accessQueue`. Its relevant stack is:

```text
_dispatch_assert_queue_fail
dispatch_assert_queue
_swift_task_checkIsolatedSwift
swift_task_isCurrentExecutorWithFlagsImpl
closure #1 in ProjectSystemMediaController.artworkFor(_:)
-[MPMediaItemArtwork jpegDataWithSize:]
_MPToMRNowPlayingInfoDictionary
```

`ProjectSystemMediaController` is `@MainActor`. Its artwork request closure
inherited that isolation, but MediaPlayer invokes it synchronously on a
background queue. Swift's executor check traps before the closure body runs.
An EPUB cover activates this path before first audio; covered short content can
also activate it. This report establishes an actor-isolation trap; it does not
establish document length as the trigger.

The artwork closure is now created in an explicitly `nonisolated` factory and
typed `@Sendable`. It captures only the immutable bounded `UIImage` thumbnail
and returns it synchronously without accessing controller or runtime state.
Apple documents `UIImage` as `Sendable`; no unchecked wrapper or isolation
assertion is used. Explicit factory isolation also matters because this project
uses default MainActor isolation. See Apple's
[UIImage documentation](https://developer.apple.com/documentation/uikit/uiimage)
and Swift's [closure isolation rules](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md).

The audit also found inline remote-command and audio-node completion closures
created in MainActor classes. They now use nonisolated, Sendable callback
factories and explicitly hop to MainActor before changing playback state.
Audio completion retains its weak queue reference and generation check, so a
stopped/replaced operation cannot consume current buffers. Audio-session
notification observers already request the main queue and remain unchanged.

The earlier thumbnail hardening below did not address callback isolation. The
root cause is confirmed from the report and source; the new fix has received
static review only and still requires a new build and physical-device check.

### Follow-up: EPUB Play closes before first audio

The owner reports that short pasted text works in the same installed build, while
EPUB Play closes the app before any audio. The latest published artifact at the
time of this follow-up was Debug + real models from PR #34 head
`777c017df4423a3eec2086356bca362218f69727`
(`mycli-build-37755314233-1`). This confirms an artifact exists for the earlier
fix; it does not establish which artifact is installed or the termination cause.

The follow-up fixes additional code-confirmed paths:

- Now Playing used `UIImage(contentsOfFile:)` on the original EPUB cover. The
  Reader thumbnail limit did not cover lock-screen artwork, which starts loading
  when Play publishes its loading state. It now publishes transport state without
  waiting for artwork, downscales off the main actor through Image I/O, retains
  only a maximum 512-pixel thumbnail, rejects oversized files/source geometry,
  and cancels stale artwork tasks. Missing/rejected artwork does not prevent
  listening. Stop and detach release the cached system artwork.
- Prefetch awaited a full project reload before the first audio. It now starts
  only after a playback buffer/file segment has been queued. Queue enqueue
  validates project/manifest/queue ownership without decoding every chapter.
  Queue lifecycle/status updates and playback finalization use a queue/status
  snapshot instead of decoding another copy of the EPUB. Full project loading
  still performs source/content validation; audio integrity checks remain.
- Every paragraph progress publication rescanned every chapter's UTF-16 length
  on the main actor. A source-length/prefix index is now computed once off the
  main actor during project refresh; playback progress uses that index.
- Cancelled engine waiters are removed, and cancellation no longer clears the
  shared models. Resource admission failure still releases models while holding
  the operation gate. Gate ownership remains serialized through cancellation
  unwind; synchronous prediction is not claimed to be instantly interruptible.

These changes address concrete allocation and responsiveness risks. They were
implemented before the matching report identified the artwork isolation trap;
they do not, by themselves, fix that trap. Memory pressure, watchdog termination,
and native/model failures remain separate risks requiring device measurements.

Apple's [iOS Memory Deep Dive](https://developer.apple.com/videos/play/wwdc2018/416/)
explains why compressed file size is not the decoded bitmap's memory cost and
why Image I/O thumbnail decoding avoids full-image resizing spikes.

Static review only; no builds, tests, package resolution, or CI were run for the
follow-up. In addition to the device matrix below, verify a large-resolution
EPUB cover, a book with many chapters, early stop/repeated Play during artwork
and model loading, and saved audio with queued offline work. The broader
intent-aware generation/cache redesign remains deferred in issue #35.

| Path | Baseline risk | Fix |
| --- | --- | --- |
| Reader opening | Unbounded paragraph Text and main-thread layout rebuilt for playback updates | Source-preserving bounded slices, cached layout, safe project/text admission |
| Production synthesis | Source targets were tied to the available acoustic buckets (the starter has one 15-second bucket); long unbroken words escaped word splitting | Hard UTF-16 cap plus short source targets, independent of model bucket geometry |
| Model lifetime | Separate pipelines retained separate model sets; actor load re-entered while awaiting SDK load | One shared engine with an explicit operation gate |
| Paragraph capture | Float samples accumulated for the entire original paragraph | Bounded layout plus checked sample accumulation |
| Chapter finalization | All chapter PCM concatenated in RAM, then encoded/decoded again | Incremental temporary WAV and streamed hash/header validation |
| Cached replay/seek | WAV bytes, byte arrays, Float PCM, a tail slice and AVAudioPCMBuffer could coexist | File-backed AVAudioFile segment scheduling |
| Cancellation | Old cancellation handlers called stop without checking operation identity | Operation-scoped stop and post-await identity checks |
| Memory pressure | No app-level warning handler or suspended-work policy | Stop, release models/layout caches, suspend work until an explicit retry |
| Kokoro Debug inference | Short waveform triggered assertionFailure; missing model outputs were force-unwrapped | Recoverable SDK contract errors, finite/bounded duration checks before tensor expansion |

Mono Float PCM at 24 kHz occupies 96,000 bytes/second. A 30-minute chapter is
172.8 MB before the other copies and model tensors. This explains why wrapping
the baseline in another do/catch cannot solve its memory termination risk.

## Limits and compatibility

- Reader slice: at most 600 UTF-16 units, preserving Character boundaries and
  original offsets. Whitespace boundaries are preferred for ordinary text.
- Synthesis input: at most 100 UTF-16 units; source targets 3 then 7 seconds.
- Buffer: at most 30 seconds of 24 kHz PCM. Paragraph capture/cache: at most
  180 seconds. Invalid rate, non-finite samples, and overflow are rejected.
- Section: fewer than 20,000 layout slices; one JSON document at most 16 MiB;
  hydrated project content JSON at most 64 MiB and manifest at most 20,000 items.
  Oversized projects remain on disk and receive an explicit recoverable error.
- Final WAV retains the standard RIFF size limit and transactional WAV/metadata
  pairing. It is not subject to the paragraph's in-memory sample limit.
- Available app memory is checked before model work with a 256 MiB reserve.
  This advisory check is not a promise about Core ML peak allocations or iOS
  termination behavior. Physical-device measurements must validate the reserve.
- Synthesis configuration advances to 2. Old derived audio becomes incompatible;
  source content, schema, IDs, and source bookmarks are retained. Old final files
  are not silently deleted by the migration.

The app does not synthesize silence, swallow unsafe output, silently skip text,
or silently truncate a document to claim success. It stops with an error when
safe processing is unavailable. The original project remains recoverable.

## Verification still required

Implementation received a static diff and call-site review only. Repository
AGENTS.md forbids tests/builds/device verification without explicit approval.
No build, simulator run, test suite, workflow or CI run was performed.

On a physical iPhone with production resources, cover:

1. Open the reported EPUB and distinguish Reader opening from Play. Also open a
   short pasted paragraph, a large PDF, an EPUB with a huge single section, and
   text with emoji/combining marks, no spaces, or many newlines. Confirm first
   audio, then exercise lock-screen artwork, remote play/pause/seek, and both
   live-buffer and saved-file completion. Repeat Play/Stop during artwork loading
   and confirm stale callbacks do not change the new playback operation.
2. Play through chapter completion. Check memory at first prediction, paragraph
   cache writes and finalization, including Generate Offline and prefetch.
3. Replay final audio; seek near beginning/end; pause/resume; change chapter;
   restart the app and resume from matching audio/source position.
4. Rapidly alternate Play/Stop/seek and switch projects during model load. A
   previous task must not stop or publish audio into the new operation.
5. Trigger a memory warning while loading, synthesizing, generating and replaying.
   Work stops, queue stays suspended, progress is retained, and explicit retry
   works after cleanup. Confirm cancelled inference unwinds before model unload.
6. Exercise malformed WAV headers, oversized caches, NaN/Inf audio, missing model
   outputs, overflowing/non-finite durations and short waveforms in Debug and
   Release. Expect a recoverable error and no Swift trap.
7. Fail finalization/commit with low disk space or cancellation. No partial final
   pair should replace a good pair; only that operation's temporary file is removed.
8. Open a configuration-1 project. Source bookmarks survive; old exact seconds
   are rejected; new derived audio can be generated under configuration 2.

The supplied report confirms the artwork failure. Verify the corrected build on
the reporting device and collect peak memory measurements before calling the
fix device-verified. Retain any new crash/JetsamEvent reports for separate failures.
