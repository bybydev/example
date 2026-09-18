# Inkribe v1 Implementation Plan

> **Status: complete.** Phases 0–9 were implemented and merged through PR #11. This document is retained as the historical v1 execution plan; use the focused architecture/feature contracts and README for current behavior.

## Product goal

Inkribe v1 is a premium, fully offline macOS speech-to-text app. It should let a user record audio or import an audio/video file, transcribe it locally, edit the transcript, optionally clean or restructure the text with a bundled local LLM, and export the result without an account, cloud service, API key, or runtime model download.

Working App Store name: **Inkribe: Offline Voice to Text**.

## Product principles

- **Offline by default and by architecture.** Audio, transcripts, queue state, and AI cleanup stay on the Mac.
- **Bundled models.** Production builds contain the required STT and LLM models; there is no first-launch model download.
- **One inference stack family.** Use `whisper.cpp` for STT and `llama.cpp` for text cleanup/summarization.
- **Persistent jobs use JobQueue.** Use `hoangbkit/JobQueue` exact version `1.0.0` for transcription queue persistence, scheduling, progress, retry, pause/resume, cancellation, restoration, and queue events. Do not create a second Inkribe-owned queue scheduler/state machine.
- **Apple Silicon first-class, Intel supported.** Use Metal acceleration where available with CPU fallback where required.
- **Cross-platform shared packages from day one.** Reusable domain/runtime/persistence/export/job logic lives in local Swift packages targeting macOS 15+ and iOS 26+ so a future iOS target does not require a repo-wide extraction.
- **Custom Mac shell from day one.** Own the visible title bar, sidebar, toolbar/search, content chrome, and app styling while keeping native `NSWindow` behavior, resizing, fullscreen, menus, focus, accessibility, and traffic lights.
- **Shell geometry is structural, not decorative.** The sidebar and main pane are separate full-height columns divided by one continuous vertical divider from the top edge to the bottom edge. The sidebar owns the traffic-light/titlebar region above it; the main pane owns its page titlebar, content, and any status/player bar. No app title or toolbar content spans across the divider, and a main status/player bar never extends underneath the sidebar.
- **Stable model paths.** Production models and CI fixtures are substituted into the same `Models/` layout so app code never branches on test-vs-production asset locations.
- **Reproducible assets/dependencies.** Model URLs/checksums are pinned, and `JobQueue` is pinned to stable tag `1.0.0`. Commit package resolution required by Xcode/Xcode Cloud so local and CI builds resolve the same dependency graph.
- **XcodeGen-driven project.** `project.yml` is authoritative. The generated `.xcodeproj`, shared schemes, and package resolution required by Xcode Cloud are committed, following the Spokio pattern.
- **Xcode Cloud is the v1 CI target.** Test workflows use tiny committed model fixtures; release/archive workflows restore and validate real models.
- **Debug diagnostics mirror proven Spokio patterns.** In Debug builds, expose both MacAppFoundation Developer Tools and a dedicated Spokio-style in-app Logs window from the top-level Developer menu. Keep both out of Release/App Store builds.

## V1 scope

### Included

- Custom macOS app shell and desktop-first navigation
- Microphone recording with pause/resume and input selection
- Audio level metering
- Audio/video file import via picker and drag/drop
- Persistent multiple-file transcription queue using `hoangbkit/JobQueue` exact version `1.0.0`
- Queue progress, cancel, retry, pause/resume state, and relaunch restoration
- Fully offline transcription using `whisper.cpp`
- Bundled Whisper model
- Automatic and manual language selection
- Segment timestamps
- Local transcript library and search
- Editable transcript view
- Synchronized audio playback and transcript seeking
- Local AI text tools using `llama.cpp` + Qwen-class GGUF model
- Clean transcript
- Polish transcript
- Summarize
- Generate notes
- Extract action items
- Remove filler/repetition and fix obvious contextual STT errors
- Copy, TXT, Markdown, SRT, and VTT export
- Shared local Swift packages targeting macOS 15+ / iOS 26+
- XcodeGen build configuration
- Production model download + checksum validation scripts
- Tiny same-shape model fixtures for CI
- Xcode Cloud test and archive support
- MacAppFoundation integration for themes, Settings, onboarding, StoreKit/Pro, badges, upsells, and paywall
- Debug-only MacAppFoundation Developer Tools window from the Developer menu
- Debug-only Spokio-style Logs window with live in-memory `swift-log` capture, copy, clear, selectable monospaced rows, metadata, bounded history, and auto-scroll
- Unit, integration, UI, queue-restoration, and inference smoke tests

### Explicitly deferred beyond v1

- System-wide global dictation hotkey
- Direct typing/pasting into the currently focused app
- System audio capture
- Meeting-specific capture workflow
- Speaker diarization and speaker naming
- Cloud sync
- Online AI providers
- User accounts
- API keys
- Watch folders
- Shortcuts, AppleScript, or CLI automation
- Full subtitle editing/burn-in workflow

## Target repository shape

```text
Inkribe/
├── InkribeMac/
│   ├── App/
│   ├── Shell/
│   ├── Features/
│   │   ├── Library/
│   │   ├── Recorder/
│   │   ├── Import/
│   │   └── TranscriptEditor/
│   ├── Settings/
│   ├── Developer/
│   │   └── Logging/
│   └── Resources/
│
├── Packages/
│   ├── InkribeCore/
│   ├── InkribeAudio/
│   ├── InkribeTranscription/     # JobQueue + WhisperRuntime integration
│   ├── InkribeAI/
│   ├── InkribePersistence/
│   ├── InkribeExport/
│   ├── WhisperRuntime/
│   └── LLMRuntime/
│
├── Models/                        # ignored; production or substituted fixtures
│   ├── whisper/
│   └── qwen/
├── testfixtures/                  # committed tiny valid fixtures
│   ├── whisper/
│   └── qwen/
├── InkribeMacTests/
├── InkribeMacUITests/
├── scripts/
│   ├── download-models.sh
│   └── validate-models.sh
├── ci_scripts/
│   └── ci_post_clone.sh
├── docs/
├── project.yml
├── Package.resolved
├── Makefile
└── .gitignore
```

The exact package count may be consolidated if some boundaries prove artificially small. The cross-platform dependency direction, `Models/` / `testfixtures/` contract, and JobQueue ownership boundary are mandatory.

---

# Phase 0 — Repository and build foundation

## Goals

Create a deterministic macOS project foundation and cross-platform package structure before feature development begins.

## Work

- Add `project.yml` with XcodeGen as the source of truth.
- Target macOS 15+ for the Mac app.
- Create shared local Swift packages declaring macOS 15+ and iOS 26+.
- Keep reusable packages free of AppKit and MacAppFoundation.
- Configure Debug and Release builds.
- Create app, unit-test, package-test, and UI-test targets as appropriate.
- Commit the generated `.xcodeproj` and shared scheme for Xcode Cloud.
- Resolve the latest stable MacAppFoundation tag at implementation time and pin it exactly in XcodeGen.
- Link MacAppFoundation only where Mac app/test code needs it.
- Add `hoangbkit/JobQueue` as an exact `1.0.0` dependency.
- Make `InkribeTranscription` depend on the `JobQueue` product and `WhisperRuntime`.
- Keep `Package.resolved` consistent with JobQueue `1.0.0` for reproducible local and Xcode Cloud builds.
- Configure bundle identifier `com.hoangbkit.inkribe`.
- Configure the three Pro product IDs and local StoreKit test catalog documented in `docs/PRODUCT_CONFIGURATION.md`.
- Create shared MacAppFoundation app-scoped state: `MacAppThemeStore`, `PurchaseManager`, `MacAppSettingsRouter`, and `OnboardingState`.
- Establish an app-scoped JobQueue persistence URL/configuration.
- Establish startup ordering: register all JobQueue job types before calling `queue.start()`.
- Bootstrap `swift-log` before other app services so startup/runtime logs are available immediately.
- Add a bounded observable `LogStore` and multiplex log handler modeled on Spokio `develop`, capturing logs for the Debug Logs window while preserving normal console output.
- Add `Makefile` entry points such as:
  - `make generate`
  - `make validate-project`
  - `make build`
  - `make test`
  - `make download-models`
  - `make validate-models`
- Add `.gitignore` with `Models/` ignored.
- Add basic app sandbox entitlements required for microphone input and user-selected file access.
- Establish logging and error-reporting conventions for local diagnostics without external telemetry dependency.
- Do not log transcript content, raw audio, or prompts containing transcript text by default.
- Keep `JobQueue` queue metadata free of transcript bodies; queue state and transcript content have separate ownership.
- Add/maintain architecture documentation for `whisper.cpp`, `llama.cpp`, JobQueue, model assets, shared packages, MacAppFoundation, developer tools/logging, and feature boundaries.

## Acceptance criteria

- Fresh clone can generate and build the empty app after dependencies are resolved.
- Generated project is reproducible and `make validate-project` catches drift.
- Shared scheme exists and can be consumed by Xcode Cloud.
- Shared local packages compile for macOS 15+ and iOS 26+.
- `InkribeTranscription` resolves `JobQueue` exact version `1.0.0`.
- `Models/` is never committed.
- Debug logs emitted through the configured logger are captured in the bounded in-memory `LogStore`.
- Job types can be registered and an empty JobQueue can start/load its store successfully.

---

# Phase 1 — Custom macOS shell and navigation

## Goals

Build the permanent desktop shell immediately so later features are implemented in the final visual/navigation structure rather than migrated later.

## Shell geometry contract

The shell must be built as two structural columns, not as a content view with a decorative sidebar layered on top:

```text
Window
├── SidebarColumn
│   ├── SidebarTitlebarArea      # traffic lights live here
│   └── SidebarContent
│
└── MainColumn
    ├── MainTitlebar             # page title + page actions
    ├── MainContent
    └── MainStatusOrPlayerBar    # when present; main column only
```

The divider between `SidebarColumn` and `MainColumn` is continuous from the very top of the window to the bottom. The titlebar split and body split must align exactly.

Expanded shell example:

```text
┌───────────────────┬──────────────────────────────────────────────────────────┐
│ ● ● ●          ◀  │ Library                               Search       +     │
├───────────────────┼──────────────────────────────────────────────────────────┤
│                   │                                                          │
│ ▣ Library         │                        CONTENT                           │
│ ● Record          │                                                          │
│ ↓ Import          │                                                          │
│                   │                                                          │
│                   │                                                          │
│                   ├──────────────────────────────────────────────────────────┤
│ ⚙ Settings        │ Whisper Small · Qwen 1.7B · Local only        Ready     │
└───────────────────┴──────────────────────────────────────────────────────────┘
```

Rules:

- Do not place `INKRIBE`, the current page title, search, export controls, or other main-toolbar content above the sidebar column.
- The sidebar titlebar area primarily owns the native traffic lights and the custom sidebar control.
- The main titlebar starts at the divider and owns the current page title and page-level actions.
- Main status bars and transcript player bars start at the divider and end at the right edge; they never cross underneath the sidebar.
- The sidebar stays one uninterrupted vertical region below its titlebar area.

## Sidebar toggle contract

Implement a custom sidebar toggle visually attached to the divider near the titlebar. It must move with the divider rather than being positioned independently.

Behavior:

- Derive both divider and toggle position from the same `sidebarWidth` state.
- Expanded width should use the final design-system width (initial target around 220 pt); collapsed width is 0.
- Animate width changes smoothly using a short ease-in-out animation; initial target ~0.20–0.25 seconds.
- The toggle travels with the divider for the full animation.
- The toggle should sit immediately adjacent to or slightly overlap the divider, never float deep inside either titlebar region.
- The main content expands/collapses continuously rather than snapping after the sidebar animation.
- Fade sidebar contents during the collapse/expand transition where needed to prevent ugly clipping.
- Flip the toggle glyph/state between collapse and expand.
- Keep the toggle reachable when the sidebar is fully collapsed.
- Persist the user's sidebar visibility state.
- Provide a standard menu/keyboard sidebar-toggle command wired to the same state transition.
- Respect Reduce Motion by simplifying or removing nonessential transition animation.
- Use the same shell state source for every screen so Library, Record, Import, Transcript Editor, and Settings never implement their own sidebar position or animation logic.

Collapsed concept:

```text
┌──────┬───────────────────────────────────────────────────────────────────────┐
│● ● ●▶│ Library                                               Search     +   │
├──────┼───────────────────────────────────────────────────────────────────────┤
│      │                                                                       │
│      │                         CONTENT                                       │
│      │                                                                       │
└──────┴───────────────────────────────────────────────────────────────────────┘
```

The exact toggle visual can evolve, but its geometry and behavior are part of the shell contract.

## Work

- Use native `NSWindow` underneath the shell.
- Implement the two-column root layout described above.
- Implement custom title-bar/toolbar presentation while preserving native window controls and behaviors.
- Implement the full-height sidebar/main divider and ensure titlebar/body/status-bar boundaries remain aligned through resize and fullscreen transitions.
- Implement custom sidebar/navigation.
- Implement the animated divider-attached sidebar toggle and shared `sidebarWidth` state.
- Centralize shell/sidebar state in one root shell model/state owner; feature screens consume it rather than recreating it.
- Persist sidebar visibility and expose a keyboard/menu command to toggle it.
- Ensure no content-only status/player bar extends beneath the sidebar.
- Style the custom shell from MacAppFoundation semantic theme roles.
- Add MacAppFoundation `ProPlanButton` in the main titlebar region only.
- Implement primary destinations:
  - Library
  - Record
  - Import
- Sidebar Settings action opens the separate MacAppFoundation `MacAppSettingsView` scene.
- Define the transcript editor as a primary detail surface rather than a modal workflow.
- Add empty/loading/error states.
- Add keyboard focus and accessibility behavior from the beginning.
- Add shell snapshot/UI tests for key window sizes, expanded/collapsed sidebar states, representative themes, and Reduce Motion behavior.

## Acceptance criteria

- Window looks and behaves consistently across supported macOS versions.
- Native resize, fullscreen, traffic lights, menu commands, focus, and accessibility continue to work.
- One continuous divider visually and geometrically separates sidebar from main content from top edge to bottom edge.
- Traffic lights remain in the sidebar titlebar region; page title/actions remain in the main titlebar region.
- Status/player bars are constrained to the main column and never cross under the sidebar.
- Sidebar collapse/expand animates the sidebar width, divider, toggle, and main-content width as one coordinated transition.
- Toggle remains usable when the sidebar is collapsed and the state survives relaunch.
- Sidebar geometry and toggle behavior remain identical when navigating between all primary screens.
- Shell remains correct at minimum supported window size, fullscreen, and with Reduce Motion enabled.
- Main shell is stable enough that later phases do not need navigation architecture rewrites.

---

# Phase 2 — Model asset pipeline and Xcode Cloud fixtures

## Goals

Make bundled inference assets deterministic, verifiable, and cheap to use in CI.

## Production model contract

```text
Models/
├── whisper/
│   └── <pinned-whisper-model>
└── qwen/
    └── <pinned-qwen-gguf>
```

Initial target:

- Whisper model suitable for high-quality offline Mac transcription through `whisper.cpp`.
- Qwen-class ~1.7B instruction model in GGUF, initially targeting a Q4-class quantization suitable for `llama.cpp`.

Exact model revisions, filenames, licenses, URLs, and checksums must be pinned before implementation is considered complete.

## Work

- Add `scripts/download-models.sh`.
- Download to temporary files first.
- Use pinned immutable model revisions/URLs rather than floating `latest` links.
- Validate SHA-256 before moving a file into its final path.
- Retry failed network downloads safely.
- Skip already-present files only when checksum validation passes.
- Redownload corrupted/mismatched files.
- Add `scripts/validate-models.sh` to validate:
  - required paths
  - expected file count/shape where applicable
  - no unexpected files where strict shape matters
  - SHA-256 checksums
- Add small committed fixtures under `testfixtures/` with the same public directory/file contract expected by application code.
- Add `INKRIBE_CI_USE_TEST_MODELS=1` behavior modeled after Spokio:
  - remove/replace real `Models/` contents
  - copy tiny fixture bundles into the normal `Models/` paths
  - perform no real model downloads
- Release/archive CI path downloads and validates real models.
- Add `Models/` to XcodeGen as folder resources so copied test fixtures and downloaded production assets are bundled identically.
- Add runtime validation with useful development errors when required model resources are missing.

## Important Xcode Cloud rule

Do **not** depend on running XcodeGen from `ci_post_clone.sh`. Follow the Spokio approach: commit the generated project, shared schemes, and package resolution needed before post-clone hooks execute. `ci_post_clone.sh` prepares model assets, not project structure.

## Acceptance criteria

- Test CI never downloads production model weights.
- Production/archive CI cannot succeed with missing or checksum-invalid models.
- App code uses identical bundle lookup paths with real and test models.
- Local developers can restore all production model assets with one command.

---

# Phase 3 — Native inference runtimes

## Goals

Integrate `whisper.cpp` and `llama.cpp` behind narrow cross-platform Swift-facing APIs before building product workflows around them.

## Work

### Whisper runtime

- Vendor or pin `whisper.cpp` in a reproducible way.
- Create a Swift-friendly runtime wrapper usable from macOS 15+ and iOS 26+.
- Support model load/unload lifecycle.
- Support file/buffer transcription.
- Expose segment text and timestamps.
- Expose detected language and allow a requested language.
- Configure sensible thread counts for Intel and Apple Silicon.
- Use Metal acceleration where supported.
- Provide cancellation and progress callbacks.
- Prevent concurrent unsafe access to shared model state.
- Emit structured diagnostic logs for model lifecycle, timing, cancellation, and failures without transcript/audio content.

### LLM runtime

- Vendor or pin `llama.cpp` reproducibly.
- Create a Swift-friendly wrapper around model loading, prompt evaluation, token streaming, cancellation, and sampling.
- Keep its public API compatible with macOS 15+ and iOS 26+.
- Use Metal acceleration on Apple Silicon where supported.
- Support CPU fallback on Intel.
- Establish conservative context/token limits for v1 text transformation workloads.
- Keep model/runtime details out of feature UI.
- Emit structured diagnostic logs for model lifecycle, chunking/generation timing, cancellation, and failures without user transcript/prompt text.

### Runtime policy

- Model runtimes must be independently testable.
- Loading failures must produce actionable errors rather than crashes.
- Large model objects should have explicit lifetime/memory ownership.
- App should not keep unnecessary models resident when memory pressure makes unloading appropriate.

## Acceptance criteria

- Tiny CI fixtures can exercise model-discovery/loading paths.
- At least one real local smoke test can transcribe known audio with Whisper.
- At least one real local smoke test can generate deterministic-enough cleanup output from Qwen.
- Cancellation works for both inference pipelines.
- Runtime diagnostics appear in the Debug Logs window without exposing transcript/audio contents.
- Shared runtime packages compile for macOS 15+ and iOS 26+.

---

# Phase 4 — Recording, import, JobQueue, and transcription pipeline

## Goals

Deliver the core value loop: audio in, durable local job, local transcript out.

## Recording

- Microphone permission flow.
- Input device enumeration and selection.
- Record, pause, resume, stop.
- Live level meter.
- Durable local recording file creation.
- Handle device removal/change and recording interruptions gracefully.

## Import

- File picker.
- Drag and drop.
- Support common audio types: WAV, M4A, MP3.
- Support common video containers such as MP4/MOV by extracting/decoding the audio stream locally.
- Validate unsupported/corrupt files with useful errors.
- Copy/normalize imported source media into Inkribe-controlled durable storage before enqueueing so a restored job does not depend on a temporary file-picker security scope.

## JobQueue contract

Use `hoangbkit/JobQueue` exact version `1.0.0` as the only queue/scheduler/state machine.

Implement a persistent shared `TranscriptionJob: Job` in `InkribeTranscription`.

Conceptual payload:

```text
TranscriptionJob.Payload
├── transcriptID
├── sourceMediaRelativePath
└── requestedLanguage?
```

Payload requirements:

- `Codable & Sendable`
- durable across relaunch
- no model/runtime object references
- no SwiftUI/AppKit state
- no open file handles or temporary security-scope sessions
- no transcript body copied into queue metadata

Start with:

```swift
TranscriptionJob.maxConcurrentExecutions = 1
```

Whisper is resource-intensive; do not enable parallel transcription until profiling proves it improves responsiveness/throughput.

Register the job before queue startup:

```swift
try JobRegistry.shared.register(TranscriptionJob.self)
try queue.start()
```

Use JobQueue for:

- enqueueing multiple imported/recorded files
- persisted pending state
- scheduling
- progress reporting through `JobProgressReporter`
- priority
- cancellation
- pause/resume
- retry
- restoration after app relaunch
- failed/unrecoverable state
- queue events
- completed-record cleanup policy

Do not duplicate those transitions in an Inkribe feature view model.

## Queue presentation

Map JobQueue state directly into Inkribe UI:

```text
pending        → Waiting
processing     → Transcribing
pausing        → Pausing
cancelling     → Cancelling
completed      → Complete
failed         → Failed
cancelled      → Cancelled
unrecoverable  → Needs attention
```

Use JobQueue live progress as the source for queue progress bars/messages.

The Import/Queue screen can add Inkribe-specific display metadata and navigation, but it must not maintain a second queue truth.

## Transcription execution

`TranscriptionJob.execute(progress:)` should conceptually:

1. resolve the durable app-owned source media;
2. normalize/decode audio if needed;
3. load/use `WhisperRuntime`;
4. report meaningful progress;
5. generate segments + language metadata;
6. persist/update the target transcript identified by `transcriptID`;
7. return success only after the transcript write is durable.

Retry must be idempotent enough that it updates the intended transcript record instead of silently creating duplicates.

## Logging

Attach JobQueue events to the app's privacy-safe Debug log pipeline.

Log useful lifecycle information such as enqueue/start/completion/failure/cancellation, persistence failures, and restoration issues. Never log transcript or audio contents.

## Acceptance criteria

- A user can record speech and obtain a transcript without network access.
- A user can drop multiple files and they appear as persistent JobQueue records.
- Queue progress is visible and driven from JobQueue state.
- Failed/cancelled jobs are retryable where JobQueue allows it.
- Cancellation works and propagates to the transcription runtime.
- Quitting/reopening restores pending/failed queue state correctly.
- Successfully created transcript content remains in Inkribe persistence, independent of JobQueue record cleanup.
- Retry does not create duplicate transcript records.
- Transcription executes one job at a time by default.
- No home-grown competing queue scheduler/state machine exists.

---

# Phase 5 — Local library and transcript editor

## Goals

Turn transcription output into a useful Mac document workflow rather than a one-shot conversion screen.

## Work

### Library

- Local-only persistence for recordings/transcripts and metadata.
- Recent transcripts.
- Search by title/content.
- Rename.
- Delete with clear handling of associated source audio.
- Basic sort/filter sufficient for v1.
- Keep transcript/library persistence separate from JobQueue processing metadata.

### Transcript editor

- Editable transcript text.
- Segment/timestamp representation retained behind the editor model.
- Audio playback controls.
- Click transcript segment to seek audio.
- Current playback segment highlighting where practical.
- Transcript search.
- Unsaved-edit protection if persistence is not continuous.
- Clear distinction between raw transcript and user/AI-edited text so reprocessing does not destroy user edits.

## Acceptance criteria

- Library is useful with dozens/hundreds of transcripts.
- Transcript text can be edited without breaking source audio metadata.
- Seeking from a timestamped transcript reliably jumps to the corresponding audio position.
- Clearing completed JobQueue records does not delete completed transcript/library content.

---

# Phase 6 — Offline AI cleanup and text tools

## Goals

Use the bundled Qwen/`llama.cpp` stack for constrained transcript transformation, not generic chat.

## User-facing actions

- **Clean** — punctuation, capitalization, filler/repetition removal, conservative correction of obvious STT errors.
- **Polish** — convert spoken phrasing into cleaner written prose while preserving meaning.
- **Summarize** — concise summary of the transcript.
- **Notes** — structured notes/headings/bullets.
- **Action Items** — extract explicit tasks/next steps without inventing commitments.

## Work

- Define versioned prompt templates in source control.
- Strongly constrain prompts to avoid invented facts during cleanup.
- Implement chunking for transcripts that exceed the model context window.
- Preserve ordering when processing chunks.
- Provide progress and cancellation.
- Keep original transcript recoverable.
- Let users replace current text or create a derived version according to the action.
- Add guardrails for empty/very short transcripts.
- Add tests around prompt construction and chunk/merge behavior.
- Use MacAppFoundation `ProBadge`, `ProUpsellView`, and/or gate primitives for any AI actions selected as Pro.
- Keep the inference path offline regardless of entitlement state.
- Do not force AI transforms through JobQueue in v1 unless persisted/background AI processing becomes a concrete requirement; JobQueue's initial responsibility is durable transcription/import work.

## Acceptance criteria

- All AI actions work with networking disabled.
- Cleanup does not silently overwrite the only copy of the original transcript.
- Long transcripts are handled without exceeding model context limits.
- Feature UI never exposes GGUF/runtime terminology unless needed in diagnostics/settings.

---

# Phase 7 — Export and finishing workflows

## Goals

Make the result easy to move into the user's actual work.

## Work

- Copy current transcript to clipboard.
- Export plain text (`.txt`).
- Export Markdown (`.md`).
- Export SRT from timestamped segments.
- Export VTT from timestamped segments.
- Sensible filename generation from transcript title/date.
- Native save panel and overwrite behavior.
- Preserve Unicode and multilingual text correctly.
- Add menu commands and keyboard shortcuts for common export/copy actions.

## Acceptance criteria

- Every supported export can be re-opened by a standard external tool.
- SRT/VTT timestamps remain monotonic and valid after transcript editing rules are applied.
- Export never requires network access.

---

# Phase 8 — Settings, performance, and compatibility

## Goals

Make behavior predictable across hardware classes without turning settings into a model-management UI.

## Work

- Use MacAppFoundation `MacAppSettingsView` as the actual native Settings scene.
- Add Inkribe-specific Settings panes for General/Transcription/AI Cleanup/Storage/About as finalized.
- Reuse MacAppFoundation built-in Appearance + Plan panes.
- Default microphone selection.
- Default transcription language / Auto.
- Sensible STT performance controls only if real hardware testing proves they are necessary.
- Local AI behavior settings only where user value is clear.
- Storage usage and deletion controls.
- Diagnostics view for model presence/version, architecture, Metal availability, runtime errors, and JobQueue persistence issues where useful.
- Apple Silicon performance profiling.
- Intel performance profiling and CPU-path validation.
- Memory-pressure testing with both STT and LLM models.
- Very long audio/file stress tests.
- App launch performance with bundled multi-GB assets and restored queue state.

## Acceptance criteria

- Supported Intel Macs can complete core STT and AI workflows without architecture-specific crashes.
- Apple Silicon uses acceleration as intended.
- App remains responsive while inference is running.
- Memory use is controlled when switching between STT and LLM work.
- Restoring queued jobs does not stall the UI or start unsafe duplicate work.

---

# Phase 9 — Test suite, Xcode Cloud, and release hardening

## Goals

Prove the offline product works reproducibly before App Store submission.

## Test layers

### Unit tests

- transcript models
- timestamp conversion
- export formatting
- prompt construction
- chunking/merge logic
- persistence behavior
- model path/config validation
- log-entry formatting and bounded log-store retention
- `TranscriptionJob` Codable round trip
- JobQueue status-to-display mapping

### JobQueue integration tests

- job type registration/restoration
- pending queue persistence across relaunch
- processing-record recovery semantics after relaunch
- progress propagation
- cancellation
- failure → retry → completion
- multi-file ordering
- single-concurrency transcription
- missing durable source media
- queue persistence failure/recovery
- retry without duplicate transcript creation

### Runtime fixture tests

- tiny valid Whisper fixture discovery/load path
- tiny valid GGUF fixture discovery/load path
- missing/corrupt model behavior
- checksum validator success/failure behavior

### Integration tests

- known audio → JobQueue → STT result
- imported media → durable app storage → queue → decoded audio → transcription
- app relaunch with persisted pending/failed queue records
- transcript → cleanup pipeline
- transcript → SRT/VTT

### UI tests

- custom shell navigation
- import flow
- recording flow where automation permits
- JobQueue waiting/running/progress/failure/cancel/retry presentation
- library → editor
- AI action state/progress/error UI
- export entry points
- onboarding first launch/resume/completion/replay
- Settings routing and theme synchronization
- Free/Pro `ProPlanButton` routing
- MacAppFoundation Developer Tools window opening in Debug
- Developer → Show Logs opening/focusing the standalone Logs window
- whole-log copy, clear, and live append/auto-scroll behavior where automation permits

## Xcode Cloud

Test workflow:

```text
clone
  -> resolve JobQueue exact version 1.0.0 from committed package state
  -> ci_post_clone.sh
  -> INKRIBE_CI_USE_TEST_MODELS=1
  -> copy committed testfixtures into Models/
  -> build + test
```

Archive/release workflow:

```text
clone
  -> resolve committed package state
  -> ci_post_clone.sh
  -> download pinned production models
  -> SHA-256 + shape validation
  -> archive
```

No production model downloads should occur in normal test CI.

## Release hardening

- Test with networking disabled.
- Audit app for unexpected outbound connections.
- Verify licenses/notices for Whisper model, Qwen model, `whisper.cpp`, `llama.cpp`, JobQueue, MacAppFoundation, and other bundled third-party software/assets.
- Verify App Sandbox permissions are minimal.
- Verify hardened runtime and code signing.
- Verify Intel and Apple Silicon archive slices as intended.
- Measure final App Store download/install size.
- Verify model resources exist in the archived `.app`.
- Verify clean install works with no first-run downloads.
- Verify persisted JobQueue records can be loaded/recovered without network access.
- Verify the Debug-only Developer menu, MacAppFoundation Developer Tools window, in-app Log window, and Debug logging UI are absent from the Release/App Store build.
- Prepare App Store metadata and screenshots.

## Acceptance criteria

- Test Xcode Cloud workflow passes without production model downloads.
- Xcode Cloud resolves JobQueue exact version `1.0.0`.
- Queue restoration/retry/cancellation integration tests pass.
- Archive workflow cannot produce an app with missing/corrupt production models.
- Fresh installed release works fully offline immediately after installation.
- All third-party model/runtime/library licenses and notices are accounted for.
- Release build contains no Debug Developer Tools or Logs UI.

---

# Recommended implementation order

The phases are intentionally ordered to avoid expensive rewrites:

1. **Foundation** establishes XcodeGen, shared packages, JobQueue `1.0.0`, MacAppFoundation state, product configuration, logging, and repository rules.
2. **Custom shell** locks the desktop UX before features spread across temporary navigation.
3. **Model pipeline** makes local and CI builds deterministic before inference integration.
4. **Inference runtimes** prove both core ML engines in isolation.
5. **Recording/import/JobQueue/transcription** delivers the first complete persistent value loop.
6. **Library/editor** turns output into a real desktop workflow.
7. **Offline AI tools** add the second model only after transcript ownership/editing is stable.
8. **Export** completes the user's workflow.
9. **Compatibility/performance** tunes both Apple Silicon and Intel behavior.
10. **Release hardening** validates the exact bundled, offline product shipped to users.

Each implementation phase should be developed on its own branch/PR, completed with tests appropriate to that phase, and squash-merged so `master` stays readable.

# V1 definition of done

V1 is done when a fresh App Store-style installation can, with networking disabled:

1. Launch into the custom Inkribe Mac shell.
2. Record microphone audio or import supported audio/video files.
3. Copy/normalize imported media into durable app-owned storage and enqueue persistent transcription work through `hoangbkit/JobQueue` `1.0.0`.
4. Restore pending/failed queue state after relaunch and support progress, cancel, and retry without a second queue implementation.
5. Transcribe entirely locally with `whisper.cpp`.
6. Store and edit the transcript locally with timestamps and synchronized playback.
7. Run Clean, Polish, Summary, Notes, and Action Items entirely locally through `llama.cpp` and the bundled Qwen model.
8. Export TXT, Markdown, SRT, or VTT.
9. Complete all core flows on supported Apple Silicon hardware and the documented Intel support baseline.
10. Pass Xcode Cloud tests using tiny committed fixture models without downloading production weights while resolving JobQueue exact version `1.0.0`.
11. Produce a release archive whose bundled production models pass pinned checksum validation.
12. Use the pinned MacAppFoundation release for themes, onboarding, Settings, StoreKit/Pro, paywall, plan controls, badges, and upsell surfaces.
13. Provide Debug-only MacAppFoundation Developer Tools and a separate Spokio-style Logs window from the Developer menu while keeping both absent from Release builds.

See `docs/JOB_QUEUE.md` for the authoritative JobQueue integration details and `docs/SHARED_PACKAGES.md` for the cross-platform package contract.