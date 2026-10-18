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
including retry and replay while its runtime remains loaded. The Library hero
follows that same session, including paused/preparing playback, before falling
back to the most recent book. Its primary action starts/continues listening only
when the global player is absent; otherwise it opens the Reader without changing
playback. Cover/title also opens the Reader. The global player owns transport
controls, including during preparation and pause. The hero is one card with
vertically stacked listening, Free weekly-usage, and active-generation sections.
Thin inset dividers appear only between visible sections. Pro users have no usage
section; an empty Library has no listening section, and the entire card disappears
when none apply. The usage row shows the local reset date and opens AppFoundation's
`LimitReachedUpsellFlow`; only its upgrade action opens the existing paywall.
Listening progress is separate from generation. The generation hero section opens
a native queue sheet adapted from Spokio iOS's list, row/progress, swipe-action,
and confirmation patterns. The sheet groups active chapter requests by book,
shows real executor progress and waiting reasons, and provides global Pause/Resume
plus per-job Cancel. There are no history, filter, search, or job-detail screens.
The section also remains available for queue storage/recovery issues even if no
requests could be read. It disappears after the last active request finishes or
is cancelled unless such an issue remains; an already-open sheet shows an empty
state. Explicit offline Generate buttons require Pro through the UI-only gate;
their upsell and the weekly listening-limit upsell share AppFoundation's flow.

While the native Library search is presented or its query is non-empty, the hero
and source-filter strip are hidden. Search spans all Library entries; it never
changes the selected source filter. Ending search with an empty query restores
that filter and the applicable hero sections. Empty search results suggest a new
query rather than a hidden filter. Empty-Library import guidance lives in the
list's empty state beside the existing floating Add menu.
The Chapters sheet lists the hero book in reading order, highlights the current
chapter, identifies the next chapter and shows Ready Offline only for compatible,
validated final audio. It is not a cross-book playback queue. Explicit offline
generation, cancellation and retry remain in project/chapter controls. The global
Pause Audio Generation switch is in Settings > Offline & Storage.

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

Reader/detail navigation reuses a loaded runtime without refreshing its project.
This keeps full chapter decoding, retained-source hashing and saved-audio hashes
off the warm navigation path and preserves the live playback bookmark/session.
Cold loads still use the validated single-flight loader. Explicit content or
settings changes use the existing refresh methods; playback still validates the
audio it loads. PDF effective text is restored from cached blocks in the shared
loader; Hero has no additional PDF preparation gate.

Views receive these through the SwiftUI environment.

### Voice previews

The runtime manager owns a separate `VoicePreviewController` (declared in the
existing voice-picker source to preserve owner-managed Xcode project files).
It owns only transient preview request/player state, not a book session. The
picker observes its preparation, active voice and error state. New book starts
and same-session resumes cancel previews synchronously, including remote media
commands. A ready preview pauses the current book before becoming audible and
leaves that book paused. Preparing books retain their pause flag and bookmark.
Interruption, route loss, scene deactivation, memory pressure and shutdown cancel
preview work; request IDs reject late callbacks/results.

`VoicePreviewCache` performs disk access/PCM encoding off the main actor and
uses the shared ONNX engine for cache misses without unloading it. Cache keys
reuse generation compatibility inputs (text digest, voice, speed 1.0, runtime
revision, pronunciation mode and synthesis config version), with a preview/WAV
namespace. Validated 24 kHz mono WAV files are atomically written to
`Library/Caches/VoicePreviews/`; missing or corrupt files regenerate. These are
disposable caches, outside project packages. Preview text is a separate app-wide
UserDefaults preference edited through Voice Options > Preview Text; draft edits
and Reset are not committed until Save. It is bounded by the existing 300-unit
synthesis input safety budget. Previews bypass voice-application and listening
gates and have no listening meter, floating card or Now Playing item.

## Library and import

`LibraryModel` uses `ProjectStore.catalog()` to load lightweight project
snapshots. The Library does not hydrate all chapter content just to render the
shelf. The hero loads its featured runtime, and recovery separately loads projects
with durable pending generation intent.

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
web articles -> ArticleURLLoader -> TextExtractorWeb
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

Web articles use the `TextExtractorWeb` product from TextExtractor **1.2.0**
(tag `1.2.0`, revision `2c1de305453ae2e0766181bf3c403aa1a91f2562`).
The core `TextExtractor` product remains the document importer. Article fetching,
redirect/public-URL checks, MIME/download limits and retained HTML remain app-owned.
The existing detached import worker passes the final redirected URL and HTML to
`WebArticleExtractor`; the package owns decoding, main-article selection and typed
block extraction. ReadAloud consumes `WebArticleResult.text`, derived from those
ordered blocks, then applies its existing speech normalization and stores one
article item. Nested-block deduplication, code/table line structure and metadata
come from the package; ReadAloud no longer imports Readability/SwiftSoup directly.
Author/site/language/publication metadata and original-versus-final URL roles
remain intact. Typed package errors map to existing app import errors, with
cancellation preserved. Existing saved articles are not reparsed or rewritten.

TextExtractor 1.2.0 requires a Swift 6.2+ compiler through SwiftReadability; the
runtime minimum remains iOS 26. `project.yml` links both TextExtractor products
and removes the app's direct Readability/SwiftSoup dependencies. The checked-in
Xcode project and lockfile remain owner-managed; regenerate/resolve them on the
Mac before a direct local build. The existing manual Release workflow generates
its project from `project.yml` before archiving. No build/test run was performed
for this integration.

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

`ProjectRuntimeManager` is the app-level playback coordinator. Its explicit
`playerRuntime` is independent from the browsed `activeRuntime`; no dictionary
scan or inactive-book fallback chooses a playback owner. Every new playback
operation claims ownership synchronously before asynchronous preparation,
stopping the previous runtime's output and cancelling its playback work. The
system-media controller mirrors that owner and publishes its runtime state.
There is no separate copy of progress or playback state in the coordinator.

One `ProjectGlobalPlayerHost` at the root navigation stack renders the compact
or expanded card throughout Library, book details, and Reader. The Reader has
no player host of its own. Opening the Reader from the player pushes onto the
same stack and collapses the card; opening it while already reading that book
follows the playing passage instead of pushing another Reader. Expansion state
belongs to the coordinator and resets when switching books or closing.

Book-detail Start/Continue and Reader chapter-listening actions use `listen`:
the same active/preparing chapter is reused, a paused chapter resumes, and a
different chapter/book starts through the ownership handoff. Transport uses
`togglePlayer` for pause/resume and terminal-state retry/replay. Browsing a book
or selecting a chapter to read does not start or interrupt audio. Controls follow
the playback owner while the Reader can browse another chapter or book. Voice
and speed sheets capture their target runtime and chapter when opened.
Transport targets are at least 44 points, with VoiceOver labels and an
adjustable scrubber. The behavior matrix is in `PLAYBACK_BEHAVIOR.md`.

A cold PDF restores its selected policy from cached typed blocks. Reader,
streaming, offline generation, highlighting and audio/bookmark validation use
that effective text, even though saved chapter text stays unchanged. Source
parsing is restricted to import; runtime loading/playback never opens a parser.
On a cache miss, saved text remains readable. Default-policy saved text remains
playable; custom-policy generation/playback defers until its projection is
available. Queue recovery also defers rather than invalidating intent against
unavailable custom-policy text. No background work presents preparation UI.

Saved audio exposes elapsed/remaining time and exact scrubbing. Live synthesis
exposes chapter source position and passage seeking; skip seconds are approximate
and stay within the current chapter. Dragging commits once on release and is
discarded if the chapter, time mode, or preparation state changes. Views own only
the temporary drag value, not playback work.

The runtime owns an optional session sleep timer (5/15/30/45/60 minutes or end of
chapter). It survives Reader dismissal and seeks, pauses at its deadline, and is
cleared on explicit Stop, shutdown, completion, or failure. It is not persisted
across process restarts. End-of-chapter takes precedence over automatic chapter
continuation. Close removes the explicit owner, so older sessions cannot return
as fallback cards. Shutdown/deletion also releases ownership. Interruption
resume is tied to the interrupted playback operation; a new session or explicit
pause cancels automatic resume. ImageIO downsampling bounds displayed cover
thumbnails to 512 pixels.

See AUDIO_PLAYER_REVIEW.md for source findings and pending device review.

## Generation queue

`queue/jobs.json` is the durable generation intent.

JobQueue is used as an in-process executor, not as the durable source of truth.

Important rules:

- launch and foreground entry discover pending jobs in dormant projects, using
  the same single-flight loader without changing the selected reader/book
- stale `generating` intent recovers to queued work only when its generation key
  still matches; changed settings mark old intent failed, and compatible validated
  final audio completes matching intent without resynthesis
- recovery preserves job IDs and attempts, skips already loaded runtimes, retains
  inaccessible packages and reports restoration errors in Settings
- an app-wide admission coordinator grants only one project executor a slot;
  revoked/retiring full jobs drain before another project is admitted
- foreground streaming (including a paused live stream) revokes offline admission
  across every project and drains it before requesting live chunks
- compatible finalized playback can allow background generation while
  listening whenever the user enables it
- partial chunk cache is reusable
- completed finalization and compatible final-file replay request best-effort
  reclamation of exact redundant chunk pairs after all chapter usages and native
  producers release them; readers arriving during cleanup wait safely
- final-pair validation and chunk deletion share one ProjectStore actor turn;
  corruption, replacement or incompatible identity keeps the chunks intact
- each item's pronunciation mode is captured for inference and final metadata;
  finalization stores its mode-qualified runtime identity, and changing the mode
  invalidates active generation even when voice/speed stay unchanged
- replacing finalized audio preserves the previous known-good pair until the
  new pair commits
- the persisted global pause retains intent and blocks all offline admission;
  memory pressure suspends automatic recovery until explicit work resumes it
- inactive/background scenes without listening intent revoke separate offline-job
  admission, cancel prefetch/recovery work and defer reclamation; live read-ahead
  still tries to fill its 20-chunk window. Returning active resumes eligible
  offline work without changing the saved global pause preference
- preparation/buffering count as listening intent; paused/stopped/finished sessions
  do not. Foreground explicit offline generation remains available
- project offline controls show why pending work is paused or waiting
- background synthesis is opportunistic; it is not kept alive artificially

### Global queue presentation (issue #59 pass 2)

`ProjectRuntimeManager.offlineGenerationQueueBooks` overlays live runtime requests
on transient per-book snapshots of the same durable queue files. Loaded runtimes
replace whole snapshots, including an empty queue, so active work is not counted
twice and completed requests are not revived. Runtime release preserves its latest
projection until metadata refresh completes. Library/catalog and runtime membership
changes, opening the sheet, pull-to-refresh, and cancellation refresh dormant work.

`ProjectStore.offlineGenerationQueueSnapshot` reads catalog/queue/manifest metadata
and reuses loaded chapter titles, reading title-only headings for dormant pending
chapters sequentially. It does not decode
chapter text, initialize runtimes/models, hash every final WAV, or parse sources.
Unreadable queues and headings produce visible notices while leaving packages
intact. Dormant persisted `generating` records display as waiting for restoration,
never as a live process. This adds no durable schema or second queue store.

`ProjectQueueController` exposes observable execution identities and JobQueue progress.
Revocation/yield clears live progress; execution identities, not a saved `generating`
state, determine which row is Processing. Fractions describe measured chunk
preparation only. Finalization explicitly reports an indeterminate "Finalizing
chapter…" phase; a row leaves active work only after its durable terminal state.

Queue Pause/Resume reuses the persisted generation preference, including its
existing upcoming-chapter preparation scope. It does not control audible playback.
Cancel compares the exact job ID, generation key, and active state in one ProjectStore
actor turn, removes only that intent, and cooperatively removes its executor before
refreshing chapter status. It does not load dormant runtimes just to cancel or use
audio invalidation/clear-cache paths. Already-loading recovery is reconciled after
its load finishes. Prepared chunks, listening consumers, valid final audio, and
bookmarks remain intact. Late executor events cannot recreate removed intent.

The sheet owns presentation/confirmation state only; the manager owns commands.
Viewing and all queue controls are available regardless of Pro and have no upsell.

## Storage

Issue #61 pass 1 adds `cache/parsed/blocks.json` alongside saved chapter text.
Import adapters pass their existing parser output through the coordinator to the
staged package save: complete typed PDF items plus chapter mappings, typed article
blocks, EPUB chapter/TOC output, document segments/raw text/timing, and pasted text.
No parser/package capabilities or default saved-text behavior change.

ProjectStore and its persistence bridge expose disk-only cache load/save methods.
Cache identity uses the retained source and producer contract, independently of
listening options. A miss returns nil and cannot invoke a parser or schedule
preparation. Temporary audio cleanup preserves this sidecar. Runtime filtering
uses the cached PDF projection. EPUB, article and document Readers continue to
use their existing saved-text paths and do not re-extract sources.

Only an explicit block-dependent action can offer the preparation sheet when
output is unavailable. A visible foreground presenter explains the need; no work
starts before Start Processing. The operation reuses import adapters on retained
local bytes (saved HTML for articles), reports progress and supports Cancel or
dismissal. Complete output atomically replaces only the parsed sidecar, preserving
source, saved chapter files, manifest and stable IDs. Cancellation/teardown rejects
late results and pending actions; shutdown drains the parser before deletion.
The requested action resumes only while its presenter/app remain active. There
is no pending presentation or action to replay on foregrounding, and passive
loading, queue recovery and prefetch cannot offer or start preparation.

PDF filtering selects saved kinds/classifications in memory and persists policy
metadata only, with a safe bookmark reset if its chapter text changes. Changed
audio work is drained and incompatible pending jobs are removed through existing
invalidation; chapter files, the manifest and full parsed cache are not rewritten.
New PDF imports retain empty default-filtered chapters so their item IDs survive
inclusion changes. Reader layout remains lazy for the current chapter. A bounded
single-project derived-text cache in ProjectStore avoids repeated block decoding
for audio/status/checkpoint calls; ordinary dormant queue summaries do not load
typed content. The active runtime can reuse loaded blocks even if its disk cache
is subsequently unavailable.

Storage categories are measured from the real project package:

- Source
- Generated Audio
- Temporary Cache
- Artwork
- Project Data
- Working Data

`ProjectStorageUsageSection` is the shared presentation of that breakdown.

Finalization can reclaim redundant chunk cache automatically. Cached readers,
read-ahead and assembly hold item-scoped usage; complete offline jobs hold their
usage through finalization. Cleanup reserves admission and validates the final
pair's checksum/current identity and expected audio revision before deleting exact
owned keys. Cache invalidation and memory/shutdown paths drain cleanup alongside
producers. Cleanup failure does not fail listening or generation. Incomplete audio,
other generations and other chapters remain available for recovery.

Clear Temporary Cache removes rebuildable chunk cache (and any legacy paragraph cache).
Clear Generated Audio preserves source/project data and the content bookmark.
Delete Project is the operation that removes the complete package.

## Free and Pro

Pro unlocks **unlimited listening, offline Generate buttons, Kokoro voices, and extra themes**.

Free includes unlimited projects, imports, reading, 3 hours/week of playback,
live synthesis/read-ahead, prefetch, generate while listening, existing
regeneration/retry controls, project/chapter narration overrides, and all queue
viewing/management actions. Voice application follows its separate approved gate.

- **Offline preparation (issue #59):** `ReadAloudOfflineGenerationGate` checks
  the current PurchaseManager entitlement only at the Generate Offline/Current,
  Selected, Remaining, and All UI entry points in book details, Offline Audio,
  Reader, and the Reader Chapters sheet. Free taps show the shared AppFoundation
  upsell before any enqueue, preparation, or cache mutation. Native labels display
  a Pro indicator. Runtime/model enqueue APIs, the execution engine, scheduling,
  recovery, Pause/Resume/Cancel, retry, and regeneration remain ungated. Already
  accepted requests continue after entitlement expiry. There is no pending action
  to automatically execute after purchasing or dismissing the upsell.

- **Contextual upsells:** `ReadAloudProUpsell` uses AppFoundation's
  `LimitReachedUpsellFlow` for usage-card taps, weekly exhaustion, and offline
  Generate-button taps. Its explicit upgrade action opens `ReadAloudProPaywall`.
  It derives the comparison from the same registered commerce features as the
  paywall and includes the actual usage/local reset time for listening. The
  previous custom listening-limit sheet is removed. Limit enforcement and saved
  playback position remain runtime-owned; dismissing or purchasing never auto-plays.

- **Voices:** Heart (`af_heart`) is Free. The other 27 English voice styles
  require Pro. All voices may be previewed or favorited regardless of purchase;
  applying a Pro voice requires verified entitlement. Saved premium voice
  preferences are preserved and fall back to Heart when Pro is inactive.
- **Themes:** ReadAloud Light/Dark are Free. Additional themes remain Pro-gated
  through the AppFoundation theme catalog.

- **Listening:** `ReadAloudListeningAllowance` is an observable, device-wide ledger
  owned by the runtime manager and persisted in UserDefaults independently of
  project packages. The Free allowance is centralized in
  `ReadAloudAccessPolicy.weeklyListeningSeconds` (initially 3 hours). Pro playback
  does not consume it. Weeks start Monday 00:00 UTC and reset dates display locally.
  Both live and saved playback use `SpeechPlaybackQueue`; rendered sample-time
  intersections with scheduled audio intervals exclude preparation, buffer gaps,
  pause, and seek offsets. A 250 ms monitor pauses the current session at exhaustion;
  completion, pause/stop, scene, and entitlement transitions flush accounting.
  Persistence is checkpointed at most every 5 seconds while playing and at lifecycle
  boundaries. Abrupt termination may lose at most the uncheckpointed tail. Usage is
  local to an installation; cross-device/reinstall enforcement is not implemented.
  Quota pause retains the session/bookmark. New starts/seeks and all resumes use
  the same admission check; the root presents the reset time and a Pro entry point.
  Purchases/weekly rollover unlock subsequent user-initiated playback, never auto-play.

No listening allowance check restricts reading, importing, offline generation,
regeneration, prefetch, or narration-speed controls. Voice previews are excluded.

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

Settings groups user controls in this order: Plan, Listening, Appearance,
Offline & Storage, Advanced, Support and About. Listening combines default voice,
default speed, skip interval and chapter continuation. Offline & Storage exposes
the generation-pause switch and the existing storage-management screens; an enabled
pause switch maps directly to the persisted paused state, without inverting its
meaning. Storage cleanup controls remain available to all users.

Advanced > Advanced Listening contains pronunciation recovery, Prepare Upcoming
Chapters (Off/Next Chapter/Next 2 Chapters), and Generate While Listening. These
retain their existing preference keys, defaults and runtime reconciliation. The
fixed 20-chunk playback lookahead has no user setting. About shows the app version
and an offline/on-device speech footer.

## Analytics and diagnostics

ReadAloud 1.0 does not enable product analytics collection.

The ONNX resource diagnostics/offline test screen, old Kokoro prototype reader
and live performance dashboard are compiled only for DEBUG and reachable only
from Developer Tools. App-specific developer destinations are grouped into
Speech Diagnostics, Prototypes and UI Previews, alongside the shared onboarding
replay and AppFoundation developer controls. Raw generation-recovery details are
available under Speech Diagnostics; Release Settings shows an actionable error
without engine/storage details. Plan actions and voice/theme entitlement rules
are unchanged.

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

Detail Start/Continue Listening starts playback and opens the Reader. The Library
hero starts playback when the player is absent; otherwise it only opens the Reader.
Reader layout and playback need separate resource bounds. Reader layout uses source-preserving,
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

In-flight cache entries track each consumer separately. Cancellation releases
the caller promptly, cancelling the producer only when no valid consumer is
left. Cancelled producers remain awaitable until native work unwinds; entry
identities prevent stale write-back and same-key replacement races.

Runtime audio mutations close affected cache admission, pause/drain complete
offline jobs, and drain stopped playback/finalization before changing narration
identity, changing effective PDF text, clearing caches/audio, or deleting a project.
Library deletion goes through ProjectRuntimeManager instead of deleting a
package underneath a live runtime. Completed compatible chunk files survive
ordinary stop and runtime shutdown.

The shared ONNX engine has lifecycle identity checks around suspension points
and nested admission tokens. Memory-pressure cleanup holds an app-wide engine
token while all loaded runtimes drain their cache producers, jobs and stopped
playback before unload. New inference cannot enter during release. Native
session.run remains synchronous and is not interrupted mid-call.

The live producer prepares at most 20 chunks ahead of the audible chunk while
listening. `ChunkReadAhead.liveReadAheadChunkLimit` is an internal developer
constant, with no persisted preference or user-facing setting. Before first audio,
the initial window contains 20 chunks from the requested start index. Completed
chunks live on disk; only the current synthesis result and the player's existing two PCM buffers need decoded
audio memory. The producer runs through reader paragraph boundaries without
awaiting paragraph-audio drains. Live listening blocks opportunistic JobQueue
synthesis; the shared cache supports offline regeneration/reuse when that queue
is permitted to run. Upcoming-chapter jobs still follow the existing prefetch
chapter-count preference.

The currently **audible** chunk drives the Reader highlight, live chunk-bounded
scrub/skip, and content bookmark. The final chapter WAV stores source/sample
segments per chunk for exact saved-file seeking and highlighting. The
generation version change invalidates incompatible legacy derived audio
without changing original source content, project IDs, or project schema.

No new user-facing read-ahead setting is added.

## Playback continuity and paused read-ahead

Live chunk playback classifies player snapshots as initial preparation,
audible playback, buffering, user pause, or expected final drain. A drained
queue only counts as starvation when more chunks are expected after audible
playback has begun. Returning audio restores playing; cancellation remains a
normal stop, and a failed chunk preserves the last audible checkpoint for retry.
Runtime buffering remains active work, so opportunistic generation cannot take
priority while the listener waits. Player copy shows Preparing audio and system
Now Playing reports a zero rate while output is not audible.

Playback pause stops sound without cancelling live read-ahead. The producer tries
to fill the same 20-chunk window in foreground or background, then waits naturally
because the audible position no longer advances. There is no separate live
scene/pause policy, paused warm allowance or pause-state actor notification.
Capacity and readiness use cancellable continuations rather than polling.
Audible progress frees capacity when listening resumes. Stop/seek/chapter changes,
invalidation, shutdown and memory pressure still cancel the producer and release
its cache consumer; completed compatible disk chunks stay. Seek/chapter
replacement creates a fresh window, and stale cancelled native results cannot
commit over replacement work.

Scene inactivity without listening intent still stops separate queued offline
generation, next-chapter prefetch and dormant recovery, and defers cleanup. This
is temporary admission state, separate from the persisted global generation
preference and the bounded live producer. Foreground entry resumes eligible work;
a cancelled recovery scan cannot swallow a rapid return. Assembly checks offline
admission between chunks. Background read-ahead only tries while iOS permits:
paused audio does not guarantee execution until the window fills. No silent
audio or other keepalive is used.

Local OSLog diagnostics record starvation intervals and their end reason,
initial audible latency, chapter starts and application lifecycle transitions.
They contain no source text, project identifiers or analytics events. The audio
output and monotonic clock are injectable for deterministic continuity tests;
production still uses the existing AVAudioEngine/player-node queue.



## Playback, scheduling and reclamation release checks

`RELEASE_CHECKLIST.md` contains the pending physical-iPhone matrix for finalized
and live playback, starvation/recovery, lock screen, chapter transitions, route and
session events, low memory, cancellation, dormant-job recovery and reclamation.
The deterministic regression source uses synthetic audio without ONNX inference;
these tests do not establish sustained live inference under screen lock. Runtime
acceptance remains pending owner-approved builds/tests and physical-device checks.



