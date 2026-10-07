# ReadAloud

ReadAloud is a local-first, offline document-to-speech reader for iPhone.

The current product direction, architecture, persistence contracts, design, and implementation phases live under `docs/`.

## Project configuration

- Bundle ID: `com.hoangbkit.readaloud`
- Development team: `J458WW3452`
- Product baseline: iOS 26+ for iPhone
- iPad support: No
- The prototype macOS target is not part of ReadAloud 1.0
- Project generation: XcodeGen
- `project.yml` is the source of truth; the generated Xcode project and `Package.resolved` are checked-in owner-managed artifacts.


## 1.0 documentation

Read these before implementation:

- `docs/IOS_APP_BASELINE.md` — common setup reused from Spokio iOS, MiLove, and Palette
- `docs/CI_RELEASE.md` — manual branch-aware Fast CI, Full CI, and Release contract
- `docs/PRE_IMPLEMENTATION.md` — decisions that must be locked before product work
- `docs/ARCHITECTURE.md` — target system architecture
- `docs/PERSISTENCE_CONTRACT.md` — durable project/runtime contract
- `docs/IMPLEMENTATION_PLAN.md` — phased implementation plan
- `docs/PRODUCT_PLAN.md` — product scope and quality bar
- `docs/DESIGN.md` — iPhone UX design
- `docs/RELEASE_CHECKLIST.md` — final 1.0 manual release and submission checklist
- `AGENTS.md` — repository working rules

`PLAN.md` documents the completed prototype effort and is retained only as historical context.

## Kokoro SDK

ReadAloud consumes the `KokoroTTS` product from KokoroCoreML, with the 1.0 implementation baseline pinned to stable tag `1.1.0`.

KokoroCoreML 1.1.0 also publishes the executable fixture archive used by ReadAloud fixture builds. ReadAloud consumes that artifact; it does not own the fixture generator.

Prepare the verified production Kokoro assets with:

```bash
bash scripts/bootstrap.sh
```

XcodeGen should consume the released package using `exactVersion: 1.1.0` during Phase 0.

## Kokoro assets

Kokoro model and voice binaries are not committed to Git. Download the pinned,
checksum-verified asset set with:

```bash
bash scripts/download-kokoro-assets.sh
```

Verify an existing local asset set without replacing files:

```bash
bash scripts/verify-kokoro-assets.sh
```


### Executable fixture assets

Download and verify the matching KokoroCoreML 1.1.0 executable fixture with:

```bash
bash scripts/download-kokoro-fixture.sh
```

The archive SHA-256 and fixture runtime revision are pinned in
`scripts/kokoro-fixture-pins.sh`. The extracted fixture is stored under
`testfixtures/kokoro` and remains uncommitted.

Production is the default build resource mode. To explicitly stage the
executable fixture instead:

```bash
READALOUD_KOKORO_RESOURCE_MODE=fixture xcodebuild ...
```

Fixture mode never downloads the production models.


The asset pipeline pins the upstream Hugging Face revision and first verifies
the full-profile runtime manifest against `scripts/kokoro-checksums.sha256`.
Every selected model file, voice, vocab file, and hn-NSF weight file is then
verified against the per-file SHA-256 and byte count from that trusted manifest.

The prototype selects all five Kokoro speech buckets (3, 7, 10, 15, and 30
seconds) and three English voices: `af_heart`, `af_bella`, and
`am_michael`.

After verification, the downloader also writes a schema-valid custom
`Resources/Kokoro/KokoroRuntimeManifest.json` containing only the exact
models and voices bundled by ReadAloud. The custom manifest preserves the
upstream provenance fields unchanged and records ReadAloud's verified source
manifest digest separately. Downloaded assets and the generated runtime
manifest remain ignored by Git.

## App resource bundling

ReadAloud keeps production and fixture sources separate, then stages exactly one
validated resource root into `.build-resources/Kokoro` before the resource copy
phase. XcodeGen bundles that staged folder as `Kokoro`.

- `production` mode validates and stages `Resources/Kokoro`
- `fixture` mode validates and stages `testfixtures/kokoro`
- the staged root records `ReadAloudResourceMode.json`
- runtime admission uses `.productionOnly` for production and
  `.executableFixture` only for an explicitly staged fixture build

This prevents production and synthetic model trees from being bundled together
and keeps KokoroCoreML's manifest-keyed compiled caches isolated.

The staged bundle preserves the upstream SDK layout:

```text
Kokoro/
├── KokoroRuntimeManifest.json
├── coreml/
│   ├── kokoro_duration_t128.mlpackage
│   └── bucket-specific .mlpackage directories
├── voices/
│   ├── af_heart.bin
│   ├── af_bella.bin
│   └── am_michael.bin
└── runtime/
    ├── kokoro-vocab.json
    └── hnsf_weights.json
```

The pre-build staging script validates the selected mode before copying it.
Production keeps the existing verified provenance, five-bucket model set, and
synthetic-asset rejection. Fixture validation requires the exact
`fixture-executable-v1` profile, the published 1.1.0 runtime revision, one
15-second acoustic bucket, four model packages, three synthetic voices, and the
declared file/tree hashes.

`KokoroResources` reads the staged manifest's available buckets so the
scheduler does not invent missing fixture models. The streaming planner still
uses short 3-second/7-second source chunks; the Kokoro provider maps those
chunks onto the selected bundle's available model buckets.

The source `.mlpackage` directories are bundled intact. The upstream SDK
compiles and caches Core ML models in its writable manifest-keyed cache rather
than attempting to write compiled artifacts into the application bundle.

## Kokoro engine

`KokoroEngine` is the app-owned boundary around the upstream SDK. It exposes:

```text
load()
warmUp(text:voice:speed:)
synthesize(text:voice:speed:maxChunkSeconds:)
unload()
```

ReadAloud owns lifecycle, bundled-resource selection, cancellation/error
mapping, and synthesis timing. The upstream SDK owns raw-text preparation,
Misaki phonemization, chunk preparation, voice embeddings, staged Core ML
inference, and 24 kHz mono PCM generation.

The engine currently exposes the three bundled voices and returns synthesis
duration plus real-time factor with each generated `KokoroAudio`.

## Continuous read-aloud pipeline

Phase 4 adds the streaming reader path:

```text
text
  ↓
SpeechChunkScheduler
  ↓
KokoroEngine
  ↓
SpeechPlaybackQueue
  ↓
AVAudioEngine / AVAudioPlayerNode (connected at Kokoro's PCM format)
```

The scheduler keeps the first chunk intentionally short with a 3-second target,
then uses 7 seconds for normal steady-state chunks and moves to 10, 15, or 30
seconds only when a larger sentence requires it. Long sentences are split on
word boundaries before synthesis instead of synthesizing the full document at
once.

`ReadAloudPipeline` keeps up to two scheduled PCM buffers. It synthesizes the
next chunk while the current buffer is playing, which provides one-buffer
read-ahead without letting memory usage grow with document length. Playback
queue changes are emitted directly by `SpeechPlaybackQueue`, so live metrics
continue to update as buffers drain rather than only when synthesis completes.

Calling `stop()` cancels the active synthesis task and immediately flushes
scheduled playback. The loaded Kokoro engine stays alive between reads so
already-loaded/compiled model state can be reused. `unload()` explicitly drops
the engine when needed.

## DEBUG Reader prototype

The developer-only prototype screen drives the standalone local pipeline and is not part of the normal 1.0 product navigation. It includes:

- editable text input;
- bundled voice selection;
- 0.8×, 1.0×, and 1.2× speed choices;
- Read, Stop, and Warm Up controls;
- three built-in repeatable sample passages;
- live pipeline status;
- a compact rolling event log.

The live metrics panel reports model load time, first-audio latency, latest
chunk synthesis time, generated audio duration, RTF, scheduled bucket,
chunk progress, queued audio depth/duration, underrun count, warm-up time, and
the current iOS thermal state.

## Generate the project

After fetching the SDK and model assets:

```bash
xcodegen generate
```

## Build from the command line

Simulator build:

```bash
xcodebuild \
  -project ReadAloud.xcodeproj \
  -scheme ReadAloud \
  -configuration Debug \
  -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For a physical iPhone, generate the project and build the `ReadAloud` scheme with automatic signing.

## Project package foundation

ReadAloud projects are app-internal `.readaloud` packages stored under
Application Support in the ReadAloud Projects directory. Phase 1 defines the
v1 Codable disk contract and `ProjectStore` for:

- atomic package creation and JSON replacement;
- lightweight Library snapshots from `project.json`;
- full manifest/item/queue hydration;
- stable lowercase UUID package/item filenames;
- source, content, generation, playback, queue, and audio metadata validation;
- explicit schema-version rejection/migration boundaries;
- safe rename/settings/playback updates and project deletion.

Normalized item text owns its SHA-256 content revision. The project content
revision hashes ordered item identity/revisions plus hierarchy, while generation
keys deterministically bind item revision, resolved voice/speed, Kokoro runtime
revision, and synthesis configuration version.

## Unified import pipeline

Phase 2 adds one import coordinator that normalizes every supported source into
the Phase 1 project contract before publishing the package:

- EPUB uses EpubKit spine order, metadata, TOC hierarchy where it maps to
  playable chapters, cover artwork, and parser diagnostics.
- PDF uses PDFKitAudio audiobook chapters/page ranges, OCR diagnostics, and the
  generated cover thumbnail.
- TextExtractor-backed documents preserve package-provided structural segments
  such as presentation slides and subtitle cues; otherwise they become one
  normalized document item rather than inventing structure the extractor did
  not expose.
- pasted text is retained as an internal UTF-8 `.txt` source and normalized
  into one project item.

External files are copied out of security-scoped access into a private temporary
workspace first. The final source, optional artwork, manifest, items, queue, and
project metadata are then committed through the hidden `.readaloud` staging
package. The final package becomes visible only after source SHA-256 validation
and all writes succeed, so a failed import does not register a broken Library
project.

## Library

Phase 3 replaces the prototype-first launch screen with the real Library home.

The Library stays snapshot-driven: it reads `project.json` metadata through
`ProjectStore.catalog()` and does not hydrate content items just to render the
shelf. It provides Continue Listening, artwork, progress/source metadata,
search, sort, pull-to-refresh, rename, delete, project-info actions, and
per-package corruption warnings.

The Add menu connects the Phase 2 importer to native file import and pasted
text. Import progress/errors remain local to Library, and failed imports never
create visible partial projects. Project navigation is established now; the
actual Project Detail implementation belongs to Phase 4. A global mini-player
slot is reserved at the tab root for the later shared playback runtime.

## Project Detail and narration settings

Phase 4 replaces the Library project placeholder with the real Project Detail
experience. A project is fully hydrated only after the user opens it; Library
remains snapshot-driven.

Project Detail now provides project artwork/metadata/progress, Continue
Listening routing, project voice/speed defaults, stable ordered items, durable
offline-generation states, item actions, project rename/delete/info actions,
and lightweight offline/storage management.

Narration resolution follows the persistence contract independently for voice
and speed:

```
item Custom -> remembered item value
item Default -> project default
project default absent -> app default
```

Selecting Default changes only the item's `inherit` mode. Remembered custom
values remain persisted and are restored when Custom is selected again.
Changing a project default never overwrites item overrides. If a narration
change affects the current item, the content bookmark is preserved while the
old exact-audio position is invalidated.

Generate/Regenerate actions in this phase persist durable queue intent only;
the runtime queue executor arrives later. Ready Offline is derived from the
current generation key plus valid audio metadata and the finalized WAV identity,
not from queue state or file presence alone. Regeneration leaves the known-good
audio in place until a future generation commits its replacement.

## Project runtime

Phase 5 introduces the reference-stable runtime layer for project activity.
`ProjectRuntimeManager` is installed at the app root and owns loaded project
runtimes. Repeated navigation to the same project reuses the same runtime
reference and deduplicates in-flight acquisition.

Each `ProjectRuntime` owns:

- active project identity and hydrated project/item state;
- the existing streaming `ReadAloudPipeline` synthesis/playback owner;
- durable queue state through `ProjectQueueController`;
- cache/package paths through `ProjectCacheCoordinator`;
- disk mutations through `ProjectRuntimePersistenceBridge`;
- aggregated playback/queue activity and item generation state.

Project Detail no longer creates its own `ProjectStore`. It is a UI adapter
over the shared runtime, and the Phase 6 Reader route already receives that same
runtime instance. The tab-root mini-player host observes the manager/runtime
rather than creating playback state of its own.

Library remains snapshot-driven and lightweight. Library rename/delete actions
synchronize any loaded runtime so cached project state cannot become stale.

The historical DEBUG prototype Reader still owns its standalone prototype
pipeline and remains isolated from the 1.0 project navigation. Product project
screens use `ProjectRuntime` as the ownership boundary.

## Reader

Phase 6 replaces the project Reader placeholder with the real runtime-backed
reading/listening experience.

Reader now provides:

- readable chapter/section text with persisted appearance controls;
- current-paragraph highlighting driven by the runtime's audible paragraph;
- saved-bookmark restoration when re-entering Reader;
- manual scrolling that never gets force-corrected back to playback;
- an explicit Return to Current affordance after the user scrolls or browses
  another chapter;
- play, pause, resume, stop, backward/forward seek, automatic chapter
  continuation, previous/next chapter browsing, voice and synthesis-speed
  access;
- a searchable Chapters sheet with live playback/offline status and preserved
  manifest hierarchy;
- current-chapter generation/offline actions and chapter info;
- direct Continue Listening routing from Library;
- the same ProjectRuntime observed by Reader, Project Detail, and the global
  mini-player.

Streaming playback persists a content bookmark at the start of each audible
normalized-text paragraph and keeps `audioPosition` nil until a finalized
audio identity exists. Voice/synthesis-speed changes stop an affected old
stream while preserving that bookmark.

The ±15-second Reader controls are intentionally mapped to the nearest
paragraph boundary using estimated speech duration during streaming. Phase 7's
finalized audio timeline is responsible for exact generation-bound audio
seeking; Phase 6 does not invent exact seconds for a stream that has no durable
audio revision yet.

Reader paragraph transitions reuse one active audio session/engine sequence
instead of tearing audio down between paragraphs. Pause intent is owned by
ProjectRuntime so it remains stable during synthesis and between paragraphs.

## Streaming and persistent generation

Phase 7 combines the existing low-latency streaming path with durable
offline-ready audio.

Playback now follows this decision:

```
compatible finalized WAV exists?
  yes -> play the verified WAV
  no  -> stream paragraph audio through Kokoro
         -> reuse compatible paragraph cache when available
         -> cache newly synthesized paragraph audio
         -> finalize the item only when every paragraph is available
```

Paragraph cache identity includes the stable item ID, paragraph index,
paragraph text revision, resolved voice, canonical synthesis speed, Kokoro
runtime revision, and synthesis configuration version. Cache entries are
derived data: partial, stale, malformed, or hash-mismatched entries are deleted
and regenerated without affecting project correctness.

Final item audio is 24 kHz mono 16-bit PCM WAV plus
`audio/<item-id>.metadata.json`. The metadata contains the deterministic
generation key, WAV SHA-256 audio revision, resolved narration identity, and a
source-segment timeline built from the actual persisted sample counts. Segment
timing is never estimated from text length.

Final WAV + metadata replacement is staged together with rollback copies.
Existing known-good audio remains untouched until staged replacement is ready;
ordinary replacement failures restore the previous pair.

Resume semantics:

- streaming playback persists only the normalized-text content bookmark;
- verified finalized playback persists that bookmark plus
  `generationKey + audioRevision + exact seconds`;
- matching generation key and audio revision restore exact seconds;
- a regenerated WAV with a different audio revision restores from the
  bookmark's segment start;
- stale/incompatible finalized audio is never played;
- voice/synthesis-speed changes and Clear Generated Audio preserve the content
  bookmark while invalidating exact audio seconds.

The Reader's ±15-second controls therefore use actual finalized WAV time while
playing compatible persistent audio. They retain the Phase 6 paragraph-boundary
fallback only for live streaming, where no durable audio identity exists yet.

Streaming playback itself satisfies existing Generate intent when it completes
the same generation. A verified final asset takes precedence over stale queued
or generating history for Ready Offline status.

Phase 8 remains responsible for executing durable queued generation and
prefetch independently of foreground Reader playback.

## Durable queue and prefetch

Phase 8 turns `queue/jobs.json` into an executable, recoverable generation
queue while keeping it as the single durable source of truth.

The in-process scheduler uses `JobQueue 1.0.0`, but its own persistence is
derived runtime state under the project `temp/` directory and is rebuilt from
`queue/jobs.json` whenever a project runtime is loaded. Durable job IDs are
also used as JobQueue IDs so execution events map back to the persisted intent
without a second identity system.

Queue lifecycle rules:

- stale persisted `generating` jobs recover to `queued` on cold runtime load;
- job start persists `generating` and increments the attempt count;
- yielding for foreground playback persists the job back to `queued`;
- success persists `completed`;
- failures persist `failed` plus the error message;
- cancellation removes queued/generating intent rather than inventing a
  separate durable cancelled state;
- retry creates fresh queued intent using the item's current generation key;
- narration-setting changes discard stale queued/generating/failed intent for
  affected items.

Queue execution is single-concurrency and shares the same `KokoroEngine` used
by Reader streaming. It therefore never loads a second speech model. Missing
paragraphs are synthesized with the same `SpeechChunkScheduler`, stored in the
Phase 7 paragraph cache, then finalized through the same WAV + metadata
transaction.

Foreground playback always has priority. When Reader needs Kokoro for live
streaming, the generation queue pauses and any executing job is cancelled back
to retryable queued intent; completed paragraph cache survives that yield.
When Reader is playing an already-finalized WAV, Kokoro is idle, so queued
generation may run safely while the user continues listening.

Prefetch policy is deliberately small and understandable: entering a chapter
queues at most the next two not-ready chapters. Prefetch never bypasses durable
queue order and never replaces a valid Ready Offline asset.

Project Detail and Offline Audio expose the durable queue state and operations:
Generate, Generate Selected, Generate Remaining, Generate All, Cancel, Retry,
Regenerate, and Clear Cache & Regenerate.

Background execution is still opportunistic. Phase 8 guarantees persisted
intent and safe recovery; it does not claim indefinite iOS background synthesis.
Phase 9 owns system background playback / Now Playing integration.

## Background playback and system media

Phase 9 makes ReadAloud participate in iOS system audio like a normal
spoken-audio app.

The app declares the `audio` background mode and keeps playback on an
`AVAudioSession` configured with the `.playback` category and
`.spokenAudio` mode. The audio session remains active while audio is playing
or paused and is deactivated when playback stops.

Audio-session behavior:

- an interruption pauses playback and records whether it was actively playing;
- interruption end resumes only when iOS reports `shouldResume` and ReadAloud
  had been playing before the interruption;
- unplugging an active output route pauses without automatically resuming;
- media-services reset rebuilds the `AVAudioEngine` / player-node graph,
  stops the invalidated playback operation, and leaves the durable content
  bookmark available for user-initiated resume.

One app-wide system-media controller owns `MPNowPlayingInfoCenter` and
`MPRemoteCommandCenter`. Loaded project runtimes do not register duplicate
remote-command handlers.

Now Playing publishes the current section title, project title, author when
available, project artwork, play/pause state, and finalized-audio duration /
elapsed position when a verified WAV is active.

Supported system commands:

- play / pause / toggle;
- skip backward 15 seconds;
- skip forward 15 seconds;
- previous / next chapter when available;
- direct playback-position scrubbing when compatible finalized audio exists.

Finalized WAV playback uses the live player sample clock for elapsed time,
system scrubbing, lifecycle checkpoints, and ±15-second seeking. The reported
position is never allowed to move backward behind the last observed durable
position. Streaming playback keeps the Phase 6/7 paragraph-boundary seek
fallback and does not invent an exact audio timeline.

When the app becomes inactive or enters the background, active runtimes persist
a playback checkpoint. Compatible finalized audio stores
`generationKey + audioRevision + exact seconds`; streaming stores the current
content bookmark. Relaunch never autoplays. Continue Listening reopens the
persisted item and resumes with the normal compatibility rules.

The persistent mini-player resolves the runtime that is actually playing rather
than whichever project is currently being browsed. It shows project title,
current chapter/status, chapter progress, play/pause, and opens that same
runtime in Reader when tapped.

## Storage and offline management

Phase 10 makes local project storage visible and separates rebuildable cache
from durable/offline media.

Settings now includes a Storage destination with:

- total ReadAloud project storage;
- per-project storage totals;
- source bytes;
- finalized generated audio bytes;
- temporary paragraph-cache bytes;
- artwork bytes;
- internal working-data bytes when present;
- remaining project-data bytes for metadata, normalized content, queue state,
  and other durable package files.

Storage accounting is derived from the actual project package on disk rather
than estimated from text or item metadata. Invalid/unattributed package bytes
are reported separately instead of being silently assigned to a valid project.

Cleanup semantics are intentionally explicit:

- **Clear Temporary Cache** removes only paragraph audio cache under
  `cache/paragraphs/`; it never removes retained source, project/content JSON,
  artwork, finalized WAV files, reading progress, or queue intent.
- **Clear Generated Audio** removes finalized item WAV/metadata, clears matching
  generation intent, and invalidates exact audio-position identity while
  preserving the content bookmark.
- **Clear Cache & Regenerate** removes both finalized audio and paragraph cache
  for the selected items before enqueueing fresh generation.
- **Delete Project** remains the only normal action that removes the complete
  `.readaloud` package.

Loaded runtimes coordinate maintenance with the Phase 8 generation queue.
Generation is paused while audio/cache files are being removed, affected
playback is checkpointed and stopped before finalized audio is deleted, and the
queue resumes only after durable state has been refreshed. This prevents a
worker from recreating an asset immediately after the user clears it.

The existing Offline Audio sheet remains the project-level generation manager:
it shows Ready / Generating / Waiting state, per-item audio sizes, Generate
Selected / Remaining, Retry, Regenerate, Clear Cache & Regenerate, and Clear
Generated Audio. The project Storage sheet now complements it with the complete
on-disk byte breakdown and safe cache cleanup.

Internal transaction/runtime files under `temp/` are shown as Working Data but
are not deleted by the user-facing temporary-cache action. They remain
system-managed so cleanup cannot race an active atomic audio commit or JobQueue
runtime write.

## Current scope

ReadAloud 1.0 implementation is complete through final release hardening: durable projects/import, structured Reader playback, persistent/offline audio, queue/prefetch generation, background/system media controls, storage management, and the AppFoundation product shell.

The final release pass intentionally keeps analytics disabled by default and uses the manual/mycli/Xcode release path instead of expanding CI. See `docs/RELEASE_CHECKLIST.md` for the remaining human submission checks. `PLAN.md` is historical.
