# Issue #36 — usable captions and resilient transcription

The user authorized implementation of the visualized caption editor and corrected the earlier complete-only publication policy. Continue in [PR #37](https://github.com/hoangbkit/Inkribe/pull/37), `fix/ios-window-recovery` → `develop`, based on 525fae4. Leave open without auto-merge.

## Scope

V1.LOCAL_STT/WORDS/JOB/RESULT/RECOVERY/PRO/PREVIEW/TEXT/TIMING/STYLE/MP4/SRT/HANDOFF within the existing caption studio. Preserve originals, native/manual anchors, existing features and purchases, Mac and shared runtime. This approval covers the editor layout and incremental publication, not a new feature phase.

## Device-report correction

Native segment text/timing must remain usable when a word timestamp is unavailable. Mapping 2 uses exact segment/token byte associations, retains usable word unions, and falls back to one phrase at the model's actual segment interval. Mapping 1 remains reproducible for existing accepted IDs; schema v7 protects new mapping metadata. Failed-range errors include reasons/counts and explicitly identify zero saved captions. The user's screenshot confirms an empty transcript after 1 of 4 windows, but does not identify those failures or prove this source fix works on that video.

## Current contract

- Available captions publish atomically as accepted windows finish. Show their editable transcript and render them on footage immediately. Missing windows must never hide valid captions or block editing/export.
- Keep compact footage, play/scrub/clocks/undo and a slim caption/gap lane above the readable transcript. Selecting a caption reveals footage just inside its interval. Edit its full text directly; advanced word/split/merge/timing controls remain available.
- Put missing ranges inline with individual Retry. Offer Retry missing ranges for all gaps. Captions/Style/Timing controls stay at the bottom; existing templates live with Style, and Media tools remain in actions.
- Keep 24-second cores, overlapping context, one smaller-core recovery for explicit failures, truthful incomplete status and durable checkpointing. No fabricated words or timestamp boundaries. Fatal source/model/storage/cancellation errors still stop execution, preserving prior publications.
- Retry retains the operation, original model/language, raw/window/word identities and user edits. Append only newly accepted units, even when the user is editing during inference.
- Schema v7 records optional coverage/mapping versions; v1–v6 documents remain readable without eager migration. The separate version-1 checkpoint still stores attempts/failures. Canonical coverage/raw data can reconstruct accepted inference after sidecar loss or duplication.
- Partial captions can export MP4/SRT with an informational gap notice. Only complete nonempty recognition uses allowance; incomplete/failed/cancelled jobs do not.
- Fully empty output never publishes or charges. Nonzero empty responses are re-inferred on an all-empty retry. Legacy empty-result recovery remains separate.
- Reset retry progress explicitly removes only the sidecar, preserving captions/edits. Runtime/policy incompatibility cannot be repaired by clearing canonical captions.

See [handoff](../handoffs/TRANSCRIPTION_RECOVERY.md) for persistence details and remaining user validation. Source/diff/whitespace review only; no builds/typechecks/tests, workflow triggers, project generation, weights, native inference or UI/device validation.
