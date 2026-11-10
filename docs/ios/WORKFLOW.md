# Inkribe iOS — current working agreement

2026-11-01. The user's next-pass signal authorizes final queue integration in
PR #57 from 2923c08b. Apply QUEUE_EXPERIENCE phase/handoff: source-review all four
passes, fix supported scoped defects and leave design/behavior outside this PR
unchanged. Source fixes cover stable scene observation/real-background recovery,
export inventory/focus handoff and stale project routes; ownership comments/helpers
are consolidated. All four source passes are complete without runtime acceptance.
Existing no-build/no-test/no-typecheck/no-CI/no-generation/no-native/UI execution
restrictions remain; keep open without auto-merge. No automatic new scope or release.

2026-11-01. The user's next-pass signal authorizes queue experience pass 3 in
PR #57 from 7d4b06fd. Implement JOB.BACKGROUND and necessary source configuration,
resource eligibility, interruption and truthful status copy. See the phase/handoff
QUEUE_EXPERIENCE under docs/ios. Use user-initiated continued-processing requests,
per-kind grants and GPU-supported video background work/foreground fallback; retain
JobQueue 1/3 capacity and all pass-1/2 behavior. Launch/foreground recovery must not
submit new continued tasks. This permits iOS background-mode/GPU-entitlement source
edits only, not project/plist generation, signing, deployment, native/UI execution,
CI or builds/typechecks/tests/fixtures. No automatic next pass; leave open.

2026-11-01. The user's next-pass signal authorizes queue experience pass 2 in
PR #57 from faa33e8c, retaining pass 1. Implement the settled Spokio-reference queue
presentation and project-tool routes only, including necessary presentation-owner
handoffs and exact export focusing/retained-request visibility. See
handoffs/QUEUE_EXPERIENCE.md. All other editor design,
processing policy, persistence/contracts and shared/Mac behavior remain. Background
continuation is still pass 3; final review is pass 4. Source-only restrictions
remain; keep open without auto-merge and await each next signal.

2026-11-01. The user authorizes only pass 1 of the four-pass queue experience
in one new feat/ios-queue-experience PR targeting develop from b51e1b95. See
handoffs/QUEUE_EXPERIENCE.md. Implement one queued
Transcribe/Create Export path and JobQueue 1-transcription/3-export capacity, removing
iOS global serialization while retaining cancellation/teardown. Preserve current
editor design and foreground-only lifecycle. Each next pass requires a separate
signal; keep the PR open without auto-merge. Existing source-only restrictions
remain. Earlier two-export-action/single-heavy-operation requirements are superseded.

2026-10-31. The user authorizes timeline-only per-clip trimming in a stacked PR
on #55 at 381b0d2b. Apply handoffs/CLIP_TRIMMING.md.
Target feat/ios-media-form, keep both PRs open without auto-merge and do not alter
the parent. The request authorizes the agreed handles/main preview/ripple timing,
Media trim removal and necessary schema/persistence/output integration. Source-only
restrictions remain: no builds/typechecks/tests/fixtures, CI, generation/models,
native processing/exports or UI/device execution. No unrelated design or features.

2026-10-31. The user's next-pass signal authorizes Media Form pass 2 in existing
PR #55, extending bb0d1b11. Apply handoffs/MEDIA_FORM.md.
Complete the source review and scoped fixes only; keep the approved Form/design.
Both source passes are delivered without runtime validation. No builds/typechecks/
tests/fixtures, CI, generation, native media/exports or UI/device execution.
Keep open without auto-merge; no automatic next feature or merge.

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
feat/ios-music-layer -> develop, from 723f333. Apply handoffs/MUSIC_LAYER.md (its
approved-scope brief is archived inside). Pass 1 is source/data/media integration only; all editor layout and visible
controls stay as on develop. Next passes await the user's signal, and unrelated
design changes require approval. Keep the PR open without auto-merge. Existing
source-only/no-build/no-test/no-CI/no-native-execution restrictions remain.

2026-10-29. The user explicitly authorizes the discussed native fullscreen changes
in a new stacked PR from #52 head 3f9b8107, targeting feat/ios-style-sheet-grid.
Apply handoffs/NATIVE_FULLSCREEN.md. Preserve the
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
single style. See handoffs/STYLE_SHEET.md. Source-only
restrictions and open/no-auto-merge requirements remain. Earlier #52 UI below is
superseded where it conflicts with this latest approved design.

2026-10-29. The latest request approves implementing the revised unified Style
sheet in a new PR from develop b28beebb, targeting develop. The concrete UI is
already approved: actual preview, selected-template row pushing a lazy grid,
inline customization, top-left Cancel and top-right Done. Its local caption-only
transaction supersedes immediate style autosaving while the sheet is open. Done
saves before adopting; Cancel and dismissal never publish the draft. Preserve the
existing caption/project/preview/Pro/export contracts. See handoffs/STYLE_SHEET.md. All source-only restrictions and open/no-auto-merge
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

Read root AGENTS.md, [scope](handoffs/PREVIEW_HANDOFF.md),
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
