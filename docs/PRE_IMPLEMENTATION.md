# ReadAloud 1.0 Pre-Implementation Decisions

## Purpose

This document locks the decisions that would be expensive to change after product implementation begins.

Implementation should not begin past Phase 0/0A until these constraints are reflected in the repo.

---

## 1. Platform baseline

ReadAloud 1.0 follows the established portfolio baseline documented in `docs/IOS_APP_BASELINE.md`.

Target:

- iOS 26+
- iPhone only for 1.0
- `TARGETED_DEVICE_FAMILY = 1`
- no macOS product target for 1.0
- no Mac Catalyst
- no iPad support

The current prototype still contains a `ReadAloudMac` target and an iOS 18 deployment target. Phase 0 should remove or park the Mac target and align the iOS deployment target with this product baseline.

Do not carry prototype cross-platform complexity into the 1.0 architecture. macOS and iPad are outside the product scope.

ReadAloud should reuse the common setup from Spokio iOS, MiLove, and Palette rather than creating a fourth app-shell/configuration pattern.

---

## 2. Shared iOS app baseline

Before app-specific product work, Phase 0 must align ReadAloud with `docs/IOS_APP_BASELINE.md`:

- XcodeGen source of truth
- checked-in owner-managed `.xcodeproj` and `Package.resolved`
- Swift 6 + complete strict concurrency
- iOS 26 / iPhone-only / no Mac Catalyst
- explicit StoreKit configuration
- PrivacyInfo.xcprivacy
- modern AppFoundation PurchaseManager + ThemeManager integration
- standard Plan / Appearance / Support / About / DEBUG Developer settings structure
- AppStore repository metadata structure
- analytics disabled by default unless explicitly enabled later

Use the newer Spokio/AppFoundation patterns when MiLove or Palette contain older compatibility code.

---

## 3. Dependency baseline

Use the latest reviewed stable semantic tags and pin them with XcodeGen `exactVersion`, matching the newer Spokio convention.

Current implementation baseline:

| Dependency | Exact version | Role |
| --- | ---: | --- |
| AppFoundation | `1.6.4` | purchases, entitlements, paywall, themes, Settings shell, developer tools |
| EpubKit | `1.1.0` | EPUB import/metadata/chapters |
| PDFKitAudio | `1.1.0` | PDF import/structure |
| TextExtractor | `1.1.0` | general document extraction |
| KokoroCoreML | `1.1.0` | local Kokoro TTS runtime + published executable fixture support |
| JobQueue | `1.0.0` | preferred reusable durable queue/recovery infrastructure |
| SwiftLame | `1.0.0` | optional; add only if compressed MP3/export becomes part of ReadAloud |

At the time this baseline was recorded, each package's `master` was identical to its latest stable tag.

Phase 0 should replace moving branch dependencies with these exact semantic versions.

Do not add SwiftLame merely because Spokio uses it; ReadAloud 1.0 currently persists WAV and does not yet require MP3 export.

If a dependency must move during implementation:

1. update the documented baseline,
2. review the API/runtime impact,
3. update the consuming phase intentionally.

Do not silently advance multiple dependencies while debugging unrelated ReadAloud behavior.

---

## 4. Fixture-model ownership

The executable Kokoro fixture is part of the **Kokoro runtime contract**, so its canonical implementation belongs in `hoangbkit/KokoroCoreML`.

Ownership:

```
KokoroCoreML
├── filesystem/manifest fixture
├── executable Core ML fixture generator
├── tiny executable .mlpackage fixtures
├── fixture runtime/voice assets
└── fixture contract validation

ReadAloud
├── fixture asset consumption
├── explicit fixture-mode substitution
└── ReadAloud integration checks using the fixture
```

ReadAloud should not maintain a divergent copy of the Kokoro executable fixture.

KokoroCoreML `1.1.0` now provides this fixture capability as a stable release with a matching downloadable fixture archive and checksum.

Phase 0A therefore only wires ReadAloud to consume the released fixture. No additional KokoroCoreML work is required before ReadAloud implementation starts.

The released `fixture-executable-v1` profile has duration t128 plus one fixed 15-second bucket, four model packages, and three synthetic voices. Phase 0A must adapt ReadAloud's production-only validator/resource assumptions to an explicit fixture branch without weakening the real-asset path. See `docs/IMPLEMENTATION_PLAN.md` and the tagged KokoroCoreML fixture guide.

---

## 5. Persistence contracts

Before Phase 1 writes production project data, the on-disk contracts in `docs/PERSISTENCE_CONTRACT.md` are authoritative.

The contract must cover:

- `project.json`
- `content/manifest.json`
- `content/items/<id>.json`
- `queue/jobs.json`
- `audio/<id>.metadata.json`
- schema versions
- stable IDs
- timestamps
- source/content revisions
- independent voice/speed selection modes and remembered custom values
- content bookmark and generation-key-bound audio position
- actual source-segment audio timeline
- generation/cache identity

Once 1.0 persistence is used by real users, field semantics must be migrated rather than silently reinterpreted.

---

## 6. Content normalization

All importers normalize into the same content model.

1. EPUB
   - preserve spine/TOC order
   - item represents a meaningful chapter/section
   - retain a source locator such as href/fragment/structural index

2. PDF
   - use PDFKitAudio's meaningful section/page grouping
   - retain page-range/source locator data
   - do not make page number itself the durable item ID

3. General documents
   - use TextExtractor structural sections when reliable
   - otherwise create sensible logical sections

4. Pasted text
   - one item by default
   - long-text sectioning may reuse the same normalizer later

### Stable identity rule

Item IDs are generated once during project import and persisted.

For 1.0, "stable" means stable for the lifetime of that project across relaunches, migrations, queue/cache operations, and metadata edits.

Re-importing the original source creates a new project with new IDs unless a future explicit re-import/update feature defines reconciliation semantics.

Each item also stores a source locator and content revision so identity and content compatibility are separate concerns.

---

## 7. Audio and cache identity

Generated audio must never be reused because a filename happens to exist.

Define a deterministic generation identity from at least:

```
contentRevision
+ resolvedVoiceID
+ canonicalSpeed
+ Kokoro/runtime contract revision
+ synthesisConfigVersion
= generationKey
```

The same generation key controls compatibility for:

- final generated audio
- generation metadata
- paragraph cache entries where applicable

If any input changes, the old asset may remain on disk temporarily but is not considered compatible.

### Paragraph identity

Paragraph/cache identity should include:

- item ID
- paragraph index or stable paragraph locator
- normalized paragraph text hash
- generation key inputs relevant to that paragraph

This allows compatible paragraph reuse without confusing content identity with item identity.

### Initial final-audio format

For 1.0, use the existing architecture's straightforward durable format:

- WAV
- 24 kHz
- mono
- PCM compatible with the Kokoro output path

Store compatibility/provenance and the actual source-segment timeline in the separate audio metadata JSON. Persist content bookmarks independently of audio seconds so regeneration, changed voice/synthesis speed, and clearing audio cannot silently move the listening position. Exact seconds apply only to a matching audio identity; otherwise resume from the saved source segment.

A later compressed-storage migration can be introduced explicitly if storage pressure justifies it.

---

## 8. Background execution semantics

ReadAloud guarantees **background playback**, not unlimited background synthesis.

### Playback

When audio is playing:

- background audio mode may keep playback active
- Now Playing / remote controls remain available
- playback position continues to persist

### Generation

Queued synthesis is opportunistic:

- continue while iOS gives the app execution time
- persist queue/job state before suspension when possible
- never depend on indefinite background execution
- never abuse audio playback solely to keep generation alive
- when execution is interrupted, recover the job into a deterministic resumable/retryable state
- resume queued work when the app becomes active and policy allows

The queue model must therefore treat `generating` as runtime state, not proof that work survived process suspension.

---

## 9. Decisions that may wait

These do not block implementation:

- final consumer-facing app name
- exact App Store subtitle
- final icon
- exact Pro gating
- exact pricing
- final analytics event list
- screenshots/marketing copy

Keep the public brand decoupled from internal ReadAloud identifiers.

---

## Ready-to-implement gate

Phase 1 product implementation is ready when:

- repo targets iOS 26+ for iPhone only
- obsolete Mac product target is removed/parked
- shared app configuration follows `docs/IOS_APP_BASELINE.md`
- generated `.xcodeproj` and `Package.resolved` are treated as checked-in owner-managed artifacts
- reusable dependencies use the exact stable versions in this document
- KokoroCoreML `1.1.0` is pinned and its published executable fixture archive is consumable
- ReadAloud fixture substitution is defined
- persistence contracts are accepted
- normalization rules are accepted
- generation/cache identity, source-segment timeline, and bookmark restore/reset policy are accepted
- Default/Custom settings retain independent remembered custom values across mode switches and relaunch
- background playback vs generation semantics are accepted
- repo working rules are present in `AGENTS.md`
