# Inkribe iOS — current working agreement

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
