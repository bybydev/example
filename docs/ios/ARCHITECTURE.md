# Inkribe iOS — current architecture

2026-10-24. Source contracts for issue #38/PR #39 and consolidation. Existing Mac
source/configuration/Transcript APIs remain intact; shared extraction does not
establish Mac feature/rendering parity.

| Owner | Responsibility |
|---|---|
| InkribeCore | Package identity/paths/atomic transactions, rational media time/revisions, processing contracts/gate, resolved style/catalog/reset/access/layout constraints and deterministic motion |
| ProjectRepository actor | Sole native project/media/recognition/usage/export authority; typed validation, adoption/lifecycle/storage, revision checks, source pins and publication |
| ProjectsModel + EditorSessions | Library/import routing and one app-owned editor session/writer per project; retain unsaved project edits in memory across navigation |
| EditorSession | Working document/snapshot, bounded value history, selection/playback, native preview composition and serialized project-save writer |
| ProcessingCoordinator + runtime/lifecycle | Existing transcription/export queues, action authorization, user/system pause, one shared heavy native operation and cancellation/teardown |
| Native adapters | Core Text font matching/shaping/layout/drawing, AVFoundation composition/inference/export, Photos/Files/Share and AppFoundation commerce/themes |

## Persistence and concurrency

Internal UUID.inkribe packages use wrapper 1 and document schema 8 (reads 1–7).
ApplicationSupport/InkribeIOSProjects and existing originals/checkpoints/usage/
exports/cache ownership remain. Relative paths, identity, versions, bounds and
regular-file checks apply on read and publication. Atomic same-directory legacy
adoption preserves valid bytes; collisions/unsafe/future data stay visible.

Editor edits save directly to document.json through the sole repository actor,
with atomic replacement and a previous valid document. One strong writer, normal
600ms debounce and immediate Back/background flush serialize complete project
values. Revision/native-anchor checks remain; only append-only speech publication
may rebase edits. Returned metadata never replaces newer typing.

The app no longer reads, creates or gates editing/actions on editor-draft.json.
The generic shared sidecar API/specifications remain unused by the app; existing
files are untouched. Failed edits and undo/context stay in the app-owned session
across navigation, with one friendly failure and Retry. They are not guaranteed
across process termination before a successful save. No UI forces a discard/reload
choice or blocks leaving Project details. Canonical metadata remains capped at
256MiB. Transcription checkpoints and frozen job requests retain their durability.

EditorHistory contains value-only expected-state commands/coalescing with the
existing 50-command/8MiB budget (one oversized command retained). Native playback,
focus, scroll and entitlement adapters remain separate; snapshot/time lookup is
independent of selection and does not dirty the project.

## Recognition, media and jobs

Original clips/raw recognition/native timestamps and IDs remain canonical. Bounded
window inference publishes accepted captions incrementally; gap retry preserves
edits and mapping-version identity. Missing word timing uses a real segment-timed
phrase, never fabricated word boundaries. Only complete nonempty recognition
charges, through the existing durable allowance/reservation path.

One retained-range map serves preview/MP4/SRT. Trim does not reduce recognition
work. Preview/export share media composition, orientation/crop, original-audio mix,
caption geometry/typography/effects and edited timing. Schema/model/storage changes
never implicitly re-infer or regroup captions.

JobQueue 1.0.0 retains speech-jobs.json/export-jobs.json and current/legacy adapter
names/IDs/payload defaults. Each queue admits one job, and one shared gate limits
heavy native work total. Native teardown is awaited before records become removable.
Wrapper-1 processing-control.json separates user pause from foreground state; no
new background entitlement. Speech retries always retain model/revision/allowance
checks. Frozen export wrapper 1 captures document/profile/media; workers never read
current catalog defaults or live editor drafts. Per-output leases pin exact URLs;
record removal, orphan recovery and explicit file deletion remain distinct.

## Style and presentation

InkribeCore owns resolved style values and immutable preset (id, version) definitions.
Saved values are authoritative. Format 1 freezes old defaults/layout/motion. Format 2
requires its resolved extension fields; corruption cannot silently default them.
Unsupported future style formats are non-corruption errors, preserving future data
instead of falling back to an older document. Future incompatible wire changes must
also advance the canonical schema. Unknown catalog references retain known values.

Core Text handles installed closest weights, script/emoji fallback, clusters and
bidi. Layout fitting is bounded at six measurements, eight lines and 16,384 UTF-16
units per cue; failure is explicit. Word/phrase-aware motion uses actual original
edited intervals, including trim into a unit. One capped asynchronous media frame
feeds at most ten retained preset snapshots/layouts; no per-card player/decoder.

A modal style/export/queue route detaches the covered editor player layer before
another route can present that session's player. Overlay error reporting invalidates
queued callbacks on any newer draw or dismantle and reports initial success too.
Native focus/scroll/layer transitions remain unexecuted acceptance scenarios.

See [CONSOLIDATION](CONSOLIDATION.md), phase handoffs and
[PRODUCTION_READINESS](PRODUCTION_READINESS.md) for evidence limits. Earlier source
records remain in [the archive](archive/before-consolidation/ARCHITECTURE.md).
