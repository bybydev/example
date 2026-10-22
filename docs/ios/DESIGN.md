# Inkribe iOS v1 design

![Visual reference](assets/main-screens-reference.jpeg)

Reference supplies dark surfaces, restrained purple/blue accents, strong footage previews, thumbnails and caption styling. It does not authorize every pictured control; PLAN/FEATURES overrides it. Preserve Mac branding.

| Surface | V1 behavior | Phase |
|---|---|---|
| Projects | Normal launch, empty-state Add, thumbnails, rename/duplicate/delete | P1 |
| Import | Photos/Files video/audio; loading/cancel/errors | P1 |
| Transcribing | Local language choice, real stages/progress/cancel/retry | P2 |
| Editor | Compact footage above caption list, simple timeline, timing/text edits, undo | P3 |
| Styles/templates | Fonts/size/color/outline/background/position and curated four effects | P4 |
| Export | MP4 720p/1080p or SRT, Save/Share | P5 |
| Media tools | Trim, crop/ratio, original-audio volume | P6 |
| Settings/Pro | Necessary model/storage controls and AppFoundation paywall/restore | Owning phase |

One coherent tool hierarchy. Preserve footage context during typing and selection/playback across panels. Readable controls fit small supported iPhones; scroll focused panels instead of tiny stacked tracks. Output-coordinate placement and shared typography/motion in preview/export. Respect accessibility and surrounding UI text-size/reduced-motion needs.

No camera, cloud, translation, team, publishing or advanced editor screens. No iPad-specific workspace/external-display feature work; existing target settings are not changed here. New UI needs a short plan/approval. Routine P1 already approved. This docs change removes no existing UI.

## P3 implemented layout

The user requested P3 after P2 merge; the short plan stated compact preview above transport, simple timeline and correction/list panels. Footage remains visible during typing (reduced height), and focused controls scroll. Caption text is corrected per timed unit with optional phrase replacement; selecting the word exposes its timing and split boundary. Cue/word numeric timing lives in disclosure panels. Undo/redo and project actions are in the toolbar; project title/original-media/relink controls remain under a disclosure. Playback highlights the active list cue; selecting a cue pauses/seeks and returns to correction controls. No camera/audio suite or other reference-only controls added. UI/keyboard/accessibility behavior still needs user validation.

## P4 implemented layout

The user requested this phase after P3 merge. The stated plan adds Captions/Style/Templates tool tabs below the stable footage/transport/timeline. Style scrolls fonts, size, text color, one effect picker and highlight color, with outline/background and position disclosures. Top/Center/Bottom actions complement horizontal/vertical placement sliders. Templates are four compact choices with the current look marked; applying one updates current-footage preview and preserves chosen placement. No template auto-plays media. Styling/reset/template changes are undoable and saved automatically.

Font labels are Modern (Avenir Next Demi Bold), Bold (Helvetica Neue Bold), Serif (Georgia Bold) and Mono (Menlo Bold), with explicit installed-script/emoji/system fallback. Presets are Spotlight (yellow active-word background), Karaoke (mint progressive fill), Pop (pink word-triggered pulse) and Soft Fade (serif fade). All properties remain editable. No custom font import, brand kit, marketplace, AI styling or extra effect catalog. Preview uses the same Core Text layout/effect renderer as the bitmap/composition adapter; surrounding UI respects Dynamic Type/VoiceOver/Reduce Motion. Device UI/font/shaping validation is still pending.

## P5 implemented layout

The current P5 request and stated short plan cover an Export sheet from the editor and a Current export toolbar shortcut in Projects. Choose captioned MP4 or edited SRT; MP4 offers 720p/1080p with actual dimensions displayed. Show progress, cancel, retry, clear errors and completed-file Save to Photos/Files/share actions. Photos is MP4-only; SRT uses Files/share. A current-job shortcut keeps delivery/discard accessible after project deletion. Export work can continue with the sheet closed while the app remains active. Starting another export explicitly replaces the one local artifact; the text explains saving it first. Discard affects only export files/pins, not the project. Storage shows current-export usage.

Native document picker and share sheet retain file access until their callbacks/dismissal; Photos retains it through authorization/write completion. Permission denial offers Files rather than prompting for library read access. The user selected Defer Pro, so no paywall, invented limits or pricing are added. UI/VoiceOver/small-screen/provider behavior remains unverified; no UI tests executed.

## P6 implemented layout

The user requested P6 after merging P5. The stated Media panel adds whole-project trim start/end fields with Apply/Reset, exact retained output length, Original video/9:16/1:1/16:9 aspect choices, Fit/Fill crop, zoom/horizontal/vertical position, crop reset, original-audio volume and volume reset. Media is available before transcription; caption-only tools appear after recognition. Shared focus reduces the footage preview and hides the overview while entering trim numbers, using the existing keyboard Done action. No new timeline tracks, gestures/keyframes or production suite.

Trim fields use original project seconds; transport/list/export start at zero for the retained range. Caption timing correction disclosures explicitly retain original project seconds after trim so adjusting a boundary unit does not silently delete its hidden source-side timing. Text/list rows show only retained units; no captions inside the range gets a clear reset/adjust hint. Applying trim or framing pauses/rebuilds preview while preserving the original source playhead; volume changes can be heard during playback. Captions keep output-canvas placement when footage is cropped. Values are undoable/autosaved; unsubmitted trim fields require Apply. User layout/keyboard/VoiceOver/pixel/audio validation remains unrun.
