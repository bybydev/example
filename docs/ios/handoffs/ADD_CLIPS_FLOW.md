# Add clips flow

2026-11-05. Base: latest develop d74676d4e6a5a3042a91c075122f1d7866c7ebb6.
Branch: feat/ios-add-clips-flow; target: develop. Source-only delivery.

## Behavior

- Clips pushes Add clips in its existing navigation stack. Cancel returns to
  Clips; navigation and sheet dismissal are blocked during the atomic mutation.
- Photos and Files select videos only, matching New Project. Direct URL and
  audio-only selection are removed from this screen. Music remains separate.
- The editor owns AddClipsModel across the Clips screen, pushed Add screen and
  native pickers. Import preparation never stops on view disappearance. Explicit
  Cancel/pop or Clips dismissal closes its selection; Cancel preparation clears
  busy state immediately and retains prepared files and retryable failures.
- Ordered, numbered selections show durations and explicit Add clip/Add N clips.
  Files are revalidated as video after copying before append publication.
- Metadata validation gates Add; optional thumbnail decoding does not. Row tasks
  request bounded-size artwork with a three-second deadline, native cancellation
  and a single completion. Missing artwork falls back to the normal video icon.
- Success pops back to Clips, reveals/selects the first added clip and seeks its
  beginning. A saved-count section offers Open Captions for added audio-bearing
  clips with missing recognition. Captions opens only after Clips dismisses.
- Missing coverage without a matching job uses Generate missing captions. Existing
  job retries retain their action and all accepted captions/edits.

## Source review

| Path | Review result |
|---|---|
| Photos picker and transfer | Ordered selection, current encoding, per-item cancellation/deadline and temporary-file cleanup retained. Shared transfer implementation unchanged. |
| Preparation ownership | Editor-owned observable model, separate photo/review/add tasks, no Add-screen onDisappear cleanup. Native PhotosPicker uses stable source rows like New Project. |
| Completion and cancellation | Photo completion uses generation-guarded defer cleanup; explicit cancellation resets busy state synchronously and registers unfinished items for retry. Old completion cannot clear a newer task's state. |
| Selection lifetime | Cancel/success/navigation pop and Clips sheet onDismiss end the selection. Captured selection IDs reject stale Photos bindings, Files results and append navigation callbacks. Late successful photo copies are removed. |
| Files and metadata | Video-only filter plus inspected-kind checks at review and copied-original preparation. Already validated selections are not rechecked on every removal/addition. |
| Thumbnail completion | MainActor-owned generator/continuation, balanced security scope, completion/cancel/deadline resume once; late callbacks ignored. No thumbnail dependency in Add readiness. |
| Save/cancel/failure | Existing staging and revision-checked atomic append retained. Preparation remains cancellable; save failure stays on the selection screen. |
| Selection/preview | Callback runs after saved document adoption. seekToClip stores the new time while preview preparation is pending; preparePreview seeks that time when attaching. |
| Captions handoff | Parent editor handles the intent in the Clips sheet onDismiss, guarded against leaving/missing project/another presentation. No automatic transcription. |
| Scope | Existing New Project thumbnail default, Photos bridge, Music, storage/schema, exports and Mac source unchanged. Existing compiled files contain new helpers; no project membership change. |

Whitespace, call-site and remote-base/blob consistency checks are source evidence
only. No builds, typechecks, tests, CI, project generation or native/UI/device
execution were run. Compilation and device acceptance remain unverified.

Device acceptance still needed: Photos and Files selection/cancel/retry, slow or
missing thumbnail, append/save failure, repeated additions, list reveal/playhead,
Open Captions presentation and missing-range transcription preserving edits.
Include picker coverage/return while transferring, immediate Cancel preparation
followed by Retry, and closing/reopening Add clips while a provider completes late.

The source defect was cancellation on Add-screen disappearance invalidating the
operation before the old task reached its busy-state reset. This path existed on
develop and remained in the first #68 commit. The reported device event ordering
has not been reproduced; this follow-up removes the lifetime dependency itself.
