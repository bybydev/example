# Issue #38 — production pass 5: caption quality and finish

2026-10-24 (Vietnam). Existing PR #39 → develop, retaining passes 1–4. Existing
V1 IDs: STYLE, PRESETS, TEXT, TIMING, UNDO, MEDIA, ACCESS, PRO, MP4, SRT, RECOVERY,
AUTOSAVE, BOUNDS, HANDOFF. Source implementation is authorized; runtime validation,
builds/tests/fixtures/CI, generation, downloads, exports and device checks remain
restricted. Leave open without auto-merge.

## Resolved style and compatibility

ProjectSchema becomes 8 and reads 1–7. Opening old projects does not rewrite them;
normal accepted edits write the current schema. Package wrapper remains 1, export
request wrapper remains 1, and JobQueue names/files/IDs/payloads, checkpoint mapping,
raw/native timestamps, recognition grouping and allowance are unchanged. Older apps
reject schema 8. Do not downgrade edited files; use a stopped-app container backup
from before upgrade for rollback. Mac Transcript/source/configuration is preserved.

InkribeCore owns portable CaptionStyle/CaptionColor/font/effect values, versioned
CaptionPreset definitions, resets/access policy, layout constraints and deterministic
motion. iOS consumes aliases and adapts actual recognition into timed units. Native
Core Text font matching, glyph shaping/layout and CGContext/video rendering remain
in the app; both live preview and frozen MP4 call the same renderer. A future Mac
adapter can consume these values; Mac parity is not established by moving types.

Style format 1 preserves legacy defaults/strict layout and legacy motion. New fields
missing from old JSON decode to the original appearance. Legacy required fields
remain required. Consolidation requires every resolved nonoptional extension field
for format 2; missing/null values must not silently default. Format 2 enables weight/tracking, line layout/fitting, configurable
backdrops/shadow and phrase-aware motion. Unsupported future format is detected
before unknown fields and throws a dedicated non-corruption error: no silent
prior-valid fallback over future style data. Any future incompatible document/style
wire change must also bump canonical schema so older readers reject it up front.

Saved style values are always authoritative. A bounded optional preset reference
(id, version) records ancestry; opening never substitutes catalog defaults. Definitions
are immutable by pair. New defaults add a new version while retaining historical
ones. Unknown preset identity with supported resolved fields stays readable/customized;
its unavailable reset definition is not invented. Untagged legacy value matching is
a visual hint, never automatic persisted ancestry. Existing four template definitions
and Basic version 1 remain available; latest four templates use version 2. New named
looks start at version 1. Catalog release number is 2.

## Curated collection

| Look | Direction | Typography / layout / treatment | Motion / recommended Y |
|---|---|---|---|
| Basic | Essential | Modern, centered, quiet caption box; legacy geometry | None / 82% |
| Spotlight | Creator | Bold, open frame, active-unit highlight | Highlight / 82% |
| Karaoke | Creator | Bold mint emphasis; word sweep only on timed words | Karaoke or whole-phrase color / 82% |
| Pop | Expressive creator | Larger modern pink, strong outline, no box | Timed pulse / 82% |
| Soft Fade | Cinematic | Serif, subtle box, reduced size and no outline | Fade / 82% |
| Punch | Creator | Heavy condensed, two lines, narrow spacing, strong outline | Pulse / 70% |
| Podcast | Podcast | Rounded, three lines, separate dark line pills | Active-unit color / 82% |
| Cinema | Cinematic | Regular serif, narrow open layout, soft text shadow | Fade / 87% |
| Classroom | Education | Leading mono, four lines, warm paper box and blue underline | Underline / 22% |
| Editorial | Editorial | Leading bold, three lines, generous spacing and soft shadow | Rise / 35% |

The new looks differ in typography/layout/background/emphasis and motion, not only
color. Applying a look keeps the user's placement. Applying its recommended
placement is separate and undoable. Stored reference/version drives named resets;
customization/placement states remain explicit after reopening. Typography, colors,
backdrop/shadow, layout, placement and motion reset independently. Full Basic reset
restores the complete Basic resolved style. All are ordinary history/autosave edits.

## Rendering and bounds

- OS-supplied fonts only; no redistributed font binaries. Missing named faces use
  the system fallback. Explicit weight matches the installed family/closest available
  face; script/emoji cascades remain native Core Text. Exact appearance across OS
  versions/scripts is not promised. Vietnamese/RTL/emoji acceptance is pending.
- Wrap/shrink are visual only. Canonical text, IDs, cues and word/phrase intervals
  stay unchanged. Core Text handles clusters, punctuation and bidi; leading/trailing
  uses native run direction. User newlines remain part of the edited text.
- Keep at most 8 lines and 16,384 UTF-16 units per rendered cue. Optional fitting
  measures requested size, a readable floor, then four refinements (six maximum).
  Floor is max(2.5% of short canvas edge, chosen size × minimum scale). Failure
  stays an explicit reduce-size/more-lines/split error; no silent truncation.
- Outline, shadow/motion extents, background padding and maximum pulse scale
  participate in bounds. Per-line boxes avoid overlapping padding. Placement is
  clamped inside output bounds consistently for preview/export.
- Format-2 karaoke sweeps approximate word-timed token unions only. Segment/unknown
  timing uses whole-unit active color. Mixed units retain their own treatment;
  no evenly spaced word boundaries are generated. Format-1 phrase progress remains
  for legacy appearance, with an honest explanatory label. Fade/rise/pulse use
  original edited intervals, including trim into an already-active unit.
- Browser compares at most ten styled snapshots/layouts sharing one asynchronous
  media-only 480px frame; no per-card decoder/player. Existing scene/pause/debounce/
  cancellation/graph invalidation guards remain. Motion uses the real player.

## Access and integration

Keep existing free color/size/position/outline/background editing and reset policy.
New font/weight/tracking/layout/shadow capabilities use the shared access predicate;
retaining a premium value or resetting to Basic remains possible after expiry.
No new products, quota rules, charge path, inference or media graph is introduced.
Frozen export manifests carry the full style and reference with document revision;
workers never consult catalog defaults. SRT remains canonical text/timing only.

See handoff/CAPTION_PRODUCTION and PRODUCTION_READINESS for source evidence,
regression sources, pending user scenarios, metadata/privacy and owner inputs.
