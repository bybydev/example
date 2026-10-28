# Inkribe Working Rules

## Current edge-to-edge timeline authorization

2026-10-28. The user confirmed removing the editor timeline's inherited 12-point
side gutters in PR #50. Move horizontal padding to preview, playback controls,
timeline header, errors and caption prompts so the ruler/tracks span the editor
width. Preserve centered-playhead start/end scroll space, scrub/pinch/timing
gestures, thumbnail/caption geometry and preview dimensions. Layout only; retain
all caption, Graphite and preview-handoff work. Source-only checks; no builds,
typechecks/tests/fixtures, CI, generation or UI/device execution. Keep #50 open
without auto-merge; future edits still require a confirmed concrete plan.

## Current Graphite theme authorization

2026-10-28. The user confirmed adding Graphite in existing PR #50, targeting
develop. Graphite is Free, always dark, immediately after Paper, with accent
#279ED2. The user subsequently confirmed revising the flat design to Midnight's
translucent surface/elevated/border tokens, subtle shadows and layered background
with restrained blue lighting. Keep the charcoal base and blue accent; remove
the special flat-background adapter and reuse AppThemeBackground for all themes.
Paper remains the default/fallback; existing premium themes retain their palettes
and Pro access. Keep theme persistence, picker and access in AppFoundation 1.6.4;
the Graphite palette is iOS app-owned. Update the
Free comparison to Paper and Graphite. No shared-package, Mac, icon, schema,
editor/playback or purchase-product changes. Source-only checks; no builds,
typechecks/tests/fixtures, CI, generation or UI/device execution. Keep #50 open
without auto-merge. Other edits still require a concrete plan and confirmation.
PR #51's preview fix was user-validated and squash merged into #50 as 35b29af.
Earlier instructions to leave #51 open and Paper as the sole Free theme are
superseded. See docs/ios/handoffs/GRAPHITE_THEME.md.

## Current preview handoff authorization

2026-10-28. The user confirms the proposed fix for the covered editor turning black
when sheets open, in a new stacked PR. Branch fix/ios-preview-handoff starts at
PR #50 head 5c9f9eb and targets feat/ios-contextual-caption-editor, not develop.
Preserve a current frame before transferring the one shared player's live layer;
keep covered previews mounted with a still and matching caption clock/snapshot,
then reveal returning live video only when its layer is ready. Preserve all #50
row selection/seek/top-left Edit caption, native push/pop, Captions preview/controls,
highlight-without-auto-scroll, styles, timing/history/saving and independent exports.
No extra player, asset reload/decode pipeline, schema, renderer implementation,
speech, queue/commerce/model/Mac or CI changes. Source-only checks; no builds,
typechecks/tests/fixtures, generation/models, native processing/exports, CI or
UI/device execution. Leave both PRs open without auto-merge. Read PREVIEW_HANDOFF
under docs/ios/phases and handoffs. This request confirms only the discussed fix;
other edit plans still require the user's confirmation before implementation.

## Current contextual caption editor authorization

2026-10-28. The user authorizes only replacing the top-level Timing tool with a
contextual Edit caption editor in one new PR from latest develop, targeting develop.
Second tap on a selected timeline caption or the selected transcript row's top-left
Edit caption button opens the same editing content. Keep caption/word correction, split/
merge, exact timing, manual deletion, existing history and automatic saving. The
contextual editor has no player, scrubber or transport. The latest correction
requires a native push from Captions; Back/swipe-back/Done returns to the same list
and scroll context, without another sheet. Timeline entry remains a sheet whose
Done/dismissal returns paused just before the edited caption with selection retained.
The latest user correction also gives Captions a video preview above its list,
play/pause and Undo/Redo, with no scrubber/timeline. Always highlight the current
playback cue without selecting it or auto-scrolling. Remove the optional follow
toggle; retain manual list scrolling and contextual push/pop. Reuse the sole player
and existing renderer, handing off its visible layer across sheets/navigation.
The latest confirmed row plan preserves tap-to-select/highlight/seek. The list has
no inline text editing or Split / Words button. Only the selected row's existing
top-left Edit caption button pushes editing; text/words/split/merge/timing/manual
deletion stay in that editor. Before future edit work, explain the concrete plan
and wait for the user's confirmation. This request confirms only this row change.
Keep all other consolidation proposals deferred until the user's next signal.
No schema, native timing/IDs, renderer, speech, queue/export, commerce, model, Mac or
CI changes. Source-only checks; no builds/typechecks/tests/fixtures, generation,
native processing/exports, CI runs or UI/device execution. Leave the new PR open
with auto-merge disabled. Read phases/CONTEXTUAL_CAPTION_EDITOR.md and its handoff.
Earlier implementation authorizations below are historical where superseded.

## Current direct editor and sheets authorization

2026-10-28. The user requests **pass 3** in existing PR #49,
feat/ios-editor-sheets → develop, extending pass-2 head 014ad963. Complete native
clip drag reorder and source consolidation while preserving passes 1–2. Reorder
is local in the large Clips sheet until Save, with Cancel, stable IDs, expected
state, one durable undoable commit and no-op rejection. Project trim remains a
window at its current clock positions; reordered footage inside it can change.
Keep native source intervals/raw IDs, manual/native captions, clip names/settings,
accepted coverage/retry/allowance, preview/media/audio/SRT order, selection and
original files aligned. Do not automatically transcribe or affect frozen exports.
Retain direct editor/opening cancellation, Project info/storage, numbered timeline,
plain ellipsis and toolbar-only Export sheet/history. Remove unused clip-strip UI;
background export artwork must retain deletion leases without blocking dismissal.
Schema stays 11 (reads 1–10); no shared-package/Mac/native renderer/engine/commerce/
model-policy/CI changes. Active project transcription still excludes final graph
transactions. Read docs/ios/phases/EDITOR_SHEETS.md and handoffs/EDITOR_SHEETS.md.
Source-only: no builds/typechecks/tests/fixtures, CI, generation/models, native
processing/exports, UI/device/accessibility execution or deployment. Keep PR #49
open without auto-merge; implementation completion is not runtime acceptance.

## Current timeline editor authorization

2026-10-27. The user requests **pass 3** of issue #47 in existing PR #48,
`feat/ios-timeline-editor` → develop, extending pass-2 head `95628a7`.
Implement caption block move/edge-resize, explicit word timing rules, one undoable
commit per completed gesture, autosave, overlap/bounds/concurrency checks and final
gesture integration. Keep the four-area editor, action sheets, stable preview,
cancellable opening, real multi-clip frames/ruler/scrub/playback/pinch selection.
Preserve native timestamps/IDs, raw results, hidden trim portions, media/clip
identity, shared engine, queue/frozen outputs, allowance/Pro, home and Mac behavior.
Read docs/ios/phases/TIMELINE_EDITOR.md and handoffs/TIMELINE_EDITOR.md.
No schema change, clip sequencing, transitions or music tracks. Source-only:
no builds/typechecks/tests/fixtures, CI, generation/models/native processing,
UI/device execution or deployment. Keep PR #48 open without auto-merge.
Earlier scope/PR instructions below are historical where superseded.

## Current iOS library organization pass

2026-10-27. The user approved implementation in existing PR #46,
`fix/ios-improvements` → develop. Replace the home media-type strip with All,
Favorites, custom folders and Trash, using Spokio iOS's outlined icon/label/count
pills. Remove the Projects header count; keep Sort and Options close to the label.
The floating + offers New Project and New Folder. Add folder create/rename/delete,
project membership/favorites, and Trash restore/confirmed permanent deletion.
Deleting a folder preserves its active and trashed projects. New projects created
within a folder join it. These organization features are Free.
Keep the earlier hero, subtitle and crown/settings toolbar. Paper is first,
default and the only Free iOS theme; other themes require Pro. Preserve captions,
revision/job/allowance contracts, frozen exports and Mac behavior. Library metadata
belongs to ProjectRepository independently of project document revisions.
Source review only; no builds, typechecks, tests, generation, CI or UI execution.
Keep the PR open without auto-merge. See handoffs/LIBRARY_ORGANIZATION under docs/ios.

## Current shared speech engine and active model

2026-10-26. In PR #44 the user explicitly supersedes per-job/original-model
binding: the whole iOS app has one shared engine and active model. Settings alone
exposes its name and choice. Switching requires confirmation, cancels all queued
and running transcription tasks plus model downloads, waits for speech teardown, and
then changes the active model. Exports, including preparation, queue admission and
running exports, are unaffected by model switching. New, restored and resumed
transcription jobs use that active model; old payload model fields are decode-only compatibility data. Retain saved
captions, edits, accepted raw intervals and completed exports. Resume unfinished
ranges with the active model without overwriting earlier accepted edits. No new
migration or original-model UI. Existing source-only execution restrictions and
open-PR/no-auto-merge requirements remain. This overrides prior pinned-model rules.

## Current free captioning allowance

2026-10-26. The user requests raising Free to 30 minutes/week in the current PR
#44, feat/ios-manual-captions → develop. This supersedes the earlier 5-minute
allowance. Preserve existing usage/reservations and weekly reset/accounting;
Pro remains unlimited. Keep allowance and comparison/upsell copy consistent.
User-facing completion checklists should cover requested implementation work,
without adding build or device validation items.

## Current manual-caption authorization

2026-10-26. The user requests implementing the discussed Add missing caption
feature in a new PR from latest develop f0eb80c targeting develop, branch
feat/ios-manual-captions. This authorizes the discussed UI and necessary source
integration: text/user timing, saving/reopen, undo/redo, styles/trim/MP4/SRT,
duplication and preservation during transcription retries with explicit overlap
review. See docs/ios/phases/MANUAL_CAPTIONS.md and handoffs/MANUAL_CAPTIONS.md.
Keep native recognition/IDs/timing, allowance, multi-clip projects, automatic
saving, independent outputs and Mac behavior. Schema 10 reads 1–9; wrappers stay.
No builds/typechecks/tests/fixtures, CI setup/triggers/runs, generation/models,
native inference/exports, UI/device execution or deployment. Source checks only;
leave the PR open without auto-merge. Earlier phase authorizations are historical.


## Current animated Styles sheet authorization

The user also authorizes polishing the supplied editor screenshot in this PR:
bounded content width/insets, compact playback/tool controls, hidden redundant
single-clip navigation and compact multi-clip cards with readable labels. Keep
single-clip rename reachable and do not change source names, timestamps, rendering
or persistence. Existing no-execution restrictions and sheet-layout rules remain.

2026-10-26. The user approved the animated-demo Styles sheet and requests one new
PR from latest develop (81b8207), branch feat/ios-animated-style-sheet, targeting
develop; leave open without auto-merge. Scope is V1.PRESETS/V1.STYLE presentation:
sample carousel, explicit Apply and project-default/clip scope. Latest user
corrections require a large-only sheet and no editor-preview movement: preserve
the scrolling workspace, active tool, scroll identity and expanded preview state
when opening it. Do not replace the editor with a compact preview. Keep multiple clips, the existing
catalog/renderer, recognition/timing, Pro gates, overrides, undo, saving and Mac
behavior. No builds/typechecks/tests/fixtures, CI/generation/models/native exports
or UI/device execution. See docs/ios/handoffs/ANIMATED_STYLES.md for source evidence
and pending acceptance. Prior completed phase instructions below are historical.

## Current issue #41 implementation authorization

The user authorizes the entire expanded Pass 1 in a new PR from latest develop,
branch `feat/ios-pass1-project-experience` targeting develop, left open with no
auto-merge. This supersedes issue #41's planning-only status and old PR #39 holds.
Read docs/ios/phases/PROJECT_EXPERIENCE.md and handoffs/PROJECT_EXPERIENCE.md.
Implement one-project creation (one/multiple files; no separate-project import),
project details and multi-clip editor, sparse per-setting clip overrides/reset,
project exports with queued/in-place generation and preview/save/share, and simple
automatic saving. The user approved the settled UI through this conversation.
The user also authorizes clip renaming in this same PR: visible details/editor menus,
persisted labels, original-name restoration and undo; settings resets preserve names.
Preserve native recognition/IDs/timing, allowance, originals, independent frozen
outputs and Mac behavior. Schema 9 reads 1–8; package/job/checkpoint wrappers remain.
No builds/typechecks/tests/fixtures, CI setup/triggers/runs, generation, model
downloads, native inference/exports, UI/device/accessibility execution or deployment.
Source/diff/whitespace/publication review only; user validates afterward. Finish
with a marked todo list distinguishing source integration from runtime acceptance.
Earlier scope/PR instructions below are historical where superseded by this task.


## Current project-saving simplification

The user rejects a separate draft/recovery workflow and asks for a friendly single
project experience in PR #39. This supersedes earlier editor-journal requirements:
remove the app's editor sidecar dependency, readiness checks, discard/reload flows
and sidecar-driven library/action gates. Save directly through the sole repository
with the existing serialized writer and atomic/revision checks; retain failed edits
in app-owned memory across navigation. Show one friendly save failure with Retry.
Rename remains accessible. Do not add legacy migration work or delete existing
files. Transcription checkpoints/partial publication, processing queues, frozen
exports, originals, undo/access and Mac behavior remain protected. No builds/tests,
CI/generation/models/native/UI/device execution or deployment; leave PR open.

## Current consolidation authorization

The user requests a consolidation pass across issue #38's five source passes in
existing PR #39 → develop. Fix supported integration defects and duplication;
consolidate current docs while preserving historical evidence. Read docs/ios/
CONSOLIDATION.md and current entry points. Do not expand feature scope, alter
working transcription/data/access contracts or run restricted execution. The
source-only checks and open/no-auto-merge rules below remain in force.

## Issue #38 — current production passes 1–5 authorization

The user explicitly authorized pass 5 in existing PR #39
(`feat/ios-project-packages` → develop), retaining passes 1–4. Implement versioned
shared style/catalog/resolved values, ten distinctive looks, native renderer weight/
shadow/background/layout/motion extensions and pass-4 browser/customization/reset/
access integration, compatibility and supported production source fixes. Read
phases/CAPTION_PRODUCTION, handoffs/CAPTION_PRODUCTION and PRODUCTION_READINESS
under docs/ios plus prior pass records. Preserve successful transcription/partial
publication, raw/native IDs/timing, corrections/undo/allowance, packages/jobs/frozen
outputs/journals and current Mac source/config/Transcript APIs. Canonical schema 8
reads 1–7; package/job/checkpoint/request wrappers remain stable. Opening legacy
looks does not resolve current catalog defaults. Keep the approved one-scroll
editor and iPhone-only support. Routine settled UI details are authorized after
the short plan. Leave PR open without auto-merge. Production acceptance remains
pending; do not manufacture device/footage/rendering/store evidence.

No builds, typechecks, tests, fixture execution, CI setup/triggers/runs, project
generation, model downloads, native inference/exports, deployment or UI/device/
accessibility execution. User tests afterward. Meaningful regression source may
be authored but must not be executed. Source integration is not production
verification. Earlier pass-only/PR holds below are historical for this scope.

## Issue #36 — current authorization

The user requests updating #36 and implementing the approved editor visualization in existing PR #37 (fix/ios-window-recovery → develop, baseline 525fae4), left open without auto-merge. The latest explicit implementation request supersedes the earlier complete-only publication/schema-v5 restriction: publish available captions incrementally, keep transcript/footage editable and exportable with inline missing ranges, and retry gaps while preserving edits. Schema v7 records coverage/mapping versions and reads v1–v6. Use bounded window recovery and versioned sidecars; only complete nonempty recognition charges. Scope includes the existing editor/transcription/export surfaces; preserve Mac/shared runtime, purchases, originals, native/manual anchors and legacy empty recovery. Read docs/ios/phases/TRANSCRIPTION_RECOVERY.md and handoffs/TRANSCRIPTION_RECOVERY.md. No builds/typechecks/tests, workflow dispatch, generation, weights, deployment or UI/device validation. Routine implementation choices for the approved UI and partial publication are authorized. The user subsequently reported an empty transcript after 1 of 4 windows on device. Correct the strict word-timing gate: preserve native segment-timed phrases when precise word timing is unavailable; never invent word boundaries. Retain mapping 1 for existing identities and record mapping 2 per new accepted core (schema v7). Do not claim the original video is fixed without runtime evidence.
- Do not fake completion. Source integration is not compilation or runtime evidence.
- Do not run builds/typechecks/tests, workflow dispatches, project generation, model downloads, deployment or device/UI validation. User tests afterward. The current user request explicitly authorizes source-only setup of the manual Build Release workflow; other CI setup remains outside scope.
- XcodeGen owns project.yml; do not modify generated .xcodeproj files.
- Preserve Mac identity, source, purchases, catalog, storage, resources and behavior.

## Scope and workflow

Read docs/ios/README.md, PLAN.md, FEATURES.md, WORKFLOW.md, HANDOFF.md and the requested phase brief. The compact 29-item v1 scope supersedes the historical 467-item catalog and P0–P13 roadmap. Old handoffs, images and Mac capabilities do not authorize features. No accounts/backend/cloud inference/sync, teams/social integration, credits, stock libraries, dubbing, share extension/App Group/inbox, camera, translation or advanced editor expansion.

One PR per requested phase from latest develop targeting develop; keep all passes in it. Leave open with auto-merge disabled until the user explicitly requests merge. Do not start another phase automatically. State scoped IDs and short UI plan; the current implementation request authorizes its settled UI and routine details. Ask only about actual new scope.

P0–P6 (#23–#29) and optional models plus P7 (#30) are squash merged. Latest phase baseline is eb89f0fb3cd0f67054e6d29de2375342718c1651. Historical PR review holds and P5 Pro deferral are superseded by the current request below.

## Pro phase — merged #31

The Pro implementation below is squash merged as 76981dee7533aab9b1194eee7376bf0ebfc60efb; its earlier PR review hold is historical.

### Approved Pro contract

Implement V1.PRO plus access rules on V1.LOCAL_STT/JOB/STYLE/PRESETS/MP4. Use feat/ios-pro-access-themes, one new PR targeting develop, leave open. Read docs/ios/phases/PRO.md and handoffs/PRO.md.

The user approved: free 30 minutes captioning/week versus unlimited Pro; basic free caption style versus all fonts/templates/animations; free 720p versus Pro 1080p; default free app theme versus all premium AppFoundation themes. Monthly $6.99 and lifetime $24.99 use com.hoangbkit.inkribe.pro.monthly and com.hoangbkit.inkribe.pro.lifetime. AppFoundation owns paywall, contextual upsell, restore, verified purchase state and theme picker/state. No watermark, trial, credit backend or new products.

Import/projects, caption text/timing/split/merge/undo, media tools and SRT remain free. Keep existing projects/captions/styles/export files usable after expiry; new premium choices require Pro. Failed/cancelled recognition is not charged; publication/retry is idempotent. Preserve accepted durable work across expiry and pre-policy jobs across upgrade.

## Existing local contracts

Schema v8 reads v1–v7; absent recognition coverage means a legacy complete result. Keep original clips/raw recognition/native/manual timing canonical. One retained-range map drives preview/MP4/SRT; trimming does not reduce recognition work. One renderer/media graph/audio mix serves preview and export. Keep bounded undo and serialized latest-draft persistence.

Optional bundle/download/cache and Tiny/Base/Small selection remain per docs/ios/MODELS.md. Default project.yml omits iOS weights; project-ios-bundled.yml requires Small and disables download/cache fallback through INKRIBE_IOS_BUNDLED_MODELS_ONLY. Release alone does not change packaging. No weights are to be downloaded by the agent.

## Current release-workflow request

The user explicitly requested the GitHub Build Release workflow based on hoangbkit/guidelines. Keep it in one new chore/manual-build-release PR from latest develop targeting develop, open until asked to merge. This authorizes workflow/helper/docs source edits only, overriding the earlier no-CI-setup rule for this release lane. No workflow dispatch, agent builds/tests, project generation, model downloads or deployment. Do not add Fast/Full CI or change application UI/runtime/model policy. Read docs/BUILD_RELEASE.md. Only workflow_dispatch; unsigned selected-platform archives plus generated Xcode project ZIP; mycli-build prerelease tags. Preserve app identities, Mac resources and source.


## Current iOS bundle identifier request

PR #32 (manual release workflow) is squash merged as 990ef4b. The user explicitly requests a new PR changing the Inkribe iOS target to com.hoangbkit.inkribe in both Debug and Release. Keep this on chore/ios-bundle-identifier from latest develop targeting develop, open until asked to merge. Update the archive identity validator accordingly. Mac remains com.hoangbkit.inkribe.debug in Debug and com.hoangbkit.inkribe in Release. Keep existing iOS preference/storage keys, product IDs and entitlements unchanged. No builds/tests, workflow dispatch, generation, model downloads or device validation. Historical P0 bundle IDs are superseded by this request.

## iOS source naming correction

The user requires the iOS app source folder to be Inkribe/, matching its target, alongside InkribeMac/. App files/types use plain names without IOS prefixes; InkribeApp is the entry point and ProjectCanvas is the domain canvas. Only the two adapters in Inkribe/Storage/LegacyJobCompatibility.swift retain old type names because JobQueue 1.0 persists those names. Existing storage paths, defaults keys, model IDs, schema fields and queue payloads remain stable. Keep these changes in PR #33, open until asked to merge. No builds/tests, CI runs, Xcode generation, weights or device checks.

The user requires iPhone-only support: TARGETED_DEVICE_FAMILY is 1 for both iOS configurations, inherited by the bundled-model spec. Do not re-enable iPad support.

Both app targets must use the same existing InkribeMac/AppIcon.icon resource, following Spokio. iOS selects AppIcon and references that file directly; do not duplicate or redesign the artwork.

