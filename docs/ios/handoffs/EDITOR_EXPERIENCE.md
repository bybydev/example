# Pass 4 handoff — editor experience

2026-10-24 (Vietnam). PR #39 → develop, open without auto-merge. Passes 1–4 are
source-integrated; pass 5 remains pending. This records implementation evidence,
not compilation, runtime acceptance or a production-ready claim.

## Source integration

| Area | Implementation | Evidence limit |
|---|---|---|
| Editor page | ProjectDetailView uses one main scroll, lazy caption rows, inline tools/workspaces, growing preview and native Back/Export/keyboard controls | Small-iPhone/landscape/keyboard/scroll and native gestures unrun |
| Corrections | Session-owned accepted caption/word drafts, timing/trim field context, inline split/merge/timing and gap retry | Actual IME, RTL, paste, partial publication and recovery interaction unrun |
| Browsing | CaptionPreset adapts existing five looks; CaptionTemplatesPanel uses one capped frame and five styled snapshots with the production renderer | AVAssetImageGenerator/long captions/frame timing, memory and performance unrun |
| Customization | Focused style sections include live preview/transport, contextual resets and existing Pro checks | Playback/layer ownership, color picker, expiry/restore/undo acceptance unrun |
| Shared seams | Value-only EditorHistory application/coalescing/budget; existing CaptionEdits/CaptionSnapshot independent of SwiftUI | Not moved into a new generic package; current Mac behavior untouched |
| Persistence/delivery | Existing writer/journal, schema 7, session registry, frozen multi-export requests and queue authorization retained | Disk/native/export/provider execution unrun |

## Behavior and edge cases

Tool changes pause without seeking. Scroll anchors are stored separately by tool;
retiring scroll views write only their captured tool's anchor. Native focus remains
presentation-owned; playback-follow is explicit/off by default and never selects a
caption or opens the keyboard. Follow plus direct user scrolling still needs device
review. Expanded preview grows within the same page and keeps other content.

Caption/word fields accept a UI draft only when the value-only command succeeds;
rejected over-limit/invalid input leaves the previous accepted correction and shows
the command error. Whitespace drafts survive row/tool recreation. Explicit undo,
reload or incompatible canonical replacement clears field drafts. Canonical edits
use the existing write-ahead journal; UI-only whitespace/timing/trim draft strings
and scroll context are retained in memory, not promised recoverable after process
termination. Timing/trim Apply still validates original-clock intervals. Undo/redo
clears unapplied UI strings rather than replaying them over restored canonical data.

Preset cards freeze one real comparison frame and evaluate actual caption/effect
state at its returned output time. They do not animate with playback or display
fabricated sample text. Playback labels the frozen comparison and pause refreshes
it. Crop/trim/canvas/relink graph replacement invalidates the image; volume-only
changes do not rebuild video. Cancellation and generation guards reject stale
callbacks. Audio-only projects use the actual black output canvas plus a decorative
waveform. Missing/empty captions/gaps stay empty, with a selected-caption reveal
when available. Long/oversized styles show renderer errors rather than dummy text.

Basic plus Spotlight/Karaoke/Pop/Soft Fade are the existing catalog. Preset apply
keeps placement; custom placement is stated separately. Appearance changes show
Customized. Reset look identifies the exact target (last chosen look in this session,
matching saved look, otherwise Basic); full Basic reset also resets placement.
No provenance is fabricated for old customized projects. Existing expiry permissions
may allow a retained premium font/effect; locks reflect that same access predicate.

History extraction preserves expected-state checks, raw/native timing and append-
only recognition behavior. New edits clear redo. Continuous sliders coalesce only
within their control gesture, and discrete preset applications are separate. Budget
remains 50 operations/8MiB, retaining one oversized operation. No persisted schema,
raw captions, queue IDs/formats, billing or native runtime behavior was migrated.

## User validation — all pending

1. Open partial and complete video/audio projects. Scroll from preview through
   timeline/tools to the last caption. Confirm nothing sticks; expand/reduce and
   switch tools without losing playhead, selection, accepted text or scroll context.
2. Correct a whole caption including spaces, emoji, CJK/RTL and IME composition.
   Switch tools and return; undo/redo after publication/save. Paste over-limit text
   and verify an explicit error with the previous accepted edit retained.
3. Focus fields near the bottom, dismiss/reopen keyboard, change text size and
   rotate available layouts. Inspect long captions, headings/buttons and timing/
   trim fields at large accessibility text; no clipped controls or inner text scroll.
4. Play with follow off/on. Select a different caption or word, type, scrub, switch
   tools and return from an inspector; verify playback never steals correction focus.
5. Open Style on speech, silence, hidden captions, missing ranges, audio clips and
   video/audio transitions. Compare all five cards against actual preview footage,
   caption time, trim/crop/aspect and effect phase. Exercise image failure/retry and
   rapid scrub/tool changes; inspect cancellation/memory on supported iPhones.
6. Apply every existing look; check selected/Customized/custom-position states,
   named look reset, full Basic reset and each section reset. Inspect immediate
   customization feedback while its sheet is open; play/scrub motion there, then
   dismiss and confirm the main player layer/scroll context returns correctly.
7. Verify one undo for a slider gesture, separate undo per preset, redo invalidation,
   expected-state conflicts, budget behavior, save failures and draft recovery after
   native completed/cancelled back gestures. Check original captions/raw IDs/timing.
8. Free/Pro/expiry/restore: locks/upsells, retained premium projects and free resets.
   Queue several exports from different revisions; verify frozen styles/media and
   preview/MP4/SRT parity plus per-output Save/Share. No exactly-once charge changes.
9. VoiceOver headings/selected pills/locked cards/errors/scrub labels and 44pt
   controls; all supported AF themes, contrast and Reduce Motion. Run authorized
   compilation and targeted acceptance before calling this production-ready.

No checks above were executed by the agent. Shared package regression sources
from earlier passes also remain unexecuted. Follow-up belongs in this same PR until
explicit merge; expanded style capabilities/catalog and release evidence are pass 5.

---

## Approved scope — archived brief (consolidated 2026-11-07)


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

