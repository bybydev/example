# macOS Chat Phase 3 — List Experiment

## Goal

Evaluate a native SwiftUI `List` as the macOS transcript container, stacked on PR #23, without carrying forward the failed `LazyVStack` experiment from PR #24.

## Scope

- Keep explicit source-message and bottom IDs.
- Avoid persistent `ScrollPosition` restoration.
- Avoid transcript-wide `.scrollTargetLayout()`.
- Use a stripped-down `List` with separators/background/insets neutralized so chat styling remains custom.
- Preserve user-scroll-away behavior and follow-latest behavior.
- Preserve source-message navigation and MCP rows.
- No Markdown parser/table/provider/composer/business-logic changes.

## Decision rule

This PR is an isolated experiment. If `List` introduces layout, selection, row-height, or live-streaming regressions, it can be dropped independently while PR #23 remains unchanged.
