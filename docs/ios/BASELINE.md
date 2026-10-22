> Historical source evidence. Current compact v1 PLAN/FEATURES and WORKFLOW supersede old feature/phase obligations and outdated holds below. This record authorizes no features, commands or checks.

**P1 refreshed baseline (2026-10-22):** develop at 57129f62abe1b01cc4052f58d1d9bdc25d79e831 already includes squash merges #22 and #23. The P1 branch starts exactly there. Inspected project.yml, P0 iOS app/domain contracts, Mac storage roots, InkribeAudio media store and the planning documents. P0 status and review-hold notes below are historical.

# Inspected repository baseline

Original planning baseline: **develop `e860f0fac71ce923ee594ac1a9e6dd636750e2d3`** (parent of the subsequently squash-merged PR #22). **P0 refreshed from develop `955196997b3fbc2683d59fcb44fbc4b11ec5ec9c` on 2026-10-22**, and branched to `feat/ios-p0-foundation` for draft PR #23. The pre-P0 source entry points below describe that branch's starting state; see the as-built audit below.

## Working rules and automation

Root [AGENTS.md](../../AGENTS.md) says:
- Do not fake completion; stop and report a problem.
- Do not run builds or tests unless asked.
- XcodeGen owns the project; do not modify .xcodeproj files.

The inspected develop tree contains no `.github/workflows/` files or `ci_scripts/` directory. Historical docs mention Xcode Cloud, but that does not authorize setup, dispatch, external account operations or assumptions about externally configured services. P0 commits use skip-CI messages; no workflows were created, modified, repaired or dispatched by this work. Externally configured services were not inspected. No tests, builds, generated project changes or CI runs were requested or performed.

## Actual code entry points

| Path | Existing responsibility / evidence |
|---|---|
| `project.yml` | One macOS target/scheme currently named Inkribe; source folder InkribeMac; no iOS app target |
| `InkribeMac/App/InkribeAppDirectories.swift` | Inspect for Mac data path preservation during P0 |
| `InkribeMac/App/InkribeStorage.swift` | Mac storage composition; do not share app-specific storage roots accidentally |
| `InkribeMac/App/InkribeCommerce.swift` | Inspect existing Mac product policy/identifiers before target work |
| `Packages/InkribeCore/Sources/InkribeCore/Transcript.swift` | Timestamped segments, optional speaker IDs, speaker names, raw/edited text, revision, derived content; legacy speaker decode defaults |
| `Packages/InkribeAudio/Sources/InkribeAudio/AudioMediaDecoder.swift` | AVAssetReader reads 16 kHz mono Float32 but appends chunks into one whole-file array |
| `Packages/InkribeTranscription/Sources/InkribeTranscription/DefaultTranscriptionJobExecutor.swift` | Whole-buffer recognition, optional diarization, token-to-speaker alignment, identity stabilization, durable transcript commit |
| `Packages/WhisperRuntime/Sources/WhisperRuntime/WhisperRuntime.swift` | Recognition contracts already include WhisperToken timestamps; tokens are not equivalent to stable editable words |
| `Packages/WhisperRuntime/Package.swift` | Swift tools 6.2, macOS 15/iOS 26 declarations, pinned native whisper binary dependency |
| `Packages/DiarizationRuntime/Package.swift` | Existing sherpa-onnx package boundary; manifests declare iOS, runtime validation remains unperformed |
| `Packages/InkribePersistence/Sources/InkribePersistence/JSONTranscriptRepository.swift` | Actor-owned cache, versioned snapshot v1, duplicate-ID validation, atomic JSON writes |
| `Packages/InkribeExport/Sources/InkribeExport/TranscriptExporter.swift` | Reuse text/subtitle formatting where suitable; not the new animated video renderer |
| `docs/handoffs/SELECTABLE_AI_AND_DIARIZATION.md` | Historical record of selectable Qwen models and speaker-aware transcription |
| `Makefile` | Existing generate/build/test/model commands; listing these does not authorize running them |

## Differences from the issue baseline

Develop already includes DiarizationRuntime and token timestamps, speaker-aware segments, stable speaker remapping on retranscription, speaker naming and speaker-aware subtitle formatting. P2 should adapt this work, not rebuild diarization from scratch. Persisted Mac transcripts still have no independent caption/video project graph or durable editable word entities.

Develop's Mac AI assets include Qwen3 0.6B as default and 1.7B as an option. Neither is automatically an iOS packaging or performance decision. Do not copy all Mac model resources into the new app by default.

The Mac Release bundle identifier is `com.hoangbkit.inkribe`; Debug is `com.hoangbkit.inkribe.debug`. Renaming the target/scheme must preserve these values, the displayed/product name, signing assumptions, entitlements, storage and existing Mac purchase identifiers. Choose a distinct iOS bundle/product namespace during P0; do not invent an App Store configuration in this planning PR.

Existing `docs/ARCHITECTURE.md`, `docs/FEATURES.md` and numbered Mac handoffs describe the Mac product. Their historical CI instructions, future name “InkribeIOS”, old project-generation guidance and “phases complete” statements are not current iOS execution instructions.

## Evidence limits

This baseline is source inspection only. No package resolution, builds, tests, model downloads, device measurements, CI setup/runs or deployment occurred. Source declarations do not establish device compatibility, performance or release readiness.

## P0 as-built target/preservation audit (PR #23; source review only)

| Contract | Develop before P0 | P0 source |
|---|---|---|
| Mac target/scheme | `Inkribe` / `Inkribe` | `InkribeMac` / `InkribeMac`; Mac test target `InkribeMacTests` |
| Mac Release / Debug ID | `com.hoangbkit.inkribe` / `com.hoangbkit.inkribe.debug` | **Unchanged** |
| Mac product/display name | `Inkribe` / `Inkribe` | **Unchanged**; XcodeGen target `productName: Inkribe` explicitly matches `PRODUCT_NAME` |
| Mac storage | Application Support/`Inkribe`; `jobs.json`, `transcripts.json`, `Media/` | **Unchanged** (Mac source not edited) |
| Mac commerce | `com.hoangbkit.inkribe.pro.monthly`, `.yearly`, `.lifetime` | **Unchanged**, as is `InkribeMac/Resources/Inkribe.storekit` |
| Mac sandbox/settings | `InkribeMac/Resources/Inkribe.entitlements`; sandbox/audio/input/file entitlements, offline network flags | **Unchanged** |
| Mac sources/models | `InkribeMac/` and optional `Models/` folder resource | **Unchanged** |
| Mac Swift app module | `Inkribe` | **Unchanged**; explicitly pinned with `PRODUCT_MODULE_NAME: Inkribe` |
| Mac tests | `InkribeTests`, `@testable import Inkribe` | New target name `InkribeMacTests`; all seven app-module imports remain `Inkribe`; test bundle ID unchanged |
| Mac test host | App product `Inkribe.app` / executable `Inkribe` | Explicit target `productName: Inkribe` keeps XcodeGen's generated host path aligned with `Inkribe.app/Contents/MacOS/Inkribe` |
| Mac CLI references | Makefile build/test use old scheme | `InkribeMac` scheme in Makefile; no commands run |
| iOS app | None | `Inkribe` target/scheme, `InkribeIOS/` sources, deployment iOS 26, iPhone/iPad; Release `com.hoangbkit.inkribe.ios`, Debug `.ios.debug` |
| iOS foundation | None | AppFoundation 0.1.8 linked only to iOS target; independent theme-state key; isolated empty StoreKit test config, asset catalog/entitlements, no feature UI |
| Project file | Existing `Inkribe.xcodeproj` generated from project.yml | `project.yml` edited; .xcodeproj **not regenerated or modified** |

The target/source diff leaves `InkribeMac/` and `Packages/` unchanged; Mac runtime behavior remains untested, not proven by a source-only comparison. New iOS code does **not** depend on MacAppFoundation, Mac entitlements, Mac StoreKit, Model folder or native runtime packages. It has its own zero-permission entitlements, empty asset catalog and zero-product StoreKit test configuration.

### Portability evidence and unknowns

- Existing `InkribeCore`, `InkribeAudio`, `InkribeExport`, `InkribePersistence` and runtimes declare iOS 26 in package manifests; this is configuration evidence only.
- `InkribeAudio/AudioMediaDecoder.swift` reads with AVAssetReader but appends every PCM chunk to one `[Float]`; it is not bounded streaming. `DefaultTranscriptionJobExecutor` and `NativeWhisperRuntime` consume full samples, and diarization `process(samples:)` is synchronous. P2 must change the end-to-end memory policy before importing large clips.
- `WhisperRuntime` references a pinned remote whisper.cpp XCFramework (b5130), `LLMRuntime` a llama.cpp XCFramework (b10964), and `DiarizationRuntime` sherpa-onnx 1.13.8 native wrapper. Binary architectures, iOS deployment loadability, native link dependencies, codesigning, resource packaging, model memory and latency were **not** verified. No remote binaries or models were downloaded.
- Microphone recorder contains macOS-specific CoreAudio paths under `#if os(macOS)` and an iOS capture-device path; permission/audio session and interruption handling are still unverified and are not included in P0 iOS target.
- The feasibility renderer has a source-level identity clip mapping and bounded compositing API; it was not run. See [handoffs/P0.md](handoffs/P0.md) for user checks and limitations.
