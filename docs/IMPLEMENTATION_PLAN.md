# ReadAloud 1.0 Multi-Phase Implementation Plan

## Purpose

This plan turns the architecture, product scope, and iOS design in this PR into an implementation sequence for ReadAloud 1.0.

The goal is a sophisticated, nearly complete first release built by aggressively reusing existing systems rather than rebuilding them.

This is not an MVP plan. Each phase should leave the codebase in a coherent state and unlock the next layer of the product.

---

# Phase 0 — Integration Baseline

## Goal

Prepare the repo so the product work can build on stable package boundaries and known dependencies.

## Work

- keep the existing ReadAloud Kokoro streaming prototype working as the baseline
- pin the reviewed stable package baseline from `docs/PRE_IMPLEMENTATION.md` using XcodeGen `exactVersion`:
  - AppFoundation `1.6.4`
  - EpubKit `1.1.0`
  - PDFKitAudio `1.1.0`
  - TextExtractor `1.1.0`
  - KokoroCoreML `1.1.0`
  - JobQueue `1.0.0`
- keep SwiftLame `1.0.0` optional until compressed export is actually required
- do not implement product phases against moving `master` branches
- align the app to the portfolio baseline: iPhone only, iOS 26+, `TARGETED_DEVICE_FAMILY = 1`
- remove or park the prototype `ReadAloudMac` target; it is not part of ReadAloud 1.0
- keep Mac Catalyst disabled
- adopt the shared setup in `docs/IOS_APP_BASELINE.md`:
  - XcodeGen source of truth
  - owner-managed checked-in generated Xcode project and `Package.resolved`
  - Swift 6 / complete strict concurrency
  - StoreKit config
  - explicit privacy manifest
  - modern AppFoundation app-root integration
  - standard Settings shell
  - AppStore metadata directory
  - manual branch-aware Fast CI / Full CI / Release workflows per `docs/CI_RELEASE.md`
- retire the prototype README rule that generated Xcode project files are never committed
- define source folders for:
  - Projects
  - Import
  - Library
  - Reader
  - Playback
  - Settings
  - App shell
- establish internal naming conventions:
  - ReadAloud remains the engineering name
  - `.readaloud` remains the package extension
  - public display/App Store name remains independent
- keep existing prototype diagnostics available behind developer-only UI rather than deleting useful instrumentation

## Do not do yet

- no Library UI
- no import UI
- no AppFoundation paywall
- no queue migration
- no redesign of the playback pipeline

## Exit criteria

- project configuration reflects iOS 26+ iPhone-only 1.0 scope and the shared portfolio setup
- reusable dependencies are pinned to the exact stable versions documented in `docs/PRE_IMPLEMENTATION.md`
- project builds with all required reusable packages available
- existing Kokoro read/play path still works
- folder/module boundaries are ready for product code
- no consumer-facing behavior has regressed


---

# Phase 0A — Fixture Model and Deterministic Asset Setup

## Goal

Adopt Spokio's fixture-model strategy so normal development and CI can exercise the real Kokoro resource-loading and synthesis contracts without downloading or bundling the full production model set.

The canonical executable fixture generator and model assets belong in **KokoroCoreML**. ReadAloud owns only fixture consumption/substitution and app-level integration.

This is foundational infrastructure, not an optional test optimization.

KokoroCoreML `1.1.0` now ships the executable fixture capability and a matching published fixture archive. The upstream blocker is complete.

Phase 0A is therefore a **ReadAloud integration phase**, not KokoroCoreML implementation work.

ReadAloud should:

- pin KokoroCoreML `1.1.0` with `exactVersion`
- download the matching `kokoro-fixture-1.1.0.tar.gz` release asset
- verify its published SHA-256
- stage the extracted `kokoro/` directory as plain app resources for fixture builds
- load it with `assetPolicy: .executableFixture`
- keep shipping/production builds on `.productionOnly`
- use KokoroCoreML's production-asset guard before production packaging
- never copy or maintain KokoroCoreML's Python fixture generator in ReadAloud

ReadAloud should use **two fixture tiers**:

```
Tier 1 — filesystem/manifest fixture
  ↓
fast provider/path/hash/manifest validation

Tier 2 — executable Core ML fixture
  ↓
real MLModel.compileModel()
  ↓
real MLModel loading
  ↓
real prediction()
  ↓
end-to-end Kokoro pipeline plumbing
```

The existing KokoroCoreML bundle fixture is useful for Tier 1, but it explicitly does not contain real Core ML models. ReadAloud needs Tier 2 as well.

## Ownership

KokoroCoreML `1.1.0` owns and publishes:

```
KokoroCoreML 1.1.0
├── executable fixture generator
├── fixture .mlpackage models
├── fixture manifest/runtime/voice assets
├── fixture contract validation
├── kokoro-fixture-1.1.0.tar.gz
└── published checksum/validation reports
```

ReadAloud owns only:

```
ReadAloud
├── exact package pin to KokoroCoreML 1.1.0
├── download/checksum verification of the matching fixture archive
├── fixture resource staging/substitution
├── .executableFixture admission in fixture builds
├── .productionOnly admission in shipping builds
└── app-level integration and iPhone validation
```

Do not duplicate fixture-generation logic inside ReadAloud.

## Tier 1 — Filesystem and manifest fixture

Reuse the existing KokoroCoreML fixture approach for checks that stop before Core ML compilation.

It should cover:

- bundle directory shape
- runtime manifest decoding
- hashes
- byte sizes
- required model package paths
- voice paths
- runtime asset paths
- path traversal/symlink protections
- provider validation
- schema validation

This tier should remain extremely small and fast.

## Tier 2 — Executable Core ML fixture

Consume the real executable fixture models published with KokoroCoreML `1.1.0`.

These are tiny valid `.mlpackage` models that compile, load, and execute through the normal Kokoro runtime. They are not mocks or placeholder files.

### Released profile and contract source

Consume the published `fixture-executable-v1` profile exactly as released:

- duration t128 plus one fixed **15-second bucket**
- four executable model packages
- three synthetic voices: Heart, Bella, Michael
- finite 24 kHz mono PCM containing a synthetic tone

The profile does not contain 3-, 7-, 10-, or 30-second acoustic model packages. Do not invent additional fixture buckets or rebuild them in ReadAloud.

The exact model names, tensor signatures, dtypes, validity masks, and geometry are owned by KokoroCoreML's tagged contract descriptor. Use these sources rather than maintaining another approximate signature list:

- [KokoroCoreML 1.1.0 fixture guide](https://github.com/hoangbkit/KokoroCoreML/blob/1.1.0/docs/executable-fixtures.md)
- [Fixture contract descriptor](https://github.com/hoangbkit/KokoroCoreML/blob/1.1.0/swift-tts/Sources/KokoroTTS/Resources/KokoroRuntime/KokoroFixtureContract.json)
- [Published fixture archive and reports](https://github.com/hoangbkit/KokoroCoreML/releases/tag/1.1.0)

## Fixture layout

Preserve the extracted directory and all of its files, including contract/provenance files. Relevant paths include:

```
testfixtures/
└── kokoro/
    ├── KokoroRuntimeManifest.json
    ├── KokoroFixtureContract.json
    ├── FixtureProvenance.json
    ├── coreml/
    │   ├── kokoro_duration_t128.mlpackage/
    │   ├── kokoro_f0ntrain_t600.mlpackage/
    │   ├── kokoro_decoder_pre_15s.mlpackage/
    │   └── kokoro_decoder_har_post_15s.mlpackage/
    ├── voices/
    │   ├── af_heart.bin
    │   ├── af_bella.bin
    │   └── am_michael.bin
    └── runtime/
        ├── kokoro-vocab.json
        └── hnsf_weights.json
```

## ReadAloud integration changes

Phase 0A must update the app's staging/build/runtime boundary, not just copy the archive:

- the existing `validate-kokoro-assets-for-build.sh` assumes a production `custom` profile, verified HF provenance, and all five production buckets. Add an explicit fixture validation path for `fixture-executable-v1`; keep production checks intact for real assets.
- select validation and `assetPolicy` from the same explicit build resource mode.
- fixture validation preserves truthful synthetic provenance (`hf_provenance_verified: false`), hashes, schema/path checks, and the exact four-package set. Never relabel the fixture as production to pass the old guard.
- resource discovery and scheduler integration must respect the selected bundle's available bucket set. Keep short source chunks for streaming, but do not require a 3-second model from a fixture that only supplies 15 seconds.
- use the normal public Kokoro API for inference. CPU-only fixture execution can provide repeatable integration coverage; separately requested iPhone validation should cover the intended device compute policy.
- use separate staging/cache identities for fixture and real resources so changing modes cannot retain stale assets or compiled models.
- stage source packages as plain folder resources; preserve SDK-managed compilation into a writable cache.
- include Misaki/MLX package resources through the normal Xcode build path.

## Fixture generation status

KokoroCoreML `1.1.0` already owns and publishes the generator, models, archive, checksum, and validation reports. Upstream fixture implementation is complete and is not a new PR prerequisite.

ReadAloud consumes the release. It does not duplicate the generator or claim that upstream macOS validation proves iPhone runtime behavior.

## Normal runtime path

The fixture must work through the **normal runtime boundary**.

The intended path is:

```
KokoroResources
      ↓
Kokoro runtime manifest
      ↓
KokoroSDKModelProvider
      ↓
MLModel.compileModel()
      ↓
MLModel(contentsOf:)
      ↓
prediction()
      ↓
KokoroPipeline
      ↓
audio samples
      ↓
ReadAloudPipeline
```

Avoid adding a test-only `FakeKokoroEngine` for integration coverage when the executable fixture can exercise the real path.

## Asset substitution

Add one explicit fixture mode, for example:

```
READALOUD_CI_USE_TEST_MODELS=1
```

When enabled:

```
testfixtures/kokoro
        ↓
Resources/Kokoro
```

or use an equivalent isolated resource-root override if that avoids mutating the checkout.

Requirements:

- fixture mode must be explicit opt-in
- normal fast CI must not download production models
- normal Kokoro resource/provider code must remain in use
- fixture setup must fail immediately if the fixture bundle is missing, malformed, or no longer satisfies the runtime contract

## Production asset path

Keep the current ReadAloud production asset system unchanged:

- pinned Kokoro SDK/runtime revisions
- immutable upstream manifest
- SHA-256 verification
- expected file sizes
- verified voice set
- verified bucket set
- generated ReadAloud subset manifest
- build-time asset validation

Fixture work must not weaken those guarantees.

## Prevent fixture leakage into shipping artifacts

Apply the resource/distribution matrix in `docs/CI_RELEASE.md`.

Debug and Release are compiler configurations. Fixture development builds may use either configuration, including a manual Release workflow artifact. TestFlight/App Store distribution always requires verified real assets.

Use multiple safeguards:

- explicit fixture manifest/profile marker and build resource mode
- fixture admission only for a development artifact selected as `resources=fixture`
- shipping runtime fixed to `.productionOnly`
- shipping staging guard rejecting fixture manifests and synthetic model metadata before compilation
- production packaging always using the real download/verification path
- clearly marked fixture artifact names and no App Store Connect upload path for fixtures

Do not weaken real-asset checks to make fixture builds pass.

## Intended coverage

Use Tier 1 fixtures for:

- manifest tests
- path/security tests
- digest tests
- provider validation that stops before compilation

Use Tier 2 executable fixtures for integration checks involving:

- resource discovery
- manifest parsing
- Core ML compilation
- Core ML loading
- Kokoro engine initialization
- model mounting/loading lifecycle
- voice lookup
- synthesis pipeline plumbing
- non-zero duration propagation
- F0/N stage propagation
- decoder stage propagation
- waveform generation
- ReadAloud playback pipeline plumbing where appropriate
- project/runtime integration that depends on a real Kokoro-shaped runtime
- JobQueue integration when durable generation queue work begins

Use real production assets only when explicitly validating:

- actual speech correctness
- voice quality
- real model performance
- real memory usage
- production model compatibility
- production shipping builds

## Exit criteria

- Tier 1 filesystem/manifest fixture remains available for ultra-fast validation
- Tier 2 fixture contains real executable Core ML `.mlpackage` models
- Core ML fixture models compile successfully through `MLModel.compileModel()`
- Core ML fixture models load through the normal provider
- each Kokoro stage returns correctly named, correctly typed, shape-compatible outputs
- duration fixture returns non-zero usable durations
- end-to-end fixture synthesis returns deterministic non-empty audio
- fixture paths mirror production paths closely enough to avoid test-only resource APIs
- the published KokoroCoreML 1.1.0 fixture archive is checksum-verified before staging
- fixture validation catches runtime-contract drift
- one explicit fixture mode substitutes the downloaded/restored small archive without production model downloads
- current production download/checksum/validation path remains unchanged
- ReadAloud performs an explicitly requested iPhone fixture integration check before relying on fixture CI as iPhone runtime proof
- shipping validation cannot accept fixture assets; fixture development artifacts remain explicitly non-production
- later implementation phases can exercise the real Kokoro runtime deterministically when testing is requested

---

# Phase 1 — Project Package Foundation

## Goal

Introduce the durable `.readaloud` project format and internal project store before building product UI. `docs/PERSISTENCE_CONTRACT.md` is the source of truth for all Phase 1 disk semantics.

## Work

### Package layout

Implement the project package layout based on Spokio:

```
<uuid>.readaloud/
├── project.json
├── source/
├── content/
│   ├── manifest.json
│   └── items/
├── queue/
│   └── jobs.json
├── cache/
│   ├── paragraphs/
│   └── artwork/
├── audio/
├── assets/
└── temp/
```

### Core persisted types

Add durable Codable models for:

- project identity
- schema version
- source metadata
- project metadata
- project settings
- playback/resume state
- content manifest
- content items
- item voice/speed overrides
- generated-audio metadata

### Project store

Implement a project store that can:

- create a package
- enumerate packages
- load lightweight project snapshots
- load full project metadata
- save project metadata atomically
- rename project metadata
- delete a project
- update playback state
- update settings
- detect unsupported/corrupt projects safely

### Versioning

Introduce project schema versioning from the start.

Do not postpone migration design until after 1.0 data exists.

## Reuse

Use Spokio as the primary reference for:

- stable IDs
- package layout
- relative paths
- atomic persistence
- manifest/item structure
- schema evolution patterns

Adapt for app-owned internal storage rather than user-managed Mac packages.

## Exit criteria

- app can create and reopen an empty/internal project package
- project survives relaunch
- Library snapshots can be loaded without full project hydration
- project writes are atomic
- schema version is persisted
- concrete project/manifest/item/queue/audio metadata semantics match `docs/PERSISTENCE_CONTRACT.md`
- stable IDs, timestamps, source revisions, and playback state follow the documented contract
- deleting a project removes only that project

---

# Phase 2 — Unified Import Pipeline

## Goal

Turn EPUB, PDF, text, and supported documents into the same normalized project model.

## Work

### Importer boundary

Create one ReadAloud importer/coordinator with adapters for:

- EpubKit
- PDFKitAudio
- TextExtractor
- pasted text

### Import contract

Every importer should produce normalized output containing:

- title
- author/creator metadata where available
- cover/artwork where available
- source type
- ordered content items
- stable item IDs
- source metadata
- diagnostics/warnings
- import progress

### Source retention

Copy the original source into the `.readaloud` package.

Do not rely on the original external file remaining available after import.

### Content normalization

Preserve meaningful structure:

- EPUB chapters/TOC
- PDF sections/page groups
- document/text sections
- pasted text blocks

Avoid flattening structured books into one giant text blob.

Follow the normalization contract:

- item IDs are generated once on import and persist for the life of the project
- source locators are metadata, not identity
- each item has a deterministic content revision
- re-importing the same source creates a new project in 1.0

### Import transaction

Import should behave transactionally:

1. create temporary package/work area
2. copy source
3. extract metadata/content
4. persist manifest/items/artwork
5. commit project metadata
6. register project in the Library
7. clean temporary files

A failed import must not leave a broken project visible in the Library.

## Exit criteria

- EPUB imports into a durable structured project
- PDF imports into a durable structured project
- TextExtractor-supported document imports into a durable project
- pasted text creates a project
- source is preserved internally
- metadata/artwork are stored where available
- import can fail safely without corrupt Library state

---

# Phase 3 — Library

## Goal

Replace the prototype-first entry experience with the real Library home screen.

## Work

### Library root

Implement:

- Continue Listening
- project list/cards
- artwork
- title
- author where available
- source type
- progress
- generated/offline status where useful
- add/import action
- search
- sort
- empty state
- loading/error state

### Project management

Add:

- open
- rename
- delete
- project info

### Performance

Use project snapshots.

Do not fully hydrate every project simply to render the Library.

### Navigation

Establish:

```
Library
  ↓
Project Detail
  ↓
Reader
```

### Mini-player placeholder

Reserve the UI architecture for a persistent mini-player even if the full player is completed later.

## Exit criteria

- app launches into Library
- imported projects persist and render correctly
- Continue Listening can identify the latest resumable project
- search/sort work from snapshot metadata
- rename/delete behave correctly
- Library remains responsive with many projects

---

# Phase 4 — Project Detail and Item Settings

## Goal

Create the iOS equivalent of Spokio's project experience without porting the Mac layout.

## Work

### Project Detail

Show:

- cover
- title
- author/metadata
- listening progress
- Continue Listening
- default voice
- default speed
- ordered chapters/sections/items
- generation/offline state per item

### Item actions

Support:

- play
- generate
- regenerate
- clear generated audio
- voice override
- speed override
- item info

### Settings inheritance

Implement deterministic resolution:

```
item override
   ↓
project default
   ↓
app default
```

Changing project defaults must not destroy stored item overrides.

### Project-level actions

Add:

- generate remaining
- manage offline audio
- project info
- rename
- storage
- delete

## Exit criteria

- project detail fully reflects project state
- item ordering is stable
- project/item voice and speed resolution is correct; Default/Custom modes retain independent remembered custom values
- item overrides and remembered custom values survive project-default changes, mode switches, and relaunch
- generation state can be shown even before full queue UI exists

---

# Phase 5 — Project Runtime

## Goal

Introduce a stable runtime layer so playback, generation, Library, Reader, and background state observe the same project activity.

## Work

Create a ProjectRuntime-like object inspired by Spokio.

Responsibilities:

- active project identity
- synthesis ownership
- playback ownership
- queue ownership
- cache coordination
- persistence bridge
- activity aggregation
- item state aggregation

The runtime should be reference-stable while a project is active.

### Important rule

Do not put runtime ownership inside SwiftUI screens.

Views observe the runtime; they do not become the runtime.

## Exit criteria

- one active runtime drives project activity consistently
- Project Detail and Reader see the same state
- navigation does not recreate synthesis/playback state
- background playback can later attach to the same runtime model

---

# Phase 6 — Reader

## Goal

Turn the current text/TTS prototype into the actual reading experience.

## Work

### Reader UI

Implement:

- chapter/section title
- readable text
- current paragraph context/highlight
- scrollable text
- playback progress
- play/pause/resume
- stop where appropriate
- seek backward/forward
- chapter navigation
- voice access
- speed access
- chapters sheet
- reader More menu

### Scroll behavior

Playback must not constantly fight the user's reading position.

If the user scrolls away:

- keep playback running
- do not force-scroll back
- show an explicit return-to-current affordance if useful

### Reader state

Reader consumes:

- project runtime
- playback state
- project/item settings
- persisted content bookmark and optional generation-key-bound audio position

## Exit criteria

- user can read and listen to a project comfortably
- current chapter is obvious
- paragraph context can follow playback without destabilizing manual scrolling
- playback controls remain stable
- leaving and re-entering Reader does not lose state

---

# Phase 7 — Streaming + Persistent Generation

## Goal

Combine the existing fast streaming path with durable offline-ready generated audio.

## Work

### Playback decision

When an item is requested:

```
compatible final audio exists?
   ├── yes → play cached audio
   └── no
        ├── synthesize first chunks
        ├── start playback quickly
        ├── continue generation ahead
        ├── populate paragraph cache
        └── persist final audio
```

### Compatibility metadata

Generated audio compatibility must use the generation-key contract from `docs/PERSISTENCE_CONTRACT.md`:

- item content revision
- resolved voice
- canonical speed
- Kokoro/runtime revision
- synthesis configuration version

For 1.0, persist final item audio as 24 kHz mono WAV PCM plus matching metadata.

### Paragraph cache

Reuse Spokio-style paragraph cache semantics so repeated synthesis and regeneration can reuse compatible work.

### Final audio

Persist generated item audio and metadata under `audio/`.

## Exit criteria

- uncached chapters start quickly
- completed audio can play without re-synthesis
- stale/incompatible audio is never silently reused
- paragraph cache speeds regeneration where compatible
- final audio and its actual source-segment timeline survive relaunch
- resume uses exact seconds only for the same audio identity; regeneration or missing audio restores from the content bookmark

---

# Phase 8 — Durable Queue and Prefetch

## Goal

Bring Spokio-level generation sophistication into ReadAloud.

## Work

### Queue states

Support:

- not generated
- queued
- generating
- ready
- failed

### Queue operations

Support:

- generate item
- generate selected items
- generate remaining items
- generate all where appropriate
- cancel
- retry
- regenerate
- clear cache and regenerate

### Prefetch

While listening:

- prioritize current playback
- generate upcoming chunks/items opportunistically
- avoid starving interactive playback
- keep queue order understandable

### Persistence

Persist queue state sufficiently to recover safely after lifecycle events.

Background synthesis is opportunistic, not guaranteed. Persisted queue intent must recover correctly if iOS suspends or terminates the app; never depend on a live `generating` task surviving background execution.

Jobs that cannot safely resume should recover to a clear retryable state rather than pretending they are still running.

## Exit criteria

- queue survives normal app lifecycle safely
- Project Detail reflects queue state
- playback remains higher priority than background generation
- user can cancel/retry failed work
- upcoming chapters can become Ready Offline automatically

---

# Phase 9 — Background Playback and System Media Integration

## Goal

Make ReadAloud behave like a real audio app.

## Work

Implement:

- background audio mode
- AVAudioSession lifecycle
- interruptions
- route changes
- Now Playing metadata
- lock-screen controls
- Control Center controls
- remote play/pause
- seek backward/forward
- next/previous chapter where appropriate
- persisted content bookmark plus optional generation-key-bound audio position
- correct restore after termination/relaunch and regeneration using the persistence contract

### Mini-player

Complete the persistent mini-player above the tab bar:

- title
- current chapter
- progress
- play/pause
- tap to return to Reader

## Exit criteria

- playback continues reliably in background
- lock-screen controls work
- interruptions recover predictably
- mini-player, Reader, and system controls stay in sync
- relaunch resumes the correct project/item/position

---

# Phase 10 — Storage and Offline Management

## Goal

Make local media generation understandable and manageable.

## Work

### Storage summary

Show:

- total ReadAloud storage
- per-project storage
- generated audio
- temporary cache
- artwork
- source size where useful

### Safe actions

Support clearly differentiated actions:

- clear temporary cache
- clear generated audio
- regenerate audio
- delete project

Do not use one ambiguous "Clear Cache" action for destructive and non-destructive categories.

### Project offline management

Provide a project-level view for:

- ready item count
- generating items
- queued items
- item sizes
- generate remaining
- clear generated audio

## Exit criteria

- user can understand what occupies storage
- safe cache cleanup cannot destroy source/project metadata
- generated audio can be removed and recreated
- project deletion is the only normal action that destroys the complete project

---

# Phase 11 — AppFoundation Product Shell

## Goal

Integrate ReadAloud into the reusable commercial/app infrastructure.

## Work

Integrate AppFoundation for:

- Pro entitlement
- paywall
- purchase
- restore
- plan management
- themes
- Settings shell/patterns
- analytics integration hooks
- developer purchase simulation/tools

### ReadAloud-specific settings

Add:

- default voice
- default speed
- skip interval
- continue to next chapter
- prefetch behavior
- generation behavior
- storage management

### Gating

Centralize entitlement decisions.

Likely Pro candidates:

- larger/unlimited Library
- advanced voices
- persistent offline generation
- bulk generation
- per-item overrides
- advanced storage/generation controls

Free mode must still demonstrate the real product.

## Exit criteria

- AppFoundation owns purchase/entitlement behavior
- ReadAloud does not duplicate payment infrastructure
- Settings feel complete
- Pro gating is consistent and centralized
- purchase/restore state survives relaunch correctly

---

# Final 1.0 execution note

For the 1.0 release, the original Phases 12–15 were intentionally collapsed into one final release-hardening pass after Phase 11. The reduced scope keeps analytics inert/disabled, relies on the existing manual release path instead of expanding CI, and implements only release-critical reliability, accessibility, metadata, privacy, and submission preparation.

The detailed Phase 12–15 sections below are retained as backlog/reference for post-1.0 work.

---

# Phase 12 — Analytics and Product Diagnostics

## Goal

Add meaningful product instrumentation without exposing diagnostics to normal users.

## Work

Integrate existing analytics hooks with analytics disabled by default. Disabled mode must create no installation ID, event queue, or network traffic. Collection requires a later explicit decision; this phase does not enable it.

Candidate events:

- import_started
- import_completed
- import_failed
- project_opened
- playback_started
- playback_resumed
- playback_completed
- generation_started
- generation_completed
- generation_failed
- paywall_viewed
- purchase_started
- purchase_completed

Keep technical metrics available under developer tools where useful:

- model load time
- first-audio latency
- synthesis time
- RTF
- queue depth
- underruns
- thermal state

Do not mix engineering metrics into normal product analytics unless there is a clear reason.

## Exit criteria

- major product funnel hooks exist but are inert while analytics is disabled
- event observability is required only if collection is explicitly enabled later
- analytics failure never breaks reading/playback
- developer diagnostics remain available for performance debugging
- normal users do not see prototype metrics/log UI

---

# Phase 13 — Reliability, Migration, and Recovery

## Goal

Harden the app around the failure modes created by durable projects and long-running local generation.

## Work

### Migration

- explicit schema migrations
- migration ordering
- future-version rejection
- migration rollback/safety where practical

### Import recovery

- orphan temp cleanup
- failed import cleanup
- source-preservation checks

### Generation recovery

- interrupted job recovery
- stale queue cleanup
- partial audio cleanup
- preserve last known valid generated audio until replacement commits

### Project integrity

- detect missing files
- detect malformed metadata
- recover non-critical derived data
- never silently delete user projects

## Exit criteria

- ordinary crashes/termination do not corrupt projects
- interrupted generation recovers into a clear state
- migrations are deterministic
- derived data can be rebuilt
- original source remains protected

---

# Phase 14 — Accessibility and iPhone Polish

## Goal

Finish the iPhone-only product with strong accessibility and device-size polish. iPad expansion is outside 1.0 scope.

## Work

### iPhone polish

Cover:

- compact and large iPhone sizes
- Dynamic Type-driven layout changes
- safe-area behavior
- mini-player and Reader stability
- keyboard/file-picker transitions
- long titles and metadata

### Accessibility

Cover:

- Dynamic Type
- VoiceOver
- semantic progress
- large tap targets
- reduced motion
- status not conveyed by color alone
- accessible playback controls
- accessible generation state

## Exit criteria

- iPhone layout is polished across supported device sizes
- no important workflow depends on precise gestures or fixed text size
- no iPad-specific implementation is introduced

---

# Phase 15 — Release Infrastructure and App Store Readiness

## Goal

Turn the finished product into a shippable 1.0.

## Work

### Release workflow

Implement the exact workflow contract in `docs/CI_RELEASE.md`:

- `fast-ci.yml`
- `full-ci.yml`
- `release.yml`
- all manual-only via `workflow_dispatch`
- all runnable against any selected branch/ref
- no hardcoded `master` or `develop`
- branch-aware concurrency
- fixture resources by default
- real resources only when explicitly selected

Adopt the proven workflow patterns already used across sibling repos:

- build/archive
- configuration selection where useful
- signing
- TestFlight upload
- release metadata/versioning
- App Store release path

### App configuration

Finalize:

- marketing version 1.0
- build number strategy
- display name / public brand
- icon
- privacy metadata
- supported file declarations if appropriate
- background modes
- App Store metadata
- screenshots
- subtitle/keywords
- changelog/release notes

### Final cleanup

- remove prototype-only entry points from normal UI
- preserve developer diagnostics behind developer tools
- verify no internal engineering naming leaks into public branding unintentionally

## Exit criteria

- production archive can be produced
- TestFlight upload path works
- App Store metadata is complete
- public brand can differ from internal ReadAloud identity without technical migration
- app is ready for 1.0 submission


---

# Pre-implementation gate

Before Phase 1 product code:

- apply `docs/PRE_IMPLEMENTATION.md`
- apply `docs/IOS_APP_BASELINE.md`
- align to iOS 26+ iPhone only; iPad is unsupported
- remove/park the Mac target
- pin all reusable dependencies immutably
- consume the already released KokoroCoreML 1.1.0 executable fixture archive
- accept `docs/PERSISTENCE_CONTRACT.md`
- preserve repo rules in `AGENTS.md`

Do not start persistence/import/product UI while these foundations are still ambiguous.

---

# Dependency order

The phases intentionally build upward:

```
0  Integration baseline
        ↓
0A Fixture model + deterministic assets
        ↓
1  Project package
        ↓
2  Import pipeline
        ↓
3  Library
        ↓
4  Project detail/settings
        ↓
5  Project runtime
        ↓
6  Reader
        ↓
7  Streaming + persistent audio
        ↓
8  Queue + prefetch
        ↓
9  Background/system playback
        ↓
10 Storage/offline management
        ↓
11 AppFoundation shell
        ↓
12 Analytics/diagnostics
        ↓
13 Reliability/migrations
        ↓
14 Accessibility/iPhone polish
        ↓
15 Release/App Store
```

Some later phases can overlap once their dependencies are stable, but implementation should avoid building UI ahead of the domain/state layer it depends on.

---

# Recommended PR strategy

Keep changes reviewable even though 1.0 is ambitious.

KokoroCoreML executable fixture infrastructure is already released in 1.1.0. The remaining PR sequence is entirely ReadAloud work:

```
PR 0  ReadAloud integration baseline
PR 0A ReadAloud fixture consumption + deterministic asset substitution
PR A  Package foundation
PR B  Import pipeline
PR C  Library
PR D  Project detail + settings inheritance
PR E  Project runtime
PR F  Reader
PR G  Persistent audio + paragraph cache
PR H  Queue + prefetch
PR I  Background playback + mini-player
PR J  Storage/offline management
PR K  AppFoundation integration
PR L  Analytics/product diagnostics
PR M  Reliability/migrations
PR N  Accessibility/iPhone polish
PR O  Release/App Store
```

Stack PRs when a later change clearly depends on an unmerged earlier PR.

Do not combine unrelated product-shell, persistence, and playback work into one giant implementation PR merely to reduce PR count.

---

# Testing policy

Implementation and testing should remain separate decisions.

For each implementation PR:

1. implement the scoped phase
2. review the diff and architecture
3. identify the relevant tests/builds that should be run
4. run them only when explicitly requested/approved

Do not add expensive UI/browser verification by default.

---

# Final 1.0 completion criteria

ReadAloud 1.0 is complete when:

- a user can build a durable personal Library
- EPUB/PDF/text/documents import reliably
- chapter/section structure is preserved
- projects survive relaunch and migration
- local TTS starts quickly
- final audio can be persisted and reused
- queue/prefetch generation works predictably
- project/item voice and speed semantics are correct
- playback resumes at the correct position
- background/lock-screen playback works
- storage is understandable and manageable
- AppFoundation handles commercial shell behavior
- analytics hooks are available and remain inert by default
- iPhone experience is polished
- accessibility is complete across supported iPhones; no iPad implementation or release assets are included
- manual branch-aware Fast CI / Full CI / Release workflows are ready
- release/TestFlight/App Store workflow is ready
- deterministic fixture-model infrastructure exists for fast development/CI without full production downloads
- the app feels like a complete offline reading/listening product, not a prototype
