# Inkribe iOS design handoff

## Reference

![Inkribe for iOS — key screens and user flow](assets/main-screens-reference.jpeg)

User-supplied source: `EFF3F314-2413-4A2E-8BFC-846F644A9A78.jpeg`, copied unchanged into this repo as `assets/main-screens-reference.jpeg`. It illustrates 12 selected screens, not every feature, loading state or accessibility layout.

Retain dark surfaces, restrained purple/blue accents, prominent footage, clear thumbnails and expressive caption previews. Keep dark/light support. Exact colors, spacing, fonts and final icon are not approved design tokens; choose concrete accessible values when the relevant UI is reviewed. Do not replace the existing Mac icon/branding with the concept's decorative logo.

A wholesale image redesign is unnecessary. The decisions below override conflicting image details.

## Screen flow and responsibilities

| Screen in image | Intended behavior / refinement | Owner |
|---|---|---|
| 1 Launch | Welcome/create is onboarding or empty-library state. Normal launch goes to Projects. | P1 |
| 2 Projects | Search/filter, thumbnails, recent projects and a clear create/import action. Preserve project identities across navigation. | P1; advanced organization P12 |
| 3 Import | Photos/Files/direct-media sources with a clear selection/review step; durable adoption and cancellation. Camera routes to P9 capture when available. | P1/P9 |
| 4 Transcribing | Actual processing stages/progress with cancellation/retry. Show speaker detection only when enabled/executed; do not invent elapsed-time estimates. | P2 |
| 5 Editor | Footage preview, transport, timeline/selected tracks and one coherent tool entry hierarchy. Additional tracks/advanced tools appear contextually. | P3/P6 |
| 6 Caption editing | Keep compact footage preview above text/cue list. Selected cue/word, playback and playhead remain synchronized, including keyboard-open layout. | P3 |
| 7 Style/animation | Related controls under the agreed caption tool hierarchy. Clear target scope: project default, selected cues or individual word. | P4 |
| 8 Templates | Complete designs distinct from individual font/color/animation properties. Preview with current project footage and persist editable configuration. | P10 |
| 9 Audio | Contextual tracks, large touch areas, precise value entry and expandable advanced controls. | P6 |
| 10 Export | Explicit caption mode and separate subtitle-file outputs. Show profile compatibility, actual progress/errors and cancellation. | P5 |
| 11 Share | Native iOS share sheet for files; Save to Photos/Files as appropriate. Dedicated publish UI only for implemented official integrations. | P5/P11 |
| 12 Settings | AppFoundation appearance/commerce foundations; model/storage/export settings owned by Inkribe. Autosave is reliable default behavior. | P1/P5/P12 |

## Six implementation decisions

1. **Normal launch is Projects.** Do not add an unnecessary welcome-screen step for returning users.
2. **Keep video context during caption correction.** Compact preview remains present above the editable list; plan selection, playback and keyboard interaction together.
3. **One editor tool hierarchy.** Avoid two competing bars that both contain Captions/Style/Edit with overlapping responsibilities. Settle concrete grouping and transitions before P3 UI implementation.
4. **Design for small supported iPhones.** Readable labels and comfortable hit areas; prioritize preview/current operation; reveal tracks and advanced properties contextually. Advanced features stay in scope.
5. **Unambiguous export modes.** Video without captions, burned-in captions or embedded subtitle track where supported, plus independent SRT/VTT/etc. file choices. Explain format/styling limitations.
6. **Native sharing.** Social logos must not promise unimplemented direct posting. P11 retains publishing via verified official capabilities.

## Layout contracts to settle in P3

Review a compact and expanded editor layout, timeline/list transitions, tool selection, multi-selection, text keyboard, numeric timing editor, undo, loading/error states and project switching. Define visible preview behavior when entering style/template/audio panels.

For caption list correction: selecting a cue/word seeks or updates the relevant preview according to an explicit interaction rule; playback highlights must not steal typing focus or rewrite text. Changing panels does not reinitialize the project/player. Editing text does not implicitly remove media.

For small-height screens: preserve usable preview and focused controls, allow panels to scroll, and avoid simultaneous tiny stacked tracks. Numeric values supplement gestures/sliders for precise work. iPad/keyboard/external-display features remain in inventory; choose adaptive layout rather than enlarging a cramped phone canvas.

## Rendering and typography

Use project/output coordinates rather than screen pixel positions for saved placement. Safe-area guides are overlays, not exported graphics unless explicitly chosen. Resolve multiline text, fonts, RTL/CJK and Unicode graphemes through the shared render/layout contract. SwiftUI-only motion that cannot be reproduced in export is not a completed caption effect.

Prefer readable defaults and reduced-motion/high-contrast alternatives. User-selected expressive styles do not remove VoiceOver/Dynamic Type obligations for the surrounding controls. Determine exact measurements/contrast during UI implementation; no device validation is authorized here.

## Design approval by phase

- P0 can proceed on target/domain feasibility after implementation authorization without redrawing every screen. Any prototype UI still follows existing approval instructions.
- P1 refines Projects, onboarding/empty and import flows before their UI changes.
- P3 settles the editor structure before its UI changes.
- P4–P11 refine each affected panel/workflow against the approved editor structure before implementation.
- Present a concise plan or relevant mockup and ask for approval where required by the user's UI working preference. A phase request does not authorize manual UI tests.

Unspecified screens such as queue management, detailed timing, translation review, paywall/upsell, brands and team comments require their own phase-local layouts. Do not omit them because the reference has only 12 screens.
