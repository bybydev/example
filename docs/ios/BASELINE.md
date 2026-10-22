# Inspected repository baseline

Inspected on 2026-10-22 from **develop at `e860f0fac71ce923ee594ac1a9e6dd636750e2d3`**. This is the parent commit for the planning PR. It is later than the issue's historical master-based assessment. Refresh this record at implementation start; do not merge or reset master into develop as part of planning.

## Working rules and automation

Root [AGENTS.md](../../AGENTS.md) says:
- Do not fake completion; stop and report a problem.
- Do not run builds or tests unless asked.
- XcodeGen owns the project; do not modify .xcodeproj files.

The inspected develop tree contains no `.github/workflows/` files or `ci_scripts/` directory. Historical docs mention Xcode Cloud, but that does not authorize setup, dispatch, external account operations or assumptions about externally configured services. The planning commit uses a skip-CI marker; no CI is intentionally dispatched. Recheck trigger files before any future push/PR and respect the user's no-CI rule.

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
