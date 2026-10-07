# ReadAloud 1.0 Product Plan

## Product direction

ReadAloud 1.0 should launch as a sophisticated offline document-to-speech reader, not as a narrow prototype or intentionally reduced MVP.

The product boundary is focused:

> Import documents, organize them into a durable library, and listen to them naturally with local speech generation.

Depth inside that boundary is desirable. Features that belong to a different product category should stay out of this release.


## Platform scope

ReadAloud 1.0 follows the portfolio's iPhone-first convention:

- iPhone
- iOS 26+
- no Mac Catalyst

The current prototype macOS target is not part of the 1.0 product. ReadAloud is iPhone-only; iPad is not supported.

## 1.0 goals

ReadAloud 1.0 should feel production-complete in these areas:

- durable Library
- EPUB/PDF/general document import
- structured chapters/sections/items
- persistent reading/listening progress
- local Kokoro playback
- streaming plus persistent generated audio
- generation queue and prefetch
- project-level and item-level voice/speed settings
- background playback
- recoverable queued generation that does not assume indefinite background execution
- Now Playing and lock-screen controls
- storage/cache management
- polished Settings
- AppFoundation-backed Pro/paywall/purchases
- AppFoundation analytics hooks with analytics disabled by default unless explicitly enabled
- release-ready CI/TestFlight/App Store setup

## Product principles

### Complete v1, narrow product boundary

Do not remove obvious product capabilities only because this is version 1.0.

The app should be narrowly scoped but deep.

### Reuse before rebuild

Prefer proven infrastructure from:

- Spokio
- TextExtractor
- EpubKit
- PDFKitAudio
- KokoroCoreML
- AppFoundation
- analytics-server
- existing release workflow patterns

### User-facing simplicity over internal simplicity

The implementation can be sophisticated as long as the user experience remains understandable.

### Offline-first

The core value proposition must work without an account or network connection.

---

## Primary user journeys

### Journey A — Import and listen

```
Library
  ↓
Add
  ↓
Choose EPUB / PDF / document / paste text
  ↓
Import + extract metadata/content
  ↓
Confirm title / voice / speed
  ↓
Project appears in Library
  ↓
Open project
  ↓
Play
```

### Journey B — Resume

```
Launch app
  ↓
Continue Listening
  ↓
Resume same project/item/position
```

### Journey C — Prepare offline audio

```
Project Detail
  ↓
Choose chapter(s) / remaining content
  ↓
Generate
  ↓
Queue runs locally
  ↓
Items become Ready Offline
```

### Journey D — Customize narration

```
Project default voice/speed
  ↓
Optional per-item override
  ↓
Regenerate affected audio when needed
```

### Journey E — Manage storage

```
Settings / Project
  ↓
Storage
  ↓
Inspect generated audio/cache/source size
  ↓
Clear safe cache or generated audio
```

---

## 1.0 scope

### Library

Required:

- project cards/rows
- artwork
- title
- source type
- progress
- Continue Listening
- search
- sort
- add/import
- rename
- delete
- project info
- generated/offline status where useful
- graceful empty/loading/error states

### Import

Required:

- EPUB via EpubKit
- PDF via PDFKitAudio
- plain text/general supported documents via TextExtractor
- pasted text
- original source preserved in the internal project package
- metadata extraction where available
- artwork extraction where available
- visible import progress
- cancellation/recovery
- no half-created Library entries on failure

### Project Detail

Required:

- artwork
- title / author / metadata where available
- progress
- Continue Listening
- project voice
- project speed
- ordered chapter/section/item list
- per-item generation state
- generate/regenerate/cache actions
- item-level voice/speed overrides
- project info / storage entry point

### Reader

Required:

- readable text presentation
- current chapter/section
- play/pause/resume
- stop where appropriate
- seek backward/forward
- chapter navigation
- playback progress
- text position
- current paragraph/reading context highlighting where reliable
- voice/speed access
- background playback
- Now Playing / lock-screen controls
- mini-player when leaving Reader

### Audio generation

Required:

- immediate streaming for uncached content
- paragraph cache
- persistent item audio
- compatibility metadata
- queue
- prefetch
- cancel
- retry
- regenerate
- clear cache and regenerate
- generate selected/remaining/all as product UX requires

### Playback persistence

Required:

- current project
- current item
- content bookmark plus generation-key-bound audio position
- actual source-segment timing for cached/streamed audio
- project progress
- last played timestamp
- deterministic restore after relaunch

### Voice and speed

Required resolution order:

```
item override
   ↓
project default
   ↓
app default
```

Changing a project default must not erase item overrides. Default/Custom selection uses a separate mode and remembered custom value for each field, so selecting Default and later returning to Custom restores the previous choice across relaunch.

### Storage

Required:

- project storage summary
- generated audio size
- cache size
- source size where useful
- clear temporary/safe cache
- clear generated audio with clear consequences
- preserve original source and project metadata unless deleting the project

### AppFoundation

Integrate:

- entitlement state
- paywall
- purchases
- restore
- plan management
- themes where appropriate
- analytics integration
- developer purchase simulation/tools where useful
- Settings shell/patterns where reusable

Do not rebuild these inside ReadAloud.

### Settings

Expected groups:

- Plan
- Playback defaults
- Generation/prefetch behavior
- Storage
- Appearance
- Support
- About
- Developer tools where appropriate

### Analytics

Provide hooks for meaningful product behavior, not implementation noise. Analytics remains disabled by default; disabled mode creates no installation ID, queue, or network traffic. The events below are candidates for a later explicitly enabled configuration, not a requirement to collect data in 1.0.

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

Final event naming should follow existing analytics conventions.

---

## Pro strategy

The exact paywall boundary should be reviewed before implementation is finalized.

Likely Pro candidates:

- higher/unlimited project count
- advanced voices
- full persistent/offline generation
- bulk generation
- per-item voice/speed overrides
- advanced storage/generation controls

Principles:

- free mode must demonstrate the real product
- do not gate basic comprehension of the app
- avoid scattering paywall checks through random views
- centralize entitlement decisions
- use AppFoundation's existing purchase infrastructure

---

## Naming strategy

Keep internal engineering identity as ReadAloud:

- repository: ReadAloud
- bundle ID: `com.hoangbkit.readaloud`
- package extension: `.readaloud`
- internal types/modules: ReadAloud*

The public product brand may differ later:

- Home Screen display name
- App Store name
- icon
- subtitle
- website
- marketing assets

Do not block implementation on the final public brand.

---

## Delivery plan

### Pass 1 — Foundation + Projects

Deliver:

- internal `.readaloud` package model
- project store/registry
- project snapshots for Library
- schema/version foundation
- import adapters
- TextExtractor integration
- EpubKit integration
- PDFKitAudio integration
- source/content/artwork persistence
- Library UI
- search/sort/basic project management

Exit condition:

A user can import supported documents, see durable projects in Library, relaunch, and reopen the same structured content.

### Pass 2 — Reader + Audio

Deliver:

- Project Detail
- Reader
- item navigation
- playback/resume state
- project/item voice/speed inheritance
- project runtime
- streaming integration
- persistent generated audio
- paragraph cache
- queue/prefetch
- regenerate/cache controls
- background playback
- Now Playing / remote commands
- interruption/lifecycle handling
- mini-player

Exit condition:

A user can listen continuously, leave the Reader, background the app, relaunch, and resume with generation/cache state behaving predictably.

### Pass 3 — Product shell

Deliver:

- AppFoundation integration
- Settings
- entitlement/paywall
- purchases/restore
- storage management
- analytics
- polished loading/empty/error states
- Pro gating
- theme/product-shell integration

Exit condition:

The app behaves like a commercial product rather than an engineering build.

### Pass 4 — Release polish

Deliver:

- migration hardening
- import recovery
- queue/generation recovery
- App Store metadata/configuration
- privacy details
- versioning
- TestFlight/release workflow
- final UX polish
- release notes/changelog

Exit condition:

Ready for external TestFlight/App Store submission.

---

## Explicit non-goals for this issue

These are excluded because they broaden the product boundary, not because they are too advanced for v1:

- user accounts
- cloud sync
- collaboration
- social/community features
- web reader
- general AI chat assistant
- summarization feature set
- broad cloud TTS provider support
- shared libraries across users

These can be separate product decisions later.

---

## Product-quality bar

ReadAloud 1.0 should not feel like:

- a TextEditor with a Play button
- a file conversion utility
- a Kokoro demo
- a thin wrapper around import packages

It should feel like:

- a real personal listening library
- a local-first reader
- a polished audio product
- a durable place to keep documents and resume listening
- a coherent consumer app with sophisticated internals hidden behind simple interactions

---

## Definition of done

1. Library survives relaunch and accurately reflects stored projects.
2. EPUB, PDF, text, and supported documents import into durable projects.
3. Structured chapter/section ordering is preserved.
4. Original source is retained.
5. Playback can start quickly even when final audio is not cached.
6. Generated audio can be persisted and reused.
7. Queue/prefetch state behaves predictably.
8. Playback resumes from the correct project/item: exact seconds for matching audio, or the content segment bookmark after regeneration or missing audio.
9. Background playback and lock-screen controls work.
10. Voice/speed inheritance is correct.
11. Storage can be inspected and safely managed.
12. AppFoundation handles purchases/entitlements/product shell.
13. Public branding can differ from internal ReadAloud identity.
14. App is ready for TestFlight/App Store distribution.
