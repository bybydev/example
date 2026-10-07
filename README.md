# ReadAloud

ReadAloud is a local-first, offline document-to-speech reader for iPhone.

It imports EPUBs, PDFs, supported documents, and pasted text into durable
`.readaloud` projects, then reads them with on-device Kokoro Core ML speech.

## Product status

ReadAloud 1.0 implementation is complete through release hardening.

Implemented product flow:

```text
Library
  -> Project Detail
      -> Reader
```

The app includes:

- durable Library projects that survive relaunch;
- EPUB, PDF, document, and pasted-text import;
- structured chapters/sections;
- retained original source;
- on-device streaming speech;
- paragraph cache and finalized offline WAV audio;
- durable generation queue and prefetch;
- saved reading/listening position;
- background playback and system media controls;
- storage/offline management;
- AppFoundation purchases, restore, themes, and Pro gating.

Analytics collection remains disabled for 1.0.

## Platform

- iPhone only
- iOS 26+
- no iPad support
- no Mac Catalyst
- bundle ID: `com.hoangbkit.readaloud`
- internal project/package identity remains ReadAloud / `.readaloud`

## Architecture

Start with:

- `docs/CURRENT_ARCHITECTURE.md` — implemented 1.0 ownership/component map
- `docs/PERSISTENCE_CONTRACT.md` — authoritative durable project/audio/resume semantics
- `docs/RELEASE_CHECKLIST.md` — manual 1.0 release/submission checks
- `docs/PRODUCT_PLAN.md` — product intent
- `docs/DESIGN.md` — iPhone UX language
- `AGENTS.md` — repository working rules

The phased implementation documents remain for historical context:

- `docs/IMPLEMENTATION_PLAN.md`
- `docs/PRE_IMPLEMENTATION.md`
- `docs/IOS_APP_BASELINE.md`
- root `PLAN.md`

## Project model

Projects are stored under Application Support as:

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

Project/item identities are stable. Normalized text, resolved narration,
Kokoro runtime revision, and synthesis configuration determine generated-audio
compatibility.

See `docs/PERSISTENCE_CONTRACT.md` for the exact contract.

## Runtime ownership

`ProjectRuntimeManager` owns one stable `ProjectRuntime` per loaded project.

Each runtime owns:

- hydrated project/item state;
- streaming synthesis/playback;
- durable generation queue execution;
- paragraph cache;
- persistence bridge;
- playback/generation activity.

Reader, mini-player, background audio, Now Playing, and system remote commands
all observe the same runtime.

## Speech pipeline

```text
normalized text
  -> SpeechChunkScheduler
  -> KokoroEngine
  -> SpeechPlaybackQueue
  -> AVAudioEngine / AVAudioPlayerNode
```

ReadAloud uses the `KokoroTTS` product from KokoroCoreML 1.1.0.

Production resources are checksum/provenance verified. Development can use the
released executable fixture profile without downloading the full production
model set.

## Kokoro resources

Prepare production assets:

```bash
bash scripts/bootstrap.sh
```

Or download/verify explicitly:

```bash
bash scripts/download-kokoro-assets.sh
bash scripts/verify-kokoro-assets.sh
```

Prepare the executable fixture:

```bash
bash scripts/download-kokoro-fixture.sh
```

Production is the default resource mode. Development can explicitly stage the
fixture with:

```bash
READALOUD_KOKORO_RESOURCE_MODE=fixture xcodebuild ...
```

Fixture resources are development-only and must never ship to App Store Connect.

## Project generation

`project.yml` is the XcodeGen source of truth.

The generated `ReadAloud.xcodeproj` and `Package.resolved` are checked-in,
owner-managed artifacts. Do not regenerate or resolve them unless explicitly
requested.

When intentionally regenerating:

```bash
xcodegen generate
```

## DEBUG prototype

The original Kokoro prototype reader, sample passages, event log, and live
performance metrics are retained for engineering diagnostics.

That surface is compiled only in DEBUG and is reachable only through developer
tools. It is not part of the Release product.

## Free / Pro

Free includes:

- up to 3 projects;
- Heart voice;
- normal Reader and streaming playback;
- single-chapter offline generation;
- storage cleanup;
- Midnight and Paper themes.

ReadAloud Pro adds:

- unlimited projects;
- all bundled voices;
- per-chapter narration overrides;
- bulk generation;
- automatic prefetch;
- generate while listening;
- advanced regeneration;
- premium themes.

`ReadAloudAccessPolicy` is the central access contract.

## Release

Marketing version: **1.0**

The canonical App Store shipping path is manual/local using Xcode/mycli and
`docs/RELEASE_CHECKLIST.md`.

The manual GitHub **Release** workflow creates disposable unsigned iOS archives
for mycli. In the Actions UI, select:

- **Configuration:** Debug or Release
- **Kokoro models:** fixture or real

The workflow always builds the selected branch/ref and publishes one
`mycli-build-*` prerelease. It does not upload to App Store Connect.

App Store metadata lives under `AppStore/`.
