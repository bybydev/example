# ReadAloud

ReadAloud is evolving from a local Kokoro Core ML prototype into a sophisticated offline document-to-speech reader for iPhone.

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

## Reader prototype UI

The reader screen now drives the complete local pipeline. It includes:

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

## Current scope

The original Kokoro prototype phases are complete. The repo is now planning the ReadAloud 1.0 product around durable projects, document import, structured reading, persistent/offline audio, queue/prefetch generation, background playback, AppFoundation integration, and production release infrastructure.

Use the 1.0 docs above as the source of truth. `PLAN.md` is historical.
