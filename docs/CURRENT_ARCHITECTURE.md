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
- backed by on-device Kokoro Core ML speech synthesis
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

A single mini-player follows active playback across Library and Settings.

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
completed project. Free Library capacity is checked from the on-disk catalog
within the same serialized package-creation operation.

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
│   ├── paragraphs/
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
item custom (Pro)
  -> project default
      -> app default
```

Voice and speed inherit independently.

Saved premium selections are not destroyed when Pro expires. Their effective
behavior falls back to the allowed Free configuration until entitlement returns.

## Speech and playback

The low-latency path is:

```text
normalized text
  -> SpeechChunkScheduler
  -> KokoroEngine
  -> SpeechPlaybackQueue
  -> AVAudioEngine / AVAudioPlayerNode
```

The persistent path reuses the same synthesis/cache logic:

```text
paragraph cache
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

## Generation queue

`queue/jobs.json` is the durable generation intent.

JobQueue is used as an in-process executor, not as the durable source of truth.

Important rules:

- stale `generating` intent recovers to retryable queued work on cold load
- foreground streaming gets speech-model priority
- compatible finalized playback can allow Pro background generation while
  listening
- partial paragraph cache is reusable
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

Clear Temporary Cache removes only rebuildable paragraph cache.
Clear Generated Audio preserves source/project data and the content bookmark.
Delete Project is the operation that removes the complete package.

## Free and Pro

`ReadAloudAccessPolicy` centralizes product access.

Free includes:

- up to 3 projects
- Heart voice
- normal Reader/streaming playback
- single-chapter offline generation
- safe storage cleanup
- project-level narration defaults
- ReadAloud Light and Dark themes

Pro adds:

- unlimited projects
- all bundled voices
- per-chapter narration overrides
- bulk generation
- automatic prefetch
- generate while listening
- advanced regeneration
- premium themes

Views may present the paywall, but domain/runtime code also defends gated
operations so access rules do not depend on a specific UI path.

## Preferences

`ReadAloudPreferences` owns the app preference keys and effective defaults:

- default voice
- default speed
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
- fixture: deterministic executable fixture, development only

The canonical App Store submission path is manual/local using Xcode/mycli and
the steps in `RELEASE_CHECKLIST.md`.

The manual GitHub Release workflow is implemented for disposable mycli artifacts.
It builds the exact selected ref and lets the user choose Debug/Release and
fixture/real Kokoro resources. It publishes one unsigned iOS `.xcarchive`
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
