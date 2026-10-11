# ReadAloud 1.0 Current Architecture

This document describes the implemented ReadAloud 1.0 system. It is the primary
architecture overview for maintenance work after the phased implementation plan.

For durable on-disk semantics, `PERSISTENCE_CONTRACT.md` remains authoritative.

## Product boundary

ReadAloud 1.0 is:

- iPhone only
- iOS 26+
- local-first and offline-capable
- a durable personal document listening library
- backed by bundled, fully offline Kokoro ONNX INT8 speech synthesis
- internally named ReadAloud with bundle ID `com.hoangbkit.readaloud`
- commercially wrapped by AppFoundation

The normal product flow is:

```text
Library
  -> Project Detail
      -> Reader
```

The app uses one NavigationStack rooted in Library, with no tab bar. The top-right
toolbar opens Settings beside the sort menu. A circular floating plus button at the lower
right, with no visible text label, offers EPUB, PDF, document, and Paste Text
imports in both empty and populated
Library states. Its bottom safe-area inset reserves space in the list and keeps
it above the root mini-player.

A single mini-player follows the listening session across Library and Settings,
including retry and replay while its runtime remains loaded.

## App root

`ReadAloudApp` owns the three long-lived product services:

```text
PurchaseManager
ThemeManager
ProjectRuntimeManager
```

`PurchaseManager` is the only production entitlement source.
`ThemeManager` applies the free/Pro theme catalog. ReadAloud Light and ReadAloud
Dark are free, with ivory/teal surfaces and burnt-orange accents matching the app
icon. ReadAloud Dark is the default and free fallback. The user chooses Light or
Dark explicitly; there is no System option. The existing premium themes remain
Pro.

AppFoundation retains theme persistence, access, and color-scheme ownership.
Themed lists and reader surfaces apply the palette beyond control tint.
The existing state key is retained; old Midnight/Paper selections and committed
bases migrate to ReadAloud Dark/Light without resetting other preferences.
`ProjectRuntimeManager` owns reference-stable loaded project runtimes.

Views receive these through the SwiftUI environment.

## Library and import

`LibraryModel` uses `ProjectStore.catalog()` to load lightweight project
snapshots. The Library does not hydrate all chapter content just to render the
shelf.

`LibraryModel` owns one import worker and session at a time for EPUB, PDF,
documents, and pasted text. The worker runs outside MainActor. Queued progress
updates are accepted only for the active, non-cancelled session; terminal
callbacks cannot reopen a completed import sheet.

Cancel or swipe dismissal closes the progress sheet immediately and cancels
the worker. The Library remains usable while any synchronous parser finishes
unwinding, with new imports disabled until cleanup completes. Cancelled and
failed pasted-text imports retain their draft. Paste import starts only after
the editor sheet has dismissed.

`ReadAloudImportCoordinator` normalizes all supported input into one durable
project model:

```text
EPUB -> EpubKit
PDF -> PDFKitAudio
documents -> TextExtractor
paste -> app-owned UTF-8 text
             |
             v
normalized project/items
             |
             v
hidden staging package
             |
             v
<uuid>.readaloud
```

The retained source is copied into the project package. The final package only
becomes visible after its source, metadata, normalized content, queue, and
optional artwork are committed successfully. Package creation checks cancellation
during staging and immediately before its atomic publish. Cancellation before
publish removes the staging package; an import already published remains a
completed project. Project creation has no Free/Pro count limit. The serialized package store
still validates each import and performs an atomic publish.

## Durable project package

Each project lives under Application Support as:

```text
<project-id>.readaloud/
├── project.json
├── source/
├── content/
│   ├── manifest.json
│   └── items/
├── queue/jobs.json
├── cache/
│   ├── chunks/
│   └── artwork/
├── audio/
├── assets/
└── temp/
```

Key invariants:

- project and item UUIDs are stable
- normalized text owns its content revision
- generation identity includes content, resolved narration, Kokoro runtime
  revision, and synthesis configuration version
- finalized audio is Ready Offline only when WAV and metadata agree
- exact playback seconds are valid only for the matching generation/audio
  revision
- the source bookmark survives narration/audio invalidation
- corrupt projects are surfaced as issues rather than silently deleted
- hidden import staging older than the recovery window may be removed as
  abandoned working data
- opening a full project verifies that its retained source still matches its
  stored SHA-256 revision

See `PERSISTENCE_CONTRACT.md` for the complete contract.

## Project runtime

`ProjectRuntimeManager` returns one stable `ProjectRuntime` per loaded project.

A runtime owns:

```text
hydrated project + items
ReadAloudPipeline
ProjectQueueController
ProjectCacheCoordinator
ProjectRuntimePersistenceBridge
playback/generation activity
```

SwiftUI screens observe the runtime. They do not own synthesis tasks, queue
persistence, or a second playback state.

Library operations synchronize loaded runtimes when project metadata changes.

## Narration resolution

Effective narration is resolved as:

```text
item custom
  -> project default
      -> app default
```

Voice and speed inherit independently.

The shared synthesis-speed sheet adapts Spokio iOS's 0.5×–2.0× slider
(0.1× steps, ± buttons and 0.5×/1×/1.5×/2× presets) for app,
project and chapter defaults. Project and chapter pickers preserve their
respective inheritance modes; chapter overrides are free, but a selected voice
still requires its own voice entitlement. Edits are
staged locally and saved once on Done to avoid repeated synthesis cache
invalidation while dragging. Existing saved narration data is retained.

Saved premium selections are not destroyed when Pro expires. Their effective
behavior falls back to the allowed Free configuration until entitlement returns.

## Speech and playback

The pronunciation fallback mode applies to text-level G2P failures, not
model/resource failures: Adaptive (default) spells bounded Latin words after
dictionary/BART failure and skips otherwise unreadable tokens; Skip omits
unpronounceable tokens; Stop with Error reports the token and aborts speech.
An all-unreadable source chunk becomes 100 ms of silence in Adaptive/Skip,
preserving playback progress. Changing modes changes generation/cache identity.

The low-latency path is:

```text
normalized text
  -> SpeechChunkScheduler
  -> SpeechSynthesisEngine (ONNX INT8 only, shared actor)
  -> SpeechPlaybackQueue
  -> AVAudioEngine / AVAudioPlayerNode
```

The persistent path reuses the same synthesis/cache logic:

```text
chunk cache
  -> finalized 24 kHz mono WAV
  -> generated-audio metadata + source timeline
```

Playback chooses a compatible finalized WAV when available; otherwise it
streams/synthesizes from the durable content bookmark.

The same runtime drives:

- Reader controls
- mini-player
- background playback
- Now Playing
- Lock Screen / Control Center commands

There is no separate system-media playback model.

The Reader and mini-player share themed card surfaces and transport components.
Controls follow the playing chapter while the Reader can browse another chapter;
an explicit action starts the chapter on screen. Voice and speed sheets capture
the player chapter when opened. Transport targets are at least 44 points, with
VoiceOver labels and an adjustable scrubber.

Saved audio exposes elapsed/remaining time and exact scrubbing. Live synthesis
exposes chapter source position and passage seeking; skip seconds are approximate
and stay within the current chapter. Dragging commits once on release and is
discarded if the chapter, time mode, or preparation state changes. Views own only
the temporary drag value, not playback work.

The runtime owns an optional session sleep timer (5/15/30/45/60 minutes or end of
chapter). It survives Reader dismissal and seeks, pauses at its deadline, and is
cleared on explicit Stop, shutdown, completion, or failure. It is not persisted
across process restarts. End-of-chapter takes precedence over automatic chapter
continuation. The mini-player sheet captures its runtime and has an explicit Done
action. ImageIO downsampling bounds displayed cover thumbnails to 512 pixels.

See AUDIO_PLAYER_REVIEW.md for source findings and pending device review.

## Generation queue

`queue/jobs.json` is the durable generation intent.

JobQueue is used as an in-process executor, not as the durable source of truth.

Important rules:

- stale `generating` intent recovers to retryable queued work on cold load
- foreground streaming gets speech-model priority
- compatible finalized playback can allow background generation while
  listening whenever the user enables it
- partial chunk cache is reusable
- replacing finalized audio preserves the previous known-good pair until the
  new pair commits
- background synthesis is opportunistic; it is not kept alive artificially

## Storage

Storage categories are measured from the real project package:

- Source
- Generated Audio
- Temporary Cache
- Artwork
- Project Data
- Working Data

`ProjectStorageUsageSection` is the shared presentation of that breakdown.

Clear Temporary Cache removes rebuildable chunk cache (and any legacy paragraph cache).
Clear Generated Audio preserves source/project data and the content bookmark.
Delete Project is the operation that removes the complete package.

## Free and Pro

Only **Kokoro voices and extra themes** are Pro-locked.

Free includes unlimited projects, imports, reading/playback, offline generation
(including selected, remaining, and all chapters), prefetch, generate while
listening, full regeneration and project/chapter narration overrides.

- **Voices:** Heart (`af_heart`) is Free. The other 27 English voice styles
  require Pro. All voices may be previewed or favorited regardless of purchase;
  applying a Pro voice requires verified entitlement. Saved premium voice
  preferences are preserved and fall back to Heart when Pro is inactive.
- **Themes:** ReadAloud Light/Dark are Free. Additional themes remain Pro-gated
  through the AppFoundation theme catalog.

No other feature uses a Free/Pro entitlement check in the Library, offline
generation, regeneration, reader, or narration-speed controls.

## Preferences

`ReadAloudPreferences` owns the app preference keys and effective defaults:

- default voice
- default speed
- pronunciation fallback (Adaptive by default, Skip, Stop with Error)
- skip interval
- continue to next chapter
- prefetch count
- generate while listening
- analytics-enabled placeholder

Changing a preference that affects runtime behavior reconciles loaded runtimes.

## Analytics and diagnostics

ReadAloud 1.0 does not enable product analytics collection.

The old Kokoro prototype reader and live performance dashboard are compiled only
for DEBUG and are reachable only from developer tools. They are not part of the
Release product surface.

## Release configuration

`project.yml` is the XcodeGen source of truth.

The checked-in generated Xcode project and `Package.resolved` are owner-managed;
do not regenerate or resolve them unless explicitly requested.

Kokoro resources have two explicit modes:

- production: verified real assets, shipping eligible
- Kokoro ONNX INT8 + English ONNX G2P + vocabulary + all 28 English voice styles: bundled in every archive

The canonical App Store submission path is manual/local using Xcode/mycli and
the steps in `RELEASE_CHECKLIST.md`.

The manual GitHub Release workflow is implemented for disposable mycli artifacts.
It builds the exact selected ref and lets the user choose Debug/Release and
fully verified bundled ONNX resources. It publishes one unsigned iOS `.xcarchive`
prerelease and never uploads to App Store Connect.

## Maintenance source of truth

Use these documents in this order:

1. `CURRENT_ARCHITECTURE.md` — implemented ownership and component map
2. `PERSISTENCE_CONTRACT.md` — durable data/audio/resume semantics
3. `RELEASE_CHECKLIST.md` — release/submission checks
4. `PRODUCT_PLAN.md` and `DESIGN.md` — product intent and UX language
5. `IMPLEMENTATION_PLAN.md`, `PRE_IMPLEMENTATION.md`,
   `IOS_APP_BASELINE.md`, and root `PLAN.md` — historical implementation
   context


## Listen safety (synthesis configuration 2)

Start/Continue Listening opens the Reader; synthesis starts from its Play control.
Both paths need separate resource bounds. Reader layout uses source-preserving,
UTF-16 ranges and slices at newline/word boundaries, with a 600-unit hard limit.
One layout is cached per runtime instead of rebuilding the chapter on every
playback update. Extremely large sections, project JSON, or malformed grapheme
clusters fail admission without changing the source package.

All project pipelines share one Kokoro engine. Its explicit operation gate covers
SDK load/inference/unload across suspension points, so cancelled/replaced work
cannot load a second model set. Synthesis source chunks are bounded to 100 UTF-16
units and 3/7-second source targets in ONNX mode. Finite
sample/rate/count checks run before buffering, PCM conversion, or WAV encoding.

Final WAV assembly writes one bounded paragraph at a time to a temporary file.
The existing final-audio transaction still verifies hashes, duration, identity,
and metadata, but copies files instead of materializing chapter PCM. Final audio
playback uses AVAudioFile and scheduleSegment, including exact resume and seeks.

A memory warning stops playback, suspends generation/prefetch, releases layout
caches and the shared model set, and retains the durable source bookmark. A user
Listen/Generate action can resume work after cleanup and memory admission pass.
The available-memory check is advisory; bounded processing is the primary guard.

Configuration 2 deliberately invalidates configuration-1 derived audio/cache
compatibility because paragraph boundaries and speech chunking changed. Project
schema, IDs, retained source, normalized text, and source bookmarks stay unchanged.
See LISTEN_SAFETY.md for evidence, remaining verification, and device scenarios.


## Chunk-first streaming (synthesis configuration 4)

The reader keeps its existing <=600 UTF-16 layout paragraphs for display and
scrolling, but the speech scheduler emits short, source-mapped chunks. It prefers
natural clause punctuation within sentences, then bounded words/graphemes for
unusually long phrases. All three consumers use the identical chunk identity:
foreground streaming, background offline generation, and final-WAV assembly.

`SharedChunkAudioCache` stores independently validated chunk WAV/JSON pairs
under `cache/chunks/`; the cache key covers item/chunk identity, source range,
generation key, voice/speed, ONNX runtime revision and synthesis version.
Concurrent identical requests share one in-flight inference. Old paragraph cache
files are never used for new synthesis; Clear Temporary Cache removes them.

The foreground producer synthesizes as quickly as useful with a hard **20
completed chunks ahead of the audible chunk**; this is distinct from the
player's existing two-PCM-buffer queue. Ahead-of-playback chunks live on disk,
not as 20 decoded Float arrays in memory. The producer runs through reader
paragraph boundaries without awaiting paragraph-audio drains. Foreground
listening blocks opportunistic JobQueue synthesis; the shared cache still
supports offline regeneration/reuse when that queue is permitted to run.

The currently **audible** chunk drives the Reader highlight, live chunk-bounded
scrub/skip, and content bookmark. The final chapter WAV stores source/sample
segments per chunk for exact saved-file seeking and highlighting. The
generation version change invalidates incompatible legacy derived audio
without changing original source content, project IDs, or project schema.

Settings configuration for lookahead depth is deferred. No user-facing controls
for eager generation are added by this change.
