# Issue #38 — production pass 4: complete editor experience

Date: 2026-10-24 (Vietnam). Existing PR #39, feat/ios-project-packages → develop,
retaining passes 1–3. Existing scoped V1 IDs: TEXT, TIMING, UNDO, STYLE, PRESETS,
MEDIA, RECOVERY, AUTOSAVE, MP4, SRT, ACCESS, PRO, BOUNDS, HANDOFF.

## Approved direction and references

AppShot at daac39743e49d2ac39fc3cb498d41b5787705add was read through its
ProjectEditorView, EditorComponentInspector and TemplateBrowserView. Adapt its
whole-page scrolling canvas, horizontal component choices, focused inspectors,
content-backed comparisons and contextual resets to actual timed captions/video.
AppReel's home hero/CTA remains integrated from pass 3. Theme surfaces, border,
foreground/accent and semantic fonts remain AppFoundation-owned.

One main vertical scroll: actual video/audio canvas → transport/timeline →
Captions/Style/Timing/Media pills → active workspace. Expansion grows the preview
in the same page; it never hides the tools or pins footage. Native Back, keyboard
Done and Export stay in native chrome. No bottom editor safe-area inset, floating
preview, nested vertical transcript scroll or UIKit gesture override.

## Implementation contract

- Whole-caption text remains the primary editable transcript. Existing phrase/
  word text, original-clock timing, split/merge and missing-range retry remain
  available inline. Preserve native timing, stable IDs, raw recognition, accepted
  partial publication and user edits; no synthesized sub-word boundaries.
- Playback-follow is explicit and off initially. Following only scrolls visible
  captions during playback and never changes selection or keyboard focus.
  Selecting/editing pauses playback; switching tools pauses without seeking.
- App-owned session retains per-tool scroll anchors, expansion, selection/time,
  accepted correction whitespace, active timing/trim field drafts. Focus and
  geometry changes reveal fields. Timing and trim require explicit Apply.
  Unapplied timing/trim UI fields are in-memory context, not canonical saved edits.
- Style browser leads with Basic plus the four existing templates. Each card
  compares the actual paused footage and actual captions at the frame's output
  time, through CaptionRenderer. One asynchronous media-only image generator,
  capped at 480 × 480, serves all five cards. No per-card player/model/export.
  Exact requested time, cancellation/generation rejection, composition invalidation,
  explicit retry and honest audio/gap/empty/phrase/error states are included.
- Styled snapshots share immutable indexes/timing; cards retain one styled
  snapshot/layout each. No per-frame reconstruction of recognition indexes or
  five media graphs. Live motion uses the actual editor player, not card animation.
- Applying a preset preserves placement. Matching looks are selected; customized
  appearance and custom placement are explicit. Reset look names its target and
  preserves position; full Basic reset and per-section resets are explicit.
  Legacy customized looks have no invented preset ancestry. No schema/catalog IDs
  are persisted by this browser.
- Focused Text/Colors/Backdrop/Position/Motion customization has one scrolling
  preview, transport, section choices and controls. The main player layer is
  removed while the sheet owns the same player. No duplicated player/decoder.
  Playback, section changes and dismissal end continuous undo groups. Preset
  applies remain discrete. Existing 600ms autosave/journal writer is retained.
- Existing ProAccess.canChangeStyle determines locks and applies. Retained premium
  styles, expiry, free changes and upsell/restore policy remain unchanged.
- Export/Queue still use the session's durable savedDocument and existing frozen
  per-job requests. No direct exporter or generic speech-retry bypass is added.

## Shared-code boundary

CaptionEdits and CaptionSnapshot already evaluate value snapshots independently
of SwiftUI. EditorHistory now owns value-only selection/change payloads, expected-
state undo/redo application, coalescing and the existing 50-command/8MiB budget.
EditorSession still owns playback, observation, save serialization and entitlement
checks; EditorWorkspace holds ephemeral presentation context. CaptionPreset is an
adapter over existing style values. These seams can move with the canonical iOS
caption domain when a future Mac adapter is requested; they do not copy domain
models into InkribeCore or replace current Mac Transcript/render APIs now.

## Limits and acceptance

Source integration only. No builds/typechecks/tests/fixtures, CI, generation,
model downloads, native inference/exports, UI/device/accessibility execution or
deployment. No new test target or execution harness. See the handoff for pending
user scenarios. Expanded caption model/rendering, final 8–12 curated presets and
production evidence remain pass 5. Current catalog/renderer limits still apply.
