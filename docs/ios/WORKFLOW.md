# Inkribe iOS — current working agreement

2026-10-28. The user confirmed the concrete Graphite plan in existing PR #50:
Free dark theme after Paper, #279ED2 accent. The confirmed visual revision adds
Midnight's translucent panels, subtle shadows and layered charcoal/blue lighting;
Paper remains default and other themes remain Pro. See
[handoff](handoffs/GRAPHITE_THEME.md). Source-only checks and the requirement to
confirm future edit plans remain. Keep #50 open without auto-merge. PR #51 is
already squash merged into #50 at the user's request; its open-PR rule below is
historical.

2026-10-28. The latest user request confirms the preview handoff fix in a new stacked
PR from #50 head `5c9f9eb`, branch fix/ios-preview-handoff, targeting
feat/ios-contextual-caption-editor. Keep both PRs open without auto-merge.
Other edits require a concrete plan and the user's confirmation first. All parent
caption, project and output contracts remain protected.

Read root AGENTS.md, [scope](phases/PREVIEW_HANDOFF.md),
[marked handoff](handoffs/PREVIEW_HANDOFF.md), README, PLAN, FEATURES, ARCHITECTURE,
DESIGN and HANDOFF. Current sheet/navigation contracts supersede older overview
and clip-strip descriptions. Historical handoffs remain evidence, not new scope.

Preserve direct editor/opening cancellation, fixed preview, native IDs/source
anchors, partial captions/edits, clip settings/history, atomic saving, accepted
coverage/allowance, shared active speech engine/model, frozen outputs and Mac.
Only toolbar Export presents ExportView; Queue retains independent file delivery.

No builds/typechecks/tests/fixtures, CI setup/triggers/runs, generation, model
downloads, native inference/exports, UI/device/accessibility execution or deployment.
Use source/call-site/diff/whitespace/publication consistency review only. User
validates afterward. Finish with an honest source checklist, not runtime claims.

XcodeGen owns project.yml; do not edit generated projects. iOS remains Inkribe/,
target Inkribe, iPhone only. No dependency/model/purchase/icon changes or separate
draft/recovery workflow. Do not automatically start new scope or merge/release.

This checkout is a partial review snapshot with synthetic local git history.
Publish only changed blobs/deletions onto the full verified remote PR head tree;
never push this snapshot’s root tree/history. Verify expected-base blob hashes,
unchanged remote files, branch-head lease and final PR base/head/open/no-auto-merge.
