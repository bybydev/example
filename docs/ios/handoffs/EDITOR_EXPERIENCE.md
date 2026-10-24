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
