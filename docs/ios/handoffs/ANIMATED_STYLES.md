# Animated Styles sheet — handoff

2026-10-26. User-approved design, feat/ios-animated-style-sheet → develop, base
81b820715ffec18862feb3eaac7e7adca303f7fd. Keep the PR open without auto-merge.
Prior project experience PR #42 is merged. Multi-clip projects remain supported.

Latest presentation update: the user requires Styles to always open large. The
picker now supports only `.large`; medium selection/state and medium-background
interaction are removed. This supersedes medium-sheet descriptions below. The
scrollable content, apply footer, Done and swipe dismissal remain available.
Source/diff review only; no build, CI rerun or device validation was performed.

Latest editor correction: opening Styles no longer replaces the scrolling editor
with a compact preview, resets expanded-preview state, or selects another workspace
and scroll identity. The picker simply covers the existing editor. Style settings
and resets remain available as an explicit editor-menu action; selecting that
workspace intentionally is separate from opening the picker. This supersedes
the compact-preview behavior recorded below. No UI/build execution was performed.

Screenshot polish: the scrolling editor now explicitly bounds content to the
available width with 16pt side insets. Single-clip projects omit the redundant
clip strip/group title; Rename clip remains in the editor menu. Multiple clips
use compact horizontal thumbnail rows with bounded names, and UUID import names
display as Clip N in editor chrome without rewriting source labels. Main playback
uses one native scrubber and a compact transport row with minute/second readouts
(precise cue/timing controls remain unchanged). All four tools fit a normal-size
iPhone row; accessibility text uses horizontal scrolling. Export is a plain native
toolbar action. Source/diff checks only: screenshot/device/large-text acceptance
of this polish still needs user validation.

Responsive follow-up supersedes the numeric width guard and accessibility-only
horizontal tool strip above. The main page uses normal flexible vertical layout
and padding, with no screen-derived fixed width, added clipping or hidden controls.
Tool choices measure their content and fall back to a wrapping two-column grid.
Playback readouts/buttons and transcription status/actions stack when their full
horizontal layouts do not fit. Shared scope menus measure a bounded selected label
separately from their full menu options, preserving full names in VoiceOver. Existing
clip/word strips retain their intentional local horizontal scrolling. Source checks
only; no claim of device reproduction or verified responsive rendering is made.

## Source delivery

- [x] Styles opens a native medium/large sheet; an initially requested Style route
  from project details opens the same browser. Done/swipe dismiss without applying
  a browsed style; explicitly applied changes use normal autosaving.
- [x] One original animated landscape sample at a time; swipe, Previous/Next and
  VoiceOver adjustable navigation cover all ten existing catalog presets.
- [x] Sample text/timing is authored presentation data, isolated from user footage,
  recognition and the repository. It uses CaptionSnapshot/StyledCaptionOverlay and
  the real caption renderer. The silent backdrop is procedural animation, not a
  bundled stock MP4 or a decoded frame of the user's video. No model/download,
  network, additional player, catalog change or render/export code is introduced.
- [x] Only the displayed demo animates (capped at 30fps). Pause/resume, app inactive,
  view disappearance, an active Pro upsell and Reduce Motion suspend animation.
  Reduce Motion starts still; users can explicitly play the demo.
- [x] Use style calls EditorSession.setCaptionStyle, preserving placement, normal
  entitlement checks, immutable catalog versions, sparse overrides, history,
  snapshot regeneration and serialized saving. Browsing adds no undo/save entries.
- [x] Scope explicitly says Project defaults because existing clip overrides are
  retained. Named clip scopes and caption-only reset preserve media edits/names.
  Unknown/legacy/customized saved styles remain intact until an explicit action.
- [x] The medium browser temporarily replaces the scrolling workspace with one
  compact actual preview/transport and clip label, avoiding two real player layers.
  Sheet-background interaction allows playback/scrubbing; unrelated export/menu/
  Back actions are unavailable until the sheet closes. The full scrolling editor
  returns afterward. Customize remains the existing separate actual-preview sheet.
- [x] Footer remains accessible while content scrolls; large accessibility text
  starts at the large detent. Lock/checking/applied/save-error states are derived
  from actual session state. Missing real captions offer an explicit seek action.
- [x] iOS source discovery already includes new files through project.yml. No
  project regeneration/config/schema/purchases/models/Mac edits are needed.

## Validation and limits

Source/call-site/diff/whitespace review and remote base/blob/publication checks
only. No build, typecheck, test, fixture, UI/device/accessibility execution, native
render/export, CI, generation, model download or deployment was run. Compilation,
layout, gesture arbitration, player transitions, performance and output acceptance
remain unverified. Historical acceptance gaps remain in PRODUCTION_READINESS.md.

The inline concept's four labels were illustrative. Implementation uses the real
ten-style catalog, preserving each actual preset's typography and motion. The
medium sheet scrolls on small phones; expanding it provides more browsing space.
The underlying video is intentionally covered at the large detent/compact height.

## Required user acceptance — pending

### Reported CI failure and source fix

The user supplied bybydev/example run 40259897362, job 121369784720, which
archived head 3398911 with Xcode 26.3. The logged compiler errors both point to
CaptionStylesSheet.swift:144: SwiftUI Text has no accessibilityLiveRegion modifier,
and its .polite argument therefore has no contextual type. Removed that modifier;
the footer remains normal accessible Text reflecting the actual status. No other
compiler errors were present in the supplied job log. This is a source correction,
not evidence of a successful replacement archive. No rerun/build/test was started.

- [ ] Build exact PR head with supported Xcode/Swift 6 and regenerate locally as
  normal; confirm new sources and SwiftUI/Canvas/strict-concurrency compilation.
- [ ] SE2 + larger iPhone, portrait/landscape, light/dark/AF themes, larger text and
  VoiceOver: readable sample, visible/applicable footer, usable drag/scroll/detents.
- [ ] Browse all presets by swipe/buttons/VoiceOver. Verify no project revisions,
  undo entries, user-video extraction or styles change until Use style.
- [ ] Apply Basic/premium to defaults/Clip 2; undo/redo, caption-only reset,
  preserve placement/clip name/framing, inherited changes, save/reopen/relaunch.
- [ ] Free/checking/Pro/expired states; nested AF upsell, cancel/restore/purchase,
  then explicitly apply. No automatic purchase-triggered style changes.
- [ ] Play/pause/scrub real footage above medium browser; missing captions/trimmed
  clips; dismiss/reopen, customize/export/queue afterward; one player layer.
- [ ] Demo pause/resume, Reduce Motion, background/foreground, Pro upsell and rapid
  style changes. Compare every demo against its actual rendered preset.
- [ ] Slow/failed saves and Retry; caption edits during partial speech publication;
  actual preview/MP4/SRT parity remains governed by existing acceptance checks.
