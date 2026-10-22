# Inkribe iOS architecture contracts

Status: planned contracts, not implemented APIs. Concrete Swift type names and file locations must be chosen against latest develop during the owning phase. Read [BASELINE.md](BASELINE.md) before assuming a capability is absent.

## App and package boundaries

| Boundary | Owns | Must not own |
|---|---|---|
| InkribeMac macOS target | Existing Mac lifecycle, UI, commerce, data roots | New iOS editor state, iOS permissions |
| Inkribe iOS target | Navigation, AppFoundation integration, project/editor composition, Photos/Files/camera, app-level policy | Native inference internals or duplicate queue state machine |
| Existing portable packages | Appropriate audio/media, recognition, model assets, text/subtitle serialization | AppKit, MacAppFoundation, app navigation or paywall decisions |
| Caption project/domain code | Versioned project graph, timed words/cues, clips/tracks/styles, validation and edit commands | Views, StoreKit or provider SDK objects |
| Render subsystem | Time-based layout/composition shared by preview/export | Independent preview-only typography/easing or mutable editor UI state |
| JobQueue integration | Durable job lifecycle, retry/cancel/progress | The authoritative editable project document |
| Provider adapters | Opt-in STT/AI/translation/media/publishing capabilities and errors | Silent uploads, hidden costs or direct mutation of documents |

Keep iOS-only project/editor/render code app-local unless a real second consumer justifies a shared package. Existing shared packages can gain additive portable contracts when appropriate; do not use a package split as a prerequisite for each feature.

P0 must isolate platform settings in project.yml. Audit all target references, scheme references, Mac entitlements, test hosts, source memberships and store configurations. Preserve Mac bundle IDs, data locations, app/product name and existing purchases. Select distinct iOS identifiers; do not grant capabilities by changing the Mac target.

## Domain and identity

The Mac Transcript stays a transcript. A new iOS video project is a separate versioned document. Proposed conceptual entities:

| Entity | Required contract |
|---|---|
| Project | Stable ID, schema version, monotonic content revision, title/dates, render canvas/profile, references to owned assets and edit graph |
| Source asset | Stable ID, app-owned original relative path, metadata/orientation/timebase, integrity/provenance, missing-source state |
| Clip instance | Stable ID, source asset reference, source in/out, placement/track, time transform, effects/keyframes; duplicated clips receive new instance IDs |
| Track | Stable ID, semantic kind/language, ordered instances/cues and compositing/mixing properties |
| Raw recognition | Immutable source-relative segment/token/word output and recognition/model/language provenance |
| Editable word | Stable ID, editable text, source interval/alignment provenance, speaker/language and timing validity |
| Caption cue | Stable ID, word references/order, cue interval/line layout rules, style overrides; deleting a cue does not delete source media |
| Style/animation | Serializable versioned properties, asset/font references, keyframes/easing; global defaults plus explicit local overrides |
| Derived result | Input project revision, affected source/selection IDs, operation/provider metadata, proposed changes and accepted/applied status |
| Export snapshot | Frozen project revision, resolved assets/fonts, output profile, caption mode and destination; changes to the editor do not alter an in-flight job |

Do not persist AVPlayer, runtime handles, task closures, open security scopes or provider SDK objects. No IDs derived from current text, array index or a mutable slug. Keep human-readable titles independent of identity.

Content edits advance revision; selection, scroll and playback do not dirty persisted content. An asynchronous job applies only to the expected project/revision or presents a review/rebase choice. Retranscription or realignment is explicit and may produce a new proposal/version, never silently overwrite manual changes.

## Timing and transformations

Use rational media time internally, with explicit timescales and half-open intervals `[start, end)`. Avoid accumulating frame/timestamp rounding through repeated floating-point conversions. Imported subtitle precision can differ from video frame boundaries; define the conversion at export/serialization boundaries.

Maintain separate source-media time and composition/project time. A clip maps a source interval to a timeline interval; P6 adds trim/reorder/speed/reverse policies. Captions retain their source associations. Editing one duplicated clip must not mutate another instance's timeline placements.

Define mapping behavior for gaps, repeated source ranges, speed ramps, transitions, freeze frames and reverse. Define when text/timing is clipped, duplicated, suppressed or requires realignment. Zero/negative-duration words, NaN/nonfinite times and out-of-range intervals must not enter a valid persisted document silently.

Word timings need genuine boundaries. Whisper tokens can be subword pieces and punctuation; merge by Unicode-aware text/token mapping and preserve provenance. Do not assign equal durations to words and present them as measured alignment. Realigned timings must be distinguished from original recognition timings and manual adjustments.

Frame stepping and export sample deterministic project timestamps for a selected rational frame rate. Respect VFR input presentation timestamps, audio offsets and source orientation; do not assume every input frame lasts 1/30 second.

## Document storage and media lifecycle

P1 chooses an iOS-specific durable project root independent of Mac transcripts. Preserve originals and edit non-destructively. Separate:
- authoritative project document and original/required assets;
- durable job metadata;
- reproducible derived caches such as waveforms/thumbnails/render intermediates;
- incomplete temporary import/export files.

Stage external copies in temporary files, validate metadata, atomically adopt assets and commit a project record. Enqueue only after durable prerequisites exist. Cancellation/failure must not leave an apparently complete project pointing to missing media. Ownership/reference counting or an equivalent explicit policy must prevent deleting media still referenced by duplicates/jobs.

One authoritative repository/service instance owns a project store in an app process. Do not create independent cached actors per screen. Serialize mutations and commit disk state before publishing success. Autosave and undo have separate responsibilities: durable state survives relaunch; in-memory undo history is not automatically promised to survive relaunch.

Schema changes require version decoding, migration fixtures/plans and a recovery policy before writing new formats. Preserve the old valid document on migration/write failure. Reject unsupported future versions without destructive reset. Rebuild caches only from authoritative data; cache cleanup must not erase sources, manual text or timing.

Store relative, validated paths inside the owned root; reject traversal. Relink missing external sources explicitly. Project export/import must include or clearly identify required asset/font dependencies and remap duplicate identities safely.

## Speech and runtime ownership

Reuse current Whisper/DiarizationRuntime protocols, native context lifetime controls, speaker alignment and identity stabilization. Inspect portability and available binary slices without resolving/downloading models as part of planning.

P2 introduces bounded decoding and windowed recognition, with source offsets, contextual overlap and duplicate-boundary reconciliation. Model context and temporary arrays must also be bounded; reading chunks then concatenating them is not streaming. Diarization must follow a compatible bounded strategy rather than retaining the whole video PCM while recognition streams.

Model/running-job lifetime has one owner. Expensive decode/inference is off MainActor; native mutable state remains serialized. Start conservatively with one resource-heavy transcription execution. Coordinate live preview/export/inference resources without unlimited parallel work. Keep user-initiated cancellation alive through decode, inference, alignment and persistence.

Mac's current executor consumes full buffers and persists segments. Do not change its behavior accidentally while adding the iOS pathway. Add portable APIs/adapters or a separately scoped executor as needed. Save successful results durably before a job reports completion. Retry targets the same project operation, never creates duplicate projects or charges.

Bundling vs downloading, selected iOS models and local AI choices remain decisions in DECISIONS.md. No Mac Qwen or diarization asset gets included in the iOS app solely because its package exists.

## Editor transaction boundary

Use one editor/session state owner per open project. Own document revision, command application, undo/redo, selection and player synchronization explicitly. Views observe derived state and call commands; opening a sheet/tool panel must not rebuild document identity, reparse media or reset playback.

Text/list selection, active cue, timeline playhead and video seek use one mapping. Avoid feedback loops in which playback observation triggers seek repeatedly. Seek completion/progress from an old project must not affect a new project. Release observers/tasks when switching project/session.

Split/merge/insert/delete/timing changes are atomic edit commands with defined inverse operations. Multiple selected cues are handled consistently. Keyboard-driven changes preserve a compact preview and reachable controls. Style changes can target project defaults, a selection or an individual word without overwriting unrelated overrides.

P3 approves the actual navigation and layout before editor UI implementation. Do not treat a generated 12-screen image as a complete interaction specification.

## Preview/render/export parity

P0 compares viable AVFoundation/Core Animation/Core Image/Metal approaches and records the selected strategy with evidence limits. Do not preselect a technology only because it is convenient for SwiftUI preview.

Use a single deterministic scene evaluator:
- inputs: frozen project content, rational timestamp, output dimensions, resolved font/asset set and style version;
- output: glyph/line layout, positions/transforms/colors/effects and scene/layer instructions;
- no dependency on wall clock, UI animation completion, scroll state or incidental screen scale.

A preview adapter and export adapter consume the same time/layout/easing rules. Seeking backward, pausing, exporting in chunks and replaying the same time yield the same state. Derive spring/loop effects from media time; seed any procedural variation reproducibly.

Define canvas coordinates, safe areas, typography scaling, baseline positioning, grapheme/emoji handling, font fallback, color/alpha and compositing order. P4 style/version changes invalidate only the appropriate derived caches. A required unavailable font/asset gets an actionable warning or explicit accepted fallback, not a silently changed export.

P5 renders from an immutable snapshot, writes to a temporary output and adopts the completed file only after success. Track progress from actual stages; cancellation removes partial outputs and retry is idempotent. “Background export” means respecting iOS execution/lifecycle limits, not a promise of unlimited execution after the app exits.

Caption mode, container/codec, resolution, rational frame rate, audio profile, optional subtitle files and font limitations form an explicit export profile. Transparent video/soft subtitles depend on supported containers/codecs; document unsupported combinations without faking support. P6 effects use the same scene/time contracts.

## AI, services and billing

AI outputs are proposals against a named revision and selection. Validate their schema, reference IDs, operation bounds and confidence; show preview before application. Treat transcript text as data, not instructions overriding tool permissions. Undo accepted changes.

Local usage works without an account. Remote processing requires explicit authorization for specific media/text transfer and provider/cost disclosure. Record request IDs and idempotency keys for retries, cancellation and usage accounting. Store credentials appropriately; keep private media/text out of diagnostics. License/consent evidence is required per stock/generated/voice-preserving feature.

P5 centralizes individual-user entitlement decisions in the iOS app layer using AppFoundation/verified StoreKit state. P12 adds credits/team billing without using local completion counters as authoritative billable usage. Expired access must not make existing project content unreadable.

## Decisions and review

[DECISIONS.md](DECISIONS.md) separates fixed invariants from implementation choices. Update decisions in the owning phase PR. Review architecture-critical contracts at P0/P1, P2, P3–P5 and P6. No extra package, backend or abstraction is required merely to satisfy a diagram. Follow WORKFLOW.md for execution permissions.
