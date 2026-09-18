# Post-v1 Consolidation Contract

## Status

The v1 implementation plan (Phases 0–9) is complete. This document defines how post-v1 consolidation should clean the source tree without introducing new product scope or weakening established guarantees.

The initial consolidation work is tracked on PR #12 and must remain open until explicitly approved for merge.

## Goals

Consolidation should:

- reduce duplicated presentation/orchestration code;
- make file ownership match feature ownership;
- remove stale phase-era assumptions from current documentation;
- preserve package boundaries, privacy, offline behavior, persistence semantics, and runtime ownership;
- prefer smaller, behavior-neutral structural changes over speculative rewrites.

Consolidation is not a new feature phase.

## Current consolidation decisions

### Settings ownership

The Phase 8 Settings implementation grew into one large file containing pane composition plus every pane implementation.

The consolidated structure keeps:

- `InkribeSettingsView.swift` for pane IDs, pane ordering, shared MacAppFoundation composition, and plan purchase routing;
- one source file per Inkribe-owned pane;
- `SettingsSupport.swift` for namespaced Settings-only layout/format helpers.

This keeps pane-local state and side effects next to the pane that owns them without changing persisted preference behavior.

### Transcript finishing ownership

Clipboard/export entry points existed in both the app command menu and transcript titlebar, each independently creating tasks and handling failures.

The consolidated structure keeps:

- `TranscriptExportCoordinator` for AppKit clipboard/save-panel mechanics;
- `TranscriptExportActions` for shared presentation task, privacy-safe logging, and error presentation;
- `InkribeExport` as the cross-platform formatter/source-selection layer.

Both UI entry points use the same action façade.

### MacAppFoundation integration

The consolidation review found that Inkribe created an app-scoped `OnboardingState` in Phase 0 but never presented MAF onboarding.

PR #12 now:

- uses `OnboardingWindow` for first-launch presentation;
- applies `OnboardingState.mainWindowLaunchBehavior` so the main window is suppressed until completion;
- uses `OnboardingView` + `OnboardingStepMessage` with Inkribe-owned product content;
- injects the shared `MacAppThemeStore` into onboarding;
- exposes onboarding status + replay through MAF Developer Tools.

After the Free/Pro policy was explicitly selected, PR #12 completed the remaining MAF Pro integration without inventing new app features:

- Local AI generation is Pro;
- multi-file batch import is Pro while single-file import remains Free;
- SRT/VTT export is Pro while Copy/TXT/Markdown remain Free;
- `ProPaywallView`, `ProUpsellView`, `ProBadge`, `ProGateButton`, and `PremiumAccessPolicy` are now used at those action boundaries;
- existing transcript documents and saved derived results remain accessible after entitlement loss.

### App-state boundary

`InkribeAppState` is intentionally not split only because it is large. Its recording/import operations, queue ownership, transcript repository, durable media store, and transcript mutations form one app-layer transaction boundary.

Splitting that type across source files would currently require widening private mutation access. Consolidation must not reduce encapsulation merely to make files shorter.

## Documentation authority

Current behavior should be read from:

- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/SHARED_PACKAGES.md`
- `docs/JOB_QUEUE.md`
- `docs/MODEL_ASSETS.md`
- `docs/NATIVE_RUNTIMES.md`
- `docs/TRANSCRIPTION_PIPELINE.md`
- `docs/TRANSCRIPT_WORKSPACE.md`
- `docs/LOCAL_AI.md`
- `docs/EXPORT.md`
- `docs/SETTINGS_PERFORMANCE.md`
- `docs/RELEASE_HARDENING.md`

The numbered files under `docs/handoffs/` and `docs/V1_IMPLEMENTATION_PLAN.md` are historical implementation records. They remain useful for why a boundary was introduced, but later focused contracts supersede them when wording differs.

## Reviewed hotspots deliberately left intact

The consolidation pass also reviewed the largest remaining source files rather than mechanically splitting them by line count.

- `TranscriptEditorView` keeps one editor-state owner because toolbar mode, search, edited text, timestamped segments, playback position, autosave, and local-AI preview/application are tightly coordinated. Extracting those into separate files would currently add binding/state plumbing without removing duplicate behavior.
- `InkribeAppState` remains one app-layer transaction boundary for recording/import, queue/repository/media ownership, and transcript mutations; splitting it would widen mutation access.
- `MicrophoneRecorder`, `NativeWhisperRuntime`, and `NativeLLMRuntime` remain cohesive ownership units around hardware/native resources and lifecycle.
- Large focused regression-test files are not split solely for aesthetics; test grouping should follow the production contract they exercise.

Future extraction is appropriate when one of these files gains an independently owned state machine or reusable behavior, not merely when its line count grows.

## Non-goals

This consolidation does not:

- add new transcript, AI, export, recording, or queue features;
- change JobQueue ownership or scheduling;
- change Raw/Edited transcript semantics;
- change model identities or native runtime policy;
- add online providers or networking;
- introduce premium capabilities outside the centralized three-feature v1 policy;
- weaken durable-state failure behavior;
- reorganize shared packages without a concrete ownership problem.

## Review checklist

Before this consolidation PR is considered merge-ready:

- no duplicated export execution/error plumbing remains between app-menu and titlebar entry points;
- Settings pane behavior remains pane-local and composition remains centralized;
- Settings-only helpers do not pollute the module-global namespace;
- historical phase documents are clearly distinguished from current contracts;
- repository layout docs match the actual source tree;
- no privacy, persistence, queue, or runtime invariant is weakened.
