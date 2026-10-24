# Issue #38 — production pass 3 handoff

Date: 2026-10-24 (Vietnam). Baseline PR #39 head f598376; develop e39e223.
Branch feat/ios-project-packages → develop. Passes 1–3 are source-integrated in
the same PR. Leave open without auto-merge. Passes 4–5 remain pending.

## Result and entry points

| Responsibility | Source |
|---|---|
| One root stack/sheet route, hero/search/activity/library | Inkribe/App/ProjectsView.swift |
| Responsive theme-token hero/cards/activity | StudioComponents.swift |
| Compact async-thumbnail project rows, separate actions | ProjectCard.swift (ProjectRow) |
| App-owned editor session/writer/presentation leases | Inkribe/Editor/EditorSessions.swift |
| Acquire session outside view rendering | ProjectEditorDestination.swift |
| Native Back/expanded-preview control/save status | ProjectDetailView.swift |
| Journal/save/recovery and retained history/state | EditorSession.swift |
| Shared versioned draft envelope and bounded atomic I/O | InkribeCore/Projects/ProjectRecoveryDraft.swift, ProjectPackageStore.swift |
| Semantic recovery/conflict/lifecycle adapter | ProjectRepository.swift |
| Partial/cancelled import IDs and Photos generations | ProjectsModel.swift, MediaImporter.swift, ImportView.swift |
| Continuous native navigation background | Pro/ProViews.swift ThemedSurface |
| Coherent surrounding routes/rows/errors | SettingsView, StorageView, SpeechModelsView, ExportView, ProcessingJobDetail |
| Meaningful shared regression source, not executed | ProjectRecoveryDraftTests.swift |

## Design and navigation

Reviewed source references:
- [AppShot ProjectLibraryView](https://github.com/hoangbkit/AppShot/blob/daac39743e49d2ac39fc3cb498d41b5787705add/Features/Projects/ProjectLibraryView.swift).
- [AppReel ProjectLibraryView](https://github.com/hoangbkit/AppReel/blob/b0f4e9b92422b333e088a09d0193f71b797a79a9/Features/Projects/ProjectLibraryView.swift).
- AppFoundation 1.6.4 ThemeSwiftUI source: AppThemeBackground ignores safe area and
  ThemeSwiftUI applies the theme's preferred color scheme. Native bar/title and
  control contrast keep that scheme; no global UIKit appearance/gesture delegate.

Home now uses a rounded 28-point creation hero with semantic rounded headline,
short caption benefit, dominant capsule New Project CTA, subdued theme accent and
optional decorative caption badge. It has no fixed content height. One quieter
empty-library explanation replaces the second large creation pitch. Recovery/queue
activity, Projects header, scope chips and compact project rows follow in one scroll.
Rows show actual title/type/duration/date/caption or draft state; menu is a sibling
of the NavigationLink, not an overlapping button. Thumbnails load bounded cache data
asynchronously. At accessibility text sizes, decorative thumbnails/badges give room
to text; rows grow/wrap. Search hides hero and filter strip, preserving results/sort,
clear-filter affordance, search context after returning, and toolbar creation.

Hero/toolbar share one guarded New Project route. Root has one sheet enum for
import/paywall/celebration/models/storage and one NavigationStack for projects,
settings and queue. Import-result routing occurs only after sheet dismissal.
Crown/Settings retain the same AF paywall vs active-Pro celebration; a successful
Free→Pro grant celebrates after dismissal. Theme upsell/restore/devtools remain AF.
Settings/Storage each use one sheet enum. The surrounding native forms share AF
surface/border/text tokens. No in-app palette or caption artwork was redesigned.

The editor no longer hides native Back or installs custom Back that awaits saves.
There is no interactive-pop override or gesture-state observer. Expanded-preview
collapse is a separate trailing control. Native title/Export remain. The flat theme
background override on the bar is replaced with hidden toolbar background over the
continuous AF safe-area background, matching the references' approach. The bar,
buttons, native Back and native system gestures remain. Device scroll-edge contrast,
completed/cancelled edge swipe and system callback timing are explicitly unverified.

Full editor preview/transport/tools/transcript layout remains the existing layout
until pass 4. This pass adds no sticky/floating home/activity UI, and does not claim
the old fixed editor content is already redesigned.

## Session and draft lifecycle

All routes acquire the same app-owned EditorSession by project ID, in a destination
task rather than view initialization. Presentation owner IDs prevent one nested
route from tearing down media still owned by another. Disappearance pauses playback;
final detachment stops native playback/observers and starts a strongly retained save.
Cancelled native swipes have no gesture-progress side effects or explicit draft reset.
Selection, playhead, undo and draft stay on the session object if the view returns.
Native focus/scroll/playback behavior still needs real completed/cancelled-swipe tests.

Dirty sessions/errors never age out in process. The last idle clean session remains
available; opening a different project prunes older clean idle session state. Native
player resources stop on final detach. This is no persistent undo/version-history
feature: app relaunch restores editable document/base, not undo/focus/scroll position.

Each save capture writes editor-draft.json atomically before the canonical document:

| Field | Meaning |
|---|---|
| version = 1 | Draft wrapper, independent of canonical schema 7 |
| ownerID | Stable session recovery identity |
| sequence | Monotonic edit sequence; equal sequence only permits identical bytes |
| base | Exact valid saved document used for conflict checks |
| proposed | Unsaved editable state, including an unfinished title |

The shared store checks wrapper/version/project/revision/source identity and valid
base, bounded regular-file reads, path/symlink protection, same owner and sequence.
Compact encoding bounds the envelope at 512 MiB + 4 KiB for two documents; the normal
256 MiB canonical cap remains. Large-project memory/latency is unmeasured. Sidecar
bytes count as durable project data and cannot be cleared by cache cleanup. No extra
actor/index, native UI dependency or canonical/queue/checkpoint schema migration.

The app validates recovered proposal semantics before constructing snapshots; an
unfinished title is allowed for recovery, then canonical Save still requires a valid
title. Native/raw-anchor edit checks remain at commit. Corrupt/future/unsafe data is
preserved with an error; the saved canonical project stays readable. Only explicit
confirmed discard removes an unreadable regular sidecar, never follows a symlink.

Recovery first compares the desired editing state against current canonical content,
including accepted appended captions, normalized revision/date/schema metadata. An
already satisfied journal is removed conditionally, acknowledging a crash after
commit/before cleanup. Otherwise restore its exact base/proposal and show Review/
Retry Save. Canonical writes still reject conflicting title/style/media/manual edits;
only existing narrow append-only speech publication rebases. Same-revision external
content changes now fail too, instead of overwriting a different saved base.

Save success merges returned recognition/revision metadata into the latest draft,
then removes only the journal owned through that saved sequence. A newer writer's
journal cannot be removed. Cleanup failure stays visible. If typing advances while
a captured save fails, the writer also attempts to protect that newer proposal in
the journal, retaining it in process even when disk cannot be written. No forced
rebase or automatic discard resolves a conflict. Home exposes pending edits, with
Retry/confirmed discard in the editor. Rename/duplicate/Trash require resolution.
A project with unsafe draft metadata remains listed with a combined issue rather
than losing saved-caption access; the sidecar is not silently ignored/overwritten.

The existing 600ms typing debounce remains. Back and backgrounding request immediate
flush without awaiting it in the native navigation action. In-process ownership
protects drafts while that asynchronous operation runs; a successful atomic journal
survives relaunch. **Termination before any durable write, or an unwritable device,
cannot guarantee recovery of unpersisted keystrokes.** Errors remain visible and the
session stays retained. No background entitlement/time guarantee was added. Unapplied
local tool fields still require their existing Apply action; this does not persist
unsubmitted tool UI or provide cross-launch undo restoration. Older builds ignore
the sidecar; downgrade may hide uncommitted work and is not a recovery method.

## Import, queue and surrounding flow

Photos/Files/direct HTTPS URL remain source choices inside New Project, preserving
combined ordered clips vs separate projects. No import automatically starts speech.
Custom dimensions validate before either local or direct URL work. Native picker
cancel is not presented as an error; Photos provider failures leave Files available.

Photos preparation reserves a generation synchronously before its async task.
Cancellation/closing invalidates that generation and cancels its task; late transfer
copies are removed and cannot append into a closed/new importer or reset a newer
preparation flag. Only root importer dismissal clears selections, so a native child
picker's appearance/disappearance cannot destroy selected inputs. Photos preparation
has explicit Cancel; dismissal waits for processing or cancellation.

Separate import cancellation returns committed documents with a stopped flag rather
than throwing away completed IDs. Successful source IDs leave the retry selection;
failures/unstarted inputs remain. Committed IDs accumulate across retries until this
creation sheet ends, so earlier successes remain reachable. Combined publication is
atomic and clears committed sources even if cancellation arrived just after publish.
Partial/cancelled results stay for review with Open/View imported projects; complete
success navigates after dismissal. Done also hands off available committed IDs.
Native file-provider/native Photos cancellation and kill boundaries are unrun.

Library/storage refresh errors are explicit inline states rather than background
alerts competing with sheets/editors. Storage errors do not spin forever or pretend
an empty library. Queue summary reflects actual active/pending/output/failure/storage
state, scrolls with home, and opens pass-2 Queue. Existing queued payloads/IDs,
resource limits, captured exports/Photos/Files/Share leases and allowance policy remain.
The same-project route from Queue consumes the shared session. Models explain that
queued work/retries retain captured models, and bundled-only copy does not promise
downloads. Dummy privacy URL and live product/release inputs remain owner tasks.

## Source evidence and required user validation

Shared draft regression sources cover unfinished-title restart recovery without
canonical/media mutation, owner/sequence cleanup, equal-sequence idempotency,
corrupt/future preservation/explicit discard, missing-media draft protection and
symlink rejection. They are authored **but not executed**. No claims that they pass.

| User-run scenario still required | Expected result |
|---|---|
| User build/shared tests | Shared APIs, new views and Swift concurrency compile; regressions execute |
| Empty/populated/search/filter/busy/error home | One creation hero; correct project counts; no sticky content or redundant empty CTA |
| Small iPhone SE2/larger iPhone, large text/VoiceOver | Hero/rows/actions grow; controls/read order/contrast usable |
| Supported light/dark themes; scroll top/up/down; push/pop/sheet return | Continuous appearance, readable native title/buttons, no abrupt flat black strip |
| Native Back/edge swipe completed and cancelled while typing/playing | Draft/selection/history retained; cancelled gestures leave native focus/scroll/playback coherent |
| Save pending/failure/conflict; Back→Home→reopen | Latest in-process draft available; home recovery; retry/discard explicit; no trap or clobber |
| Terminate before/after journal/commit/cleanup | Last durable state or recoverable proposal; equivalent commit not reapplied; pre-write loss limit honest |
| New edits while save/cleanup fails; missing original; low disk | Newest retained proposal, explicit error, no raw/source changes |
| Future/corrupt/symlink sidecar; same-revision external change | No blind overwrite/reset; canonical captions readable; safe error/discard policy |
| Same project through home→queue→project | One session/writer, no conflicting autosaves or premature resource teardown |
| Rename/duplicate/Trash with pending edits; cache clear | Draft resolution required; durable journal not treated as cache |
| Photos prepare/cancel/close/reopen/late provider completion | No stale source append, orphan ingress or stuck new preparation |
| Separate import good+bad files; cancellation between publications; retry | Committed IDs retained; retry only remaining; correct cumulative handoff |
| Combined/local/URL/custom canvas; provider cancel/permissions | Original import semantics, clear errors, correct editor/library destination |
| Queue progress/partial speech/retry while editing; export A/B and delivery | Existing successful captions/edits/timing/allowance and independent frozen outputs preserved |
| Crown/Settings, Free→Pro, restore/expiry/theme upsell/Debug tools | Same AF flow and entitlements; no competing sheet/alert or new pricing |

Only source/call-site/diff/whitespace and exact publication review. No builds,
typechecks/tests/fixtures, CI setup/triggers/runs, generation, downloads, native
inference/exports, UI/device/accessibility execution or deployment. Source-complete
is not production-ready; native gesture/provider/performance evidence is pending.
