# Consolidation Handoff — Post-v1 Architecture Cleanup

## Status

The consolidation implementation is complete on PR #12.

Per explicit instruction, PR #12 remains open and must **not** be merged until separately requested.

## Delivered

### Settings ownership cleanup

- reduced `InkribeSettingsView.swift` to pane composition and plan routing;
- moved General, Transcription, AI Cleanup, Storage, Diagnostics, and About into separate pane-owned source files;
- centralized pane-only scrolling and byte formatting under `InkribeSettingsSupport`;
- preserved existing preference, storage, diagnostics, and model-lifetime behavior.

### Transcript export presentation cleanup

- added `TranscriptExportActions` as the single Mac presentation orchestration path for transcript copy/export;
- centralized task creation, privacy-safe logging, and error presentation;
- kept `TranscriptExportCoordinator` focused on clipboard/save-panel mechanics;
- kept `InkribeExport` as the cross-platform formatting/source-selection layer;
- removed duplicate task/error implementations from the transcript titlebar.

### MacAppFoundation integration cleanup

- completed the previously-unused app-scoped onboarding state with a real MAF `OnboardingWindow`;
- suppresses the main window on first launch through MAF launch behavior;
- uses MAF `OnboardingView` and `OnboardingStepMessage` while keeping all onboarding content Inkribe-owned;
- shares the same `MacAppThemeStore` with onboarding;
- adds onboarding status + replay to MAF Developer Tools;
- adds a focused app-level onboarding configuration regression test;
- wires the MAF `ProPaywallView` as the shared purchase surface;
- wires contextual `ProUpsellView` flows;
- uses `ProBadge` on locked premium actions;
- uses MAF gate primitives / `PremiumAccessPolicy` against the centralized three-feature policy;
- enforces Batch Transcription at the actual queue boundary: Free may start one file only when no transcription is already active/waiting, while Pro may add multi-file or overlapping queued work;
- keeps existing local content accessible independent of entitlement;
- uses explicit placeholder Terms/Privacy HTTPS URLs in the paywall; both are centralized in `InkribeCommerce` and must be replaced before submission.

### Documentation consolidation

- marked the v1 implementation plan as complete/historical;
- clarified that numbered phase handoffs are historical implementation records;
- added `docs/CONSOLIDATION.md` as the post-v1 cleanup contract;
- updated README development guidance for the completed v1 state;
- corrected the architecture repository layout from stale `TranscriptEditor/` wording to the actual `Transcript/` feature directory;
- documented current Mac-layer Settings/export ownership.

## Deliberate non-changes

- no new product features;
- no JobQueue scheduler/state changes;
- no persistence-format or Raw/Edited semantic changes;
- no model/runtime identity or native tuning changes;
- no entitlement changes;
- no networking changes;
- no shared-package reshuffle without an ownership problem.

The pass reviewed remaining large source files and intentionally kept `TranscriptEditorView`, `InkribeAppState`, `MicrophoneRecorder`, and the native runtime implementations cohesive because splitting them now would widen state/resource plumbing rather than reduce duplicate behavior.

## Invariants preserved

1. JobQueue remains the sole transcription scheduler/state owner.
2. Inkribe persistence remains transcript/library truth.
3. Raw Whisper text remains separate from Edited text.
4. Export remains explicit about Edited/Raw source selection and segment-based subtitles.
5. Transcript/audio/prompt/generated/exported content stays out of default diagnostics.
6. Core app behavior remains fully offline.
7. Shared packages remain free of Mac presentation concerns.
8. App-layer transaction/native-resource ownership is not weakened for cosmetic file-size reduction.

## Merge state

PR #12 is intentionally open. Do not squash-merge it until the user explicitly asks.
