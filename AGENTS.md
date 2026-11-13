# Inkribe — Agent Guide

## Working rules
- Show a plan before editing; wait for approval.
- Never run builds or tests (`xcodebuild`, `swift build/test`, `make build/test`).
- Never commit, push, or open PRs unless asked.
- Work only on the iOS app. Ignore `InkribeMac/`, `InkribeMacTests/`, the
  `InkribeMac` target/scheme, and macOS settings.
- `project.yml` is the source of truth. Never hand-edit `Inkribe.xcodeproj`
  or its schemes. Ask before running `xcodegen generate`.
- Never edit `Models/` or `testfixtures/Models/`; they contain gitignored binaries.
- Don't add dependencies or change package pins without asking.
- Preserve unrelated user changes.

## Product
Inkribe is a local-first, iPhone-only video caption editor (iOS 26+, Swift 6,
SwiftUI): import clips/photos → transcribe on-device with Whisper → edit
word-level captions, styles, clips and music → export captioned MP4 or SRT.
Speech recognition is on-device; no cloud transcription.

## Stack / project facts
- Deployment target iOS 26.0; `TARGETED_DEVICE_FAMILY = 1` (iPhone only).
- Swift 6 strict concurrency; default actor isolation is `nonisolated`.
- Generated with XcodeGen (minimum 2.45.4). `project-ios-bundled.yml` is the
  opt-in build that bundles the Small Whisper model.
- The iOS target links only local `InkribeCore`, `InkribeModelAssets`,
  `WhisperRuntime`, plus remote `AppFoundation` (UI/themes/purchases) and
  `JobQueue` (durable jobs).
- Other packages and `InkribeMac/` are macOS-only or unwired. Do not copy
  their patterns into iOS code.
- `ScreenshotStudio/` is DEBUG-only / App Store screenshot tooling.

## Where to start
| Task | Open first |
|---|---|
| App entry / root state | `Inkribe/App/InkribeApp.swift`, `Inkribe/App/ProjectsModel.swift`, `Inkribe/App/ProjectsView.swift` |
| Project document / schema | `Inkribe/Domain/ProjectDocument.swift` (schema 13), `Inkribe/Storage/ProjectRepository.swift` |
| Package format / storage | `Packages/InkribeCore/Sources/InkribeCore/Projects/ProjectPackageStore.swift`, `ProjectPackageLayout.swift` |
| Editor / timeline / playback | `Inkribe/Editor/EditorSession.swift`, `Inkribe/Editor/ProjectEditorView.swift`, `Inkribe/Editor/CaptionSnapshot.swift` |
| Caption rendering | `Inkribe/Rendering/CaptionScene.swift`, `CaptionRenderer.swift`, `Packages/InkribeCore/Sources/InkribeCore/Captions/` |
| Transcription | `Inkribe/Transcription/TranscriptionController.swift`, `LocalTranscriber.swift`, `SpeechCheckpoint.swift`, `Inkribe/Models/SpeechModelCatalog.swift` |
| Export | `Inkribe/Export/ExportController.swift`, `MP4Exporter.swift`, `SRTExporter.swift`, `Packages/InkribeCore/Sources/InkribeCore/Processing/ProcessingContracts.swift` |
| Processing queue | `Inkribe/Processing/ProcessingCoordinator.swift`, `ProcessingLifecycle.swift`, `Inkribe/App/TranscriptionView.swift` |
| Pro / paywall / limits | `Inkribe/Pro/Commerce.swift`, `ProAccess.swift`, `CaptionAllowance.swift` |
| Import / media | `Inkribe/Media/MediaImporter.swift`, `MediaInspector.swift`, `Inkribe/App/ImportView.swift` |
| Speech model downloads | `Inkribe/Models/SpeechModels.swift`, `SpeechModelStore.swift`, `Packages/InkribeModelAssets/` |
| Settings | `Inkribe/App/SettingsView.swift` |
| App Store screenshots | `Inkribe/ScreenshotStudio/` |

## Folder map
- `Inkribe/App/` — library shell, import, settings, root state.
- `Inkribe/Domain/` — Codable project document and pure edit rules.
- `Inkribe/Editor/` — editor session, timeline, caption UI, playback.
- `Inkribe/Export/` — export jobs and MP4/SRT writers.
- `Inkribe/Media/` — import, inspection, thumbnails.
- `Inkribe/Models/` — speech model catalog/download/store.
- `Inkribe/Pro/` — StoreKit, entitlement, free limits.
- `Inkribe/Processing/` — JobQueue composition, lifecycle, queue UI.
- `Inkribe/Rendering/` — caption layout/drawing and frame compositing.
- `Inkribe/Storage/` — `ProjectRepository` and package adapter.
- `Inkribe/Transcription/` — Whisper pipeline, checkpoints, allowance.
- `Inkribe/Resources/` — plist, entitlements, assets, StoreKit config.
- `Packages/InkribeCore/` — shared domain and project package store.
- `Packages/InkribeModelAssets/` — model manifest and downloader tool.
- `Packages/WhisperRuntime/` — whisper.cpp wrapper.

## Invariants (do not break)
1. **One repository.** `ProjectRepository.shared` is the only process-wide actor
   for project transactions. Views/models must use it; never create per-screen
   repositories, indexes, or JSON writers.
2. **Self-contained packages.** A project is
   `Application Support/InkribeIOSProjects/Projects/<UUID>.inkribe/` containing
   `package.json`, `document.json`, `document.previous.json`, `Originals/`, and
   optional `speech-checkpoint.json` / `editor-draft.json`. Media must live inside
   the package; use `OwnedPath` for path validation.
3. **Atomic, revisioned writes.** Stage in `Pending/`, then publish with a
   same-volume directory rename. Every edit checks `expectedRevision`; never write
   `document.json` directly. Validate with `ProjectDocument.validate()` before commit.
4. **Schema discipline.** `ProjectSchema.current == 13`. A new persisted field needs
   a schema bump plus version-gated validation and backward-compatible reads. Don't
   silently reinterpret existing fields.
5. **Durable work uses JobQueue.** Transcription (max 1) and export (max 3) are
   durable `Job` types. Keep payloads Codable-compatible (`LegacyJobCompatibility`)
   and don't add a parallel queue or fire-and-forget Task for user work.
6. **UI state vs. disk state.** `@MainActor @Observable` models own UI state;
   `ProjectRepository` owns disk. Avoid new shared mutable singletons or
   `@unchecked Sendable` unless already established and justified.
7. **Pro gates.** Free: 3 videos/week, each under 90 s, 720p MP4, SRT, basic
   styles/theme. Pro: unlimited captioning, 1080p, all styles/themes. Gate through
   `ProAccess`/`Commerce`, never ad-hoc checks.
8. **On-device speech.** Don't add cloud transcription/AI to the iOS target.
   Model URLs, revisions, sizes, and SHA-256 are pinned in `SpeechModelCatalog`
   and `InkribeModelAssets`.

## Conventions
- Keep domain logic out of SwiftUI views; pure `Codable`/`Sendable` types belong in
  `Domain/` or `InkribeCore`.
- Use AppFoundation theme tokens/components; don't hard-code colors or fonts.
- Mark only UI-bound state `@MainActor`; prefer actors for IO. Respect strict
  concurrency rather than reaching for locks or unchecked sendability.
- Keep large SwiftUI bodies split into small opaque subviews; a single long modifier
  chain has hit the compiler's type-check budget.
- Add accessibility labels/identifiers to interactive controls, following existing
  `feature.element` names.
- Update doc comments when changing an invariant. Prefer editing existing files over
  creating parallel abstractions.

## Token-saving rules
- Several core files are 1,300–1,400 lines. Use `grep`/symbol search and read only
  the relevant section; don't read whole files by default.
- Don't open unless the task touches them:
  - `InkribeMac/`, `InkribeMacTests/` — frozen macOS app.
  - Mac-only/unwired packages: `InkribeAI`, `InkribeAudio`, `InkribeExport`,
    `InkribePersistence`, `InkribeTranscription`, `DiarizationRuntime`, `LLMRuntime`.
  - `Models/` — multi-GB downloaded binaries.
  - `Inkribe.xcodeproj/` — generated; read `project.yml` instead.
  - `ScreenshotStudio/` — screenshots only.
  - `scripts/`, `ci_scripts/`, `.github/` — CI/release/models only.
- Start with the “Where to start” row; don't scan the whole tree.

## Verification
- Package tests live in `Packages/*/Tests` (mostly Swift Testing); there is no iOS
  app test target.
- Do not run builds/tests. If asked to add tests, add them to the nearest package
  and keep them deterministic.
- Never claim a build/test passed unless the user actually ran it.
- If files were added/removed or `project.yml` changed, tell the user
  `xcodegen generate` is required; don't run it unprompted.

## Done
- Minimal diff; no unrelated refactors or formatting churn.
- Report changed files, behavior, and risks (schema migration, job-payload
  compatibility, project regeneration).
- No commit/push unless asked.
