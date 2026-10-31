# Inkribe iOS — current working agreement

2026-10-31. The user authorizes music pass 3 in existing PR #54, extending 73a2323c.
Complete the source integration review and scoped defects without changing the
approved design. All three source passes are delivered; no runtime validation is
implied. Existing no-build/no-test/no-typecheck/no-CI/no-native/UI execution rules
remain. Leave the PR open without auto-merge; no automatic next feature/release.

2026-10-31. The user's "next pass" authorizes pass 2 in existing PR #54, extending
b345f71c. Implement only MUSIC.TIMELINE / MUSIC.SHEET and their required local-draft
publication adapter. Keep the settled CapCut-inspired order/leading button styles,
existing editor design and preview-free Music sheet. Pass 3 awaits the next signal.
Existing source-only restrictions and open/no-auto-merge requirement remain.

2026-10-31. The user explicitly starts pass 1 of the agreed three-pass music PR,
feat/ios-music-layer -> develop, from 723f333. Apply phases/MUSIC_LAYER.md and its
handoff. Pass 1 is source/data/media integration only; all editor layout and visible
controls stay as on develop. Next passes await the user's signal, and unrelated
design changes require approval. Keep the PR open without auto-merge. Existing
source-only/no-build/no-test/no-CI/no-native-execution restrictions remain.

2026-10-29. The user explicitly authorizes the discussed native fullscreen changes
in a new stacked PR from #52 head 3f9b8107, targeting feat/ios-style-sheet-grid.
Apply phases/NATIVE_FULLSCREEN.md and handoffs/NATIVE_FULLSCREEN.md. Preserve the
parent branch and leave both PRs open without auto-merge. No builds/tests/typechecks,
CI, generation, native playback/export or UI/device execution. Discussion of another
problem/preference is not authorization; wait for an explicit implementation command.

2026-10-29. The user authorizes implementing the latest native Style-form mockup
in existing PR #52. The confirmed plan replaces project footage/transport with
the template's live-rendered sample, groups appearance into native form rows,
uses pushed pickers/details without previews, and removes clip caption scopes.
Caption placement stays in Style under Layout with preset/inline coordinate
controls and live sample feedback; media scopes remain separate. Done saves
project-wide appearance and placement atomically; Cancel discards both.
Existing frozen exports retain recorded behavior; new exports match the project's
single style. See phases/STYLE_SHEET.md and handoffs/STYLE_SHEET.md. Source-only
restrictions and open/no-auto-merge requirements remain. Earlier #52 UI below is
superseded where it conflicts with this latest approved design.

2026-10-29. The latest request approves implementing the revised unified Style
sheet in a new PR from develop b28beebb, targeting develop. The concrete UI is
already approved: actual preview, selected-template row pushing a lazy grid,
inline customization, top-left Cancel and top-right Done. Its local caption-only
transaction supersedes immediate style autosaving while the sheet is open. Done
saves before adopting; Cancel and dismissal never publish the draft. Preserve the
existing caption/project/preview/Pro/export contracts. See phases/STYLE_SHEET.md
and handoffs/STYLE_SHEET.md. All source-only restrictions and open/no-auto-merge
requirements remain. Prior phase statuses below are historical for this scope.

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

