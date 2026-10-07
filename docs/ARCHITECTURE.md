# ReadAloud 1.0 Architecture

> Status: historical target architecture from before implementation. For the
> implemented 1.0 ownership/component map, use `CURRENT_ARCHITECTURE.md`.
> `PERSISTENCE_CONTRACT.md` remains authoritative for durable semantics.

## Purpose

This document defines the target architecture for turning the current ReadAloud prototype into a sophisticated offline reading and listening app.

ReadAloud 1.0 is not a deliberately reduced MVP. The implementation should aggressively reuse mature infrastructure from Spokio, TextExtractor, EpubKit, PDFKitAudio, KokoroCoreML, AppFoundation, and the existing ReadAloud playback pipeline.

The public app name may change later. **ReadAloud remains the internal engineering identity** unless there is a separate technical reason to rename it.

## Architectural principles

1. **Complete product, narrow boundary**
   - Build a deep document-to-speech reader.
   - Do not broaden 1.0 into accounts, sync, collaboration, web, or unrelated AI features.

2. **Reuse proven systems**
   - Adapt working architecture from sibling projects instead of creating simplified parallel systems.

3. **Project-centric persistence**
   - Every imported source becomes a durable internal project.
   - Projects own normalized content, generated audio, queue state, cache, playback state, and source metadata.

4. **iOS-native presentation**
   - Reuse Spokio's project model and runtime ideas, not its Mac window layout.

5. **Local-first runtime**
   - Reading, synthesis, playback, queueing, caching, and persistence must work offline.

6. **Stable internal identity**
   - Keep the repository, bundle identifier, internal types, and package extension stable even if the consumer-facing brand changes.


---

## Platform baseline

ReadAloud 1.0 follows the existing app portfolio and targets **iPhone on iOS 26+**.

The existing prototype's macOS target is not part of the product architecture and should be removed or parked during Phase 0. Mac Catalyst is disabled and iPad is unsupported.

The architecture may remain portable where doing so is free, but do not carry Mac-specific lifecycle, window, file-bookmark, or UI complexity into the iOS product.

Reusable dependencies should use exact stable semantic versions recorded in `docs/PRE_IMPLEMENTATION.md`. Generic app-shell/configuration conventions come from `docs/IOS_APP_BASELINE.md`.

---

## Reuse map

| Existing system | ReadAloud responsibility |
| --- | --- |
| Spokio | Project package layout, identity, manifest/items, queue/cache/audio concepts, artwork, project/item settings, generation lifecycle, deterministic fixture-model/asset substitution strategy |
| TextExtractor | General text/document extraction |
| EpubKit | EPUB metadata, TOC, chapters, cover, structured content |
| PDFKitAudio | PDF structure and audio-oriented extraction |
| KokoroCoreML | Local TTS engine plus canonical executable fixture generation/validation and published fixture archive (`1.1.0`) |
| Existing ReadAloud pipeline | Streaming synthesis, scheduling, playback, cancellation |
| JobQueue | Preferred durable queued-work and recovery infrastructure; adapt rather than rebuild if its model fits ReadAloud's project-local queue contract |
| AppFoundation | Entitlements, paywall, purchases, restore, themes, settings shell patterns, analytics integration, developer purchase tools |
| analytics-server | Product analytics backend |
| Existing GitHub workflow patterns | CI, TestFlight, release automation |

ReadAloud should contain only the integration and product-specific logic that belongs here.

SwiftLame is intentionally optional. The 1.0 persistence contract uses WAV; add SwiftLame only if compressed export/storage becomes an explicit product requirement.


---

## Model assets and fixture strategy

ReadAloud has two intentionally separate Kokoro asset paths.

### Production assets

The existing production path remains authoritative:

- pinned Kokoro SDK/runtime contract
- pinned immutable upstream manifest
- checksum and byte-size verification
- selected buckets/voices validated explicitly
- generated ReadAloud subset manifest
- build-time presence/shape validation

Production shipping builds (TestFlight/App Store) must use real verified assets. Debug/Release compiler configuration is independent of resource mode; explicitly marked fixture development artifacts may use either configuration.

### Fixture assets

Use the executable fixture published with **KokoroCoreML 1.1.0**. KokoroCoreML owns fixture generation because the fixture represents Kokoro's runtime contract; ReadAloud only downloads, verifies, stages, and consumes the published fixture archive.

Conceptually:

```
Production                         Fixture
─────────────────────────────────────────────────
Resources/Kokoro/                 testfixtures/kokoro/
KokoroRuntimeManifest.json        KokoroRuntimeManifest.json
coreml/*.mlpackage                coreml/*.mlpackage
voices/*.bin                      voices/*.bin
runtime/kokoro-vocab.json         runtime/kokoro-vocab.json
runtime/hnsf_weights.json         runtime/hnsf_weights.json
```

The fixture is not a mock API. ReadAloud should load it through the normal Kokoro public API using explicit fixture admission (`assetPolicy: .executableFixture`). Shipping builds remain production-only.

The fixture should use tiny synthetic/deterministic Core ML packages and runtime data that preserve the signatures, shapes, names, and minimum inference behavior required by KokoroCoreML.

### Released fixture contract

KokoroCoreML `1.1.0` already provides fixture generation and validation. ReadAloud consumes its published archive rather than implementing another generator.

The `fixture-executable-v1` profile contains duration t128 and one fixed **15-second** bucket (four model packages), three synthetic voices, and runtime/contract/provenance data. It produces a tone through the normal inference pipeline.

Use [the tagged fixture guide](https://github.com/hoangbkit/KokoroCoreML/blob/1.1.0/docs/executable-fixtures.md) as the contract source. ReadAloud staging/build validation must explicitly accept that synthetic profile while retaining all production checks for real mode. The prototype's production-only five-bucket validator cannot be used unchanged for fixture resources.

Align resource discovery/scheduling with the selected bundle, keep fixture/real staging and compiled caches separate, and preserve plain source packages for SDK-managed compilation.

### Fixture substitution

Development/CI may explicitly substitute:

```
testfixtures/kokoro
       ↓
Resources/Kokoro
```

using a dedicated environment flag or equivalent build setting.

Normal fast CI should therefore require no large Kokoro download.

### Release safety

Fixture assets must be impossible to mistake for production assets.

Shipping validation rejects fixture manifests/assets and synthetic model metadata, and shipping packaging always uses the production download + verification path. The manual Release workflow may also create explicitly marked fixture development artifacts in Debug or Release configuration; those artifacts cannot enter App Store Connect. See `docs/CI_RELEASE.md` for the authoritative matrix.

This allows fast deterministic integration checks without weakening production asset provenance.

---

## High-level system

```
                 ┌─────────────────────────────┐
                 │        Library / UI         │
                 └──────────────┬──────────────┘
                                │
                                ▼
                    ┌─────────────────────┐
                    │ ReadAloudProjectStore│
                    └────────────┬────────┘
                                 │
                   ┌─────────────┴──────────────┐
                   │                            │
                   ▼                            ▼
          ┌──────────────────┐         ┌──────────────────┐
          │ Project Importer │         │ Project Runtime  │
          └───────┬──────────┘         └────────┬─────────┘
                  │                             │
      ┌───────────┼───────────┐                 │
      ▼           ▼           ▼                 ▼
 TextExtractor  EpubKit  PDFKitAudio     ReadAloudPipeline
                                              │
                                   ┌──────────┴──────────┐
                                   ▼                     ▼
                              KokoroCoreML        Playback Queue
                                   │                     │
                                   └──────────┬──────────┘
                                              ▼
                                   cache / audio / state
```

AppFoundation wraps the app shell rather than the core reading model:

```
AppFoundation
├── entitlement / Pro
├── paywall / purchases / restore
├── settings shell
├── themes
├── analytics bridge
└── developer tools
```

---

## Internal project package

Use a package model intentionally close to Spokio.

Package extension:

```
.readaloud
```

Suggested layout:

```
<uuid>.readaloud/
├── project.json
├── source/
│   └── <stable-source-id>.<ext>
├── content/
│   ├── manifest.json
│   └── items/
│       ├── <item-id>.json
│       └── ...
├── queue/
│   └── jobs.json
├── cache/
│   ├── paragraphs/
│   └── artwork/
├── audio/
│   ├── <item-id>.wav
│   └── <item-id>.metadata.json
├── assets/
└── temp/
```

The package is app-internal data. It is not a user-managed document package in 1.0.

### Storage location

Use an app-owned Projects directory, for example:

```
Application Support/
└── Projects/
    ├── <uuid>.readaloud
    ├── <uuid>.readaloud
    └── ...
```

The physical package filename should use the stable project UUID. Display names come from project metadata.

This avoids rename and relocation complexity while preserving a robust package format.


---

## Durable contract source of truth

The concrete on-disk semantics are defined in `docs/PERSISTENCE_CONTRACT.md`.

That document is authoritative for:

- `project.json`
- content manifest/items
- queue persistence
- audio metadata
- schema versions
- stable identity
- content revisions
- generation keys
- audio compatibility
- background-generation recovery

Architecture changes that affect those semantics must update the contract and define migration behavior rather than silently changing persisted meaning.

---

## Project model

The project is the durable unit of the app.

Conceptually:

```
ReadAloudProject
├── id
├── schemaVersion
├── title
├── source
│   ├── type
│   ├── originalFileName
│   ├── sourceID
│   └── metadata
├── artwork
├── settings
│   ├── voiceID
│   ├── speed
│   └── generation preferences
├── playback
│   ├── currentItemID
│   ├── contentBookmark (revision + normalized-text offset)
│   ├── audioPosition? (generation key + audio revision + seconds)
│   ├── projectProgress
│   └── lastPlayedAt
├── createdAt
└── updatedAt
```

The exact Codable types should be designed during implementation, but the responsibilities above are required.

### Stable IDs

- Project IDs must be stable UUIDs.
- Source IDs must be stable.
- Content item IDs must be stable after import.
- Queue, cache, audio, and playback state must reference stable IDs instead of array indexes or titles.

---

## Content model

All input formats normalize into ordered project items.

```
source document
      │
      ▼
import adapter
      │
      ▼
content manifest
      │
      ├── item A
      ├── item B
      └── item C
```

An item may represent:

- EPUB chapter or section
- PDF section/page group
- text/document section
- pasted text block

Each item should support at least:

```
ReadAloudItem
├── id
├── title
├── order
├── text/content reference
├── source reference
├── metadata
├── voice selection mode + remembered custom voice?
├── speed selection mode + remembered custom speed?
└── generation state derived from runtime/storage
```

### Voice and speed inheritance

Resolve settings as:

```
item mode == custom → remembered custom value
item mode == inherit → project default ?? app default
```

Changing a project default or selecting Default must never destroy remembered custom item values. Persist `inherit`/`custom` selection modes independently for voice and synthesis speed, as defined in `docs/PERSISTENCE_CONTRACT.md`.


---

## Content normalization contract

Normalization rules are fixed before importer implementation:

- EPUB → meaningful spine/TOC chapter or section
- PDF → PDFKitAudio section/page grouping
- general document → TextExtractor structural section where reliable
- pasted text → one item by default

Item IDs are generated once at import and remain stable for the lifetime of the project. Re-importing the same external source creates a new project in 1.0.

Identity and compatibility are separate:

```
stable item ID
      +
contentRevision
      +
source locator
```

The item ID identifies the item; `contentRevision` determines whether derived audio/cache remains valid.

---

## Import architecture

Use format-specific adapters behind one importer boundary.

```
                       ┌─────────────────────┐
                       │ ReadAloudImporter   │
                       └──────────┬──────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              ▼                   ▼                   ▼
      TextExtractorAdapter   EpubKitAdapter    PDFKitAudioAdapter
              │                   │                   │
              └───────────────────┼───────────────────┘
                                  ▼
                         normalized project
```

Responsibilities:

1. Validate source.
2. Copy source into the internal package.
3. Extract metadata and artwork.
4. Normalize content into manifest/items.
5. Persist the initial project atomically.
6. Register the project in the library.
7. Recover or clean up safely on failure.

Do not let UI code perform extraction directly.

---

## Project store

The project store owns project discovery and durable mutations.

Suggested responsibilities:

- enumerate internal packages
- load lightweight library snapshots
- open full project metadata
- create/register imported projects
- rename project metadata
- delete projects
- update playback state
- update project settings
- manage schema migration
- surface corruption/unavailable states

The Library should consume snapshots, not eagerly hydrate entire projects.

---

## Runtime ownership

Opening or playing a project creates/uses a runtime layer that owns mutable work:

```
ProjectRuntime
├── projectID
├── queue controller
├── synthesis controller
├── playback controller
├── cache coordinator
├── persistence bridge
└── activity/state aggregation
```

Avoid placing queue or synthesis ownership directly in SwiftUI views.

The runtime should be reference-stable while a project is active so Library, Project Detail, Reader, mini-player, and background playback can observe the same state.

---

## Streaming and persistent audio

ReadAloud must support both immediate playback and durable generated audio.

```
play item
   │
   ├── full compatible audio exists
   │      └── play cached audio
   │
   └── no compatible full audio
          ├── synthesize first chunks
          ├── begin playback quickly
          ├── continue synthesis ahead
          ├── populate paragraph cache
          └── persist final item audio/metadata
```

Generated audio compatibility is determined by a deterministic generation key containing at least:

- item content revision
- resolved voice ID
- canonical speed
- Kokoro/runtime contract revision
- synthesis configuration version

For 1.0, final generated item audio is persisted as 24 kHz mono WAV PCM plus sidecar metadata. Filename existence alone never proves compatibility.

Never silently play stale incompatible generated audio.

Persist actual audio-to-source segment ranges in the sidecar metadata and maintain the audible content bookmark during streaming. Resume at exact seconds only for the same compatible finalized audio revision; regeneration or absent audio resumes from the bookmarked source segment. Voice/synthesis-speed changes preserve the content bookmark while invalidating the old seconds. Follow `docs/PERSISTENCE_CONTRACT.md` for reset/remapping rules.

---

## Queue and prefetch

Reuse/adapt Spokio's durable queue concepts.

Useful item states:

```
notGenerated
queued
generating
ready
failed
```

Supported operations should include:

- generate
- queue
- cancel
- regenerate
- clear cache and regenerate
- generate selected items
- generate remaining items
- prefetch upcoming items during listening

Queue persistence should survive ordinary app suspension/termination where practical. Jobs that cannot resume safely should recover into a clear retryable state.

### Background generation semantics

ReadAloud guarantees background playback, not indefinite background synthesis.

Queued generation may continue while iOS grants execution time, but it must persist intent/state and recover safely after suspension or termination. A stale persisted `generating` state must never be treated as proof that work is still running.

---

## Cache model

Retain multiple cache layers when useful:

### Paragraph cache

Purpose:

- avoid repeated synthesis work
- accelerate regeneration
- support incremental streaming
- improve resilience for long chapters

### Final audio

Purpose:

- instant replay
- offline-ready state
- background playback without repeated synthesis

### Artwork cache

Purpose:

- fast Library/project rendering
- retain normalized cover art independent of source parser behavior

Cache clearing must never destroy source content or required project metadata.

---

## Playback architecture

The existing `ReadAloudPipeline` remains the starting point for synthesis/playback integration.

Target responsibilities:

- play/pause/resume/stop
- seek backward/forward
- transition across chunks
- transition across items
- persist playback progress
- background audio
- audio interruption handling
- route changes
- Now Playing metadata
- remote command handling
- consistent state for Reader and mini-player

The UI should observe a playback state model rather than AVFoundation objects directly.

---

## AppFoundation boundary

AppFoundation should own generic product-shell concerns.

ReadAloud should integrate, not duplicate:

- Pro state
- purchase flows
- restore purchase
- paywall presentation
- plan management
- theme handling
- settings framework/patterns where available
- analytics integration hooks
- developer purchase simulation

ReadAloud-specific settings remain ReadAloud's responsibility:

- default voice
- default speed
- skip interval
- continuous playback behavior
- storage/cache policy
- generation/prefetch behavior

---

## Branding boundary

Keep internal identifiers stable:

```
Repository           ReadAloud
Bundle ID            com.hoangbkit.readaloud
Internal types       ReadAloud*
Package extension    .readaloud
Engineering docs     ReadAloud
```

The following may use a different future public brand:

```
CFBundleDisplayName
App Store name
App icon/branding
Marketing site
Screenshots/copy
```

Do not couple persistence or engineering identifiers to the marketing name.

---

## Schema versioning and migration

Every durable project must have a schema version.

Rules:

1. New app versions must not assume current in-memory models match old disk layout.
2. Migrations must be explicit and ordered.
3. A migration should be atomic where possible.
4. Source documents and generated audio must not be deleted merely because metadata needs migration.
5. Unsupported future schema versions must fail safely with a clear user-facing state.
6. Migration code should be independent from SwiftUI.

---

## Failure and recovery principles

Important operations should be transactional where practical:

- import
- manifest write
- project metadata write
- queue persistence
- generated audio finalization
- migration

Temporary files belong under `temp/` and should be cleaned after success or on next safe startup.

A failed import should not leave a half-registered project in the Library.

A failed generation should not make previously valid generated audio unusable unless replacement was explicitly committed.

---

## UI architecture

Primary navigation:

```
Library
  └── Project Detail
        └── Reader

Settings
```

A global mini-player may sit above the tab bar when playback is active.

SwiftUI screens should be presentation layers over:

- project store
- project runtime
- playback state
- AppFoundation app state

Avoid embedding persistence or extraction logic in views.

---

## Implementation guidance

When implementation begins:

- port concepts from Spokio deliberately; do not blindly copy Mac-only code
- prefer shared domain types over duplicated per-screen state
- keep import adapters separate from persistence
- keep runtime mutable state separate from durable Codable models
- preserve current working Kokoro pipeline behavior while integrating project persistence
- avoid premature cross-platform abstraction; optimize the app for iOS first
- keep the product and UI architecture iPhone-only; do not add iPad-specific abstractions or layouts
- follow `docs/PRE_IMPLEMENTATION.md` before product implementation
- follow `docs/PERSISTENCE_CONTRACT.md` for durable state
- keep generic executable Kokoro fixture generation in KokoroCoreML, with ReadAloud responsible only for consumption/substitution

---

## Architecture acceptance criteria

The architecture is successful when:

- EPUB, PDF, and general documents normalize into the same durable project model
- Library cards can load without fully opening every project
- one active runtime can drive Reader, mini-player, and background playback consistently
- generated audio and paragraph cache are reusable and safely invalidated
- playback resumes after relaunch
- queue/generation state survives normal lifecycle transitions safely
- project/item voice and speed inheritance is deterministic
- AppFoundation handles commercial shell concerns without duplication
- public branding can change without project-format or bundle-ID migration
- fast development/CI and explicitly marked development artifacts can use deterministic Kokoro fixtures without production downloads; TestFlight/App Store artifacts always reject fixtures
