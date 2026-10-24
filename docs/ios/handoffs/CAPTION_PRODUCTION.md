# Pass 5 handoff — caption quality and finish

2026-10-24 (Vietnam). All five source passes are integrated in PR #39 → develop,
open without auto-merge. Production verification is pending; no release-ready claim.

## Evidence

| Change | Source evidence | Execution status |
|---|---|---|
| Canonical schema 8, old appearance defaults, future-style protection | ProjectDocument + shared CaptionStyle codec + dedicated ProjectStoreError case; package future-schema guard remains | Schema 1–8 upgrade/rollback and disk execution unrun |
| Immutable 10-look catalog with per-preset versions and resolved values | InkribeCore/Captions; iOS aliases/browser/category/reset integration | Actual comparison/appearance not rendered or device-validated |
| Weight, shadow, backdrops, layout/fitting and emphasis/rise | Shared constraints/motion + CaptionRenderer; one path for live/MP4 | Native typography, geometry, speed and output parity unrun |
| Free/Pro/expiry and undo/autosave | Shared access/reset policy consumed by existing session; existing bounded history/journal and export freeze retained | Commerce, gesture grouping and disk races unrun |
| Privacy API reasons | iOS PrivacyInfo.xcprivacy, explicit resources membership in project.yml | Archive privacy report/App Store validation unrun |
| Regression specifications | CaptionStyleTests: 11 tests covering old decode, catalog round-trip/history, reset isolation, unknown/future style, access/expiry, mixed timing and constraints | Authored only; no tests/build/typecheck/fixtures executed |

No Xcode project was generated; no CI was configured/dispatched; no models,
imports, inference, native frames/exports, device/UI/accessibility or deployment ran.
Publication review compares changed blobs and preserves every unmodified remote blob.

## Compatibility review

New shared aliases keep existing JSON names/raw values. Extra fields default only
for legacy payloads; no native/raw caption identity or grouping changes. Opening
schema 1–7 preserves their stored version/appearance; edits use schema 8. Existing
package wrapper, recovery journal wrapper, allowance ledger, JobQueue legacy names,
IDs and frozen request wrapper remain unchanged. New style fields/identity stay
inside the existing optional captionStyle value, so history/recovery/duplicate and
export freezes carry them atomically. Undo restores the actual before/after values
without resolving current catalog defaults or rechecking access for retained work.

Future format errors propagate through ProjectPackageStore as a non-invalidDocument
error; they cannot trigger older-document fallback. Future document versions remain
rejected before decoding. Unknown catalog reference with supported fields remains
readable and never causes inference, reset or default lookup on load. Old apps cannot
read schema 8. Rollback requires a pre-upgrade stopped-app full-container backup.

Latest templates use format 2; historical Basic/four-template v1 definitions stay
frozen. Applying a current preset is explicit, preserves placement and records its
version. Unknown/untagged customized legacy styles stay untagged until an explicit
preset/reset operation. Independent reset targets are clearly named; unavailable
original reset uses explicitly named Basic rather than guessing ancestry.

Native Core Text supplies installed closest weights and fallback fonts. Arabic/bidi,
Vietnamese marks, CJK breaks, punctuation, ligatures and color emoji remain native
shaping. Legacy default weight does not request a different face. Old wrapping,
padding, eight-line limit and phrase-progress behavior stay frozen. New auto-fit is
bounded and never edits captions; errors are visible instead of text truncation.

## Pending focused validation

1. Build user-selected iOS configuration; run the unexecuted shared regression
   suite only after authorization. Compare old schema 1–7 projects and frozen jobs,
   missing/new fields, invalid/future format with a valid previous file, retired
   preset version and unknown ID. Verify no silent destructive fallback/write.
2. On iPhone SE2 and a larger iPhone, compare all ten looks on identical speaking
   footage. Exercise long/empty/hidden/multilingual/RTL/emoji captions, every canvas,
   trim inside a word/phrase, mixed precise/segment timing and actual gaps.
3. Check preview/MP4 for identical wrapping, effective size, frame time, shadow,
   per-line backgrounds, motion phase, baseline and placement; verify audio sync
   and SRT unchanged. Caption text/IDs/timing/grouping must never change on style.
4. Apply, customize, save/reopen, reset each section, adopt recommended placement,
   undo/redo, background/pop/cancel swipe, and recover failed saves. Slider gestures
   form one group; each preset/reset is discrete. System color-picker grouping and
   repeated open/close need native validation. Existing typing debounce remains.
5. Free/Pro/checking/expiry/restore: cards/controls/upsell, retained premium style,
   allowed free corrections/colors/size/position and Basic resets. Queue/export
   acceptance and already captured premium requests must survive expiry.
6. Rapidly filter/browse/scrub/cancel/relink/trim/crop, then open customization and
   return. Inspect frame cancellation, ten cached layouts, six-measurement fitting,
   memory/CPU, single player-layer ownership, keyboard, scroll anchors, VoiceOver,
   large text and themes. No sticky editor component should appear.
7. Repeat prior pass home/import/storage/queue/delivery scenarios, especially
   partial jobs publishing while editing, cancelled import preserving committed
   IDs, independent exports, pause/interruption, orphan output recovery, delivery
   leases, missing originals, low disk and conditional recovery-draft cleanup.

The full production verification matrix remains in issue #38. See
../PRODUCTION_READINESS.md for confirmed owner inputs and the validation record.
No pending scenario has been marked passed based on source inspection.

Consolidation follow-up: [current fixes and pending scenarios](../CONSOLIDATION.md).
The shared caption specifications now total 12, still unexecuted; format-2 extension
fields are required while legacy omissions retain defaults. Main covered layers and
current overlay-error reporting are tightened without changing saved style values.
