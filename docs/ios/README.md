# Inkribe iOS — start here

2026-10-24. Issue #38's five source passes and consolidation are in
[PR #39](https://github.com/hoangbkit/Inkribe/pull/39),
`feat/ios-project-packages` → `develop`. Leave open without auto-merge.

The iPhone app uses UUID project packages, automatic project saving, durable
multi-job processing, a native project home and one scrolling editor with ten
versioned caption looks. Canonical schema 8 reads 1–7; package/queue/request
contracts and working transcription are retained. Mac source/config/APIs stay intact.

**Source reviewed; production acceptance pending.** No builds/typechecks/tests/
fixtures, CI setup/triggers/runs, generation, model downloads, native inference/
exports, UI/device/accessibility or deployment is authorized by this work.

| Read | Purpose |
|---|---|
| [PLAN](PLAN.md), [FEATURES](FEATURES.md) | Current scope and the 29 acceptance items |
| [WORKFLOW](WORKFLOW.md), root AGENTS.md | Authorization, execution and PR rules |
| [ARCHITECTURE](ARCHITECTURE.md), [DESIGN](DESIGN.md) | Current ownership, data and interaction contracts |
| [HANDOFF](HANDOFF.md), [CONSOLIDATION](CONSOLIDATION.md) | Integrated source status, fixes and next user checks |
| [PRODUCTION_READINESS](PRODUCTION_READINESS.md) | Release gates and owner inputs; actual privacy URL, live commerce and execution evidence remain pending |
| [MODELS](MODELS.md) | Existing optional-download versus bundled-only model lanes |
| [Historical records](archive/before-consolidation/README.md) | Superseded status and delivery history; not current scope/authorization |

The phase/handoff index is in HANDOFF. Preserve the user's confirmed successful
caption quality, partial publication, genuine word/phrase intervals, edits, undo,
allowance and independent exports. Never infer acceptance from source integration.
