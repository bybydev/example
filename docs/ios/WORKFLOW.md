# Inkribe iOS — current working agreement

2026-10-27 — Issue #47, timeline editor **passes 1–3 source-integrated** in
PR #48, `feat/ios-timeline-editor` → develop. Pass 3 extends head `95628a7`.
The fixed editor includes real multi-clip frame/caption tracks, ruler, center
playhead, scrubbing/playback, anchored zoom, selection and caption move/resize.
Drag a selected block or its edge handles; hold any block to select/move it.
A temporary block/readout and frame audition precede one validated undoable commit
on release. Cancel/interruption does not publish the proposed timing. Existing
native intervals stay immutable; moved words translate and resized words scale.
Sheets, preview geometry, cancellable opening, cache/queue/Pro contracts remain.
See [scope](phases/TIMELINE_EDITOR.md) and [source handoff](handoffs/TIMELINE_EDITOR.md).
Keep PR #48 open without auto-merge. Source review only; compilation and native
acceptance are unverified. Existing no-build/test/CI/UI/device restrictions remain.


2026-10-26 update: current work is **Add missing caption**, branch
`feat/ios-manual-captions` → develop, based on f0eb80c (merged #43).
See [scope](phases/MANUAL_CAPTIONS.md) and [marked handoff](handoffs/MANUAL_CAPTIONS.md).
Manual phrases are separate project data; schema 10 reads 1–9. Native recognition,
working styles, Mac behavior and existing wrappers are preserved. Source-only
review; compilation/device/output acceptance pending. Keep the new PR open with
no auto-merge. Earlier current-phase entries below describe completed history.


2026-10-26 update: current work is the approved animated Styles sheet in
`feat/ios-animated-style-sheet` → develop, based on 81b8207 (merged #42).
See [source checklist and pending acceptance](handoffs/ANIMATED_STYLES.md).
Keep the PR open. Source-only checks; all existing execution restrictions remain.
Earlier phase descriptions below are completed history.

2026-10-24. Latest user instructions and root AGENTS.md control authorization.
Current work is all of expanded Pass 1 (#41, parent #40), one new PR from latest
develop 4a9780f on feat/ios-pass1-project-experience targeting develop.
Older PR #39 source/merge holds and #41's planning-only wording are superseded.

Read README, PLAN, FEATURES, HANDOFF, ARCHITECTURE, DESIGN and
[PROJECT_EXPERIENCE](phases/PROJECT_EXPERIENCE.md) plus its detailed handoff.
The latest implementation request authorizes the discussed UI and routine details.
Preserve transcription, native IDs/timing, partial captions, corrections/undo,
allowance, originals, independent outputs and current Mac identity/configuration.

No builds/typechecks/tests/fixtures, CI setup/triggers/runs, Xcode generation, model
downloads, native inference/exports, UI/device/accessibility execution or deployment.
User validates afterward. Regression source may be authored but not executed.
Use source/call-site/diff/whitespace and publication consistency review only.

Keep the PR open without auto-merge. No release or automatic next parent pass.
Finish with marked todo status distinguishing source work, execution and acceptance.
Do not provision signing/store/website resources or invent policy URLs.

XcodeGen owns project.yml; do not edit generated projects. iOS remains Inkribe/,
target Inkribe, iPhone only. Mac remains InkribeMac/. Existing icon, dependency,
model and purchase ownership stay unchanged. No separate draft/recovery workflow.

This checkout is a partial review snapshot with synthetic local git history.
Publish only changed blobs onto the full verified remote base tree. Never push
this snapshot's root tree/history. Verify unchanged remote blobs, changed hashes,
expected-head lease and final PR base/head/state. A future real clone should check
its own history before applying this snapshot-specific procedure.
