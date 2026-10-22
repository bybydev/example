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
