# Add clips flow

2026-11-05. Base: latest develop d74676d4e6a5a3042a91c075122f1d7866c7ebb6.
Branch: feat/ios-add-clips-flow; target: develop. Source-only delivery.

## Behavior

- Clips pushes Add clips in its existing navigation stack. Cancel returns to
  Clips; navigation and sheet dismissal are blocked during the atomic mutation.
- Photos and Files select videos only, matching New Project. Direct URL and
  audio-only selection are removed from this screen. Music remains separate.
- Add clips obtains Photos files directly through PHPickerViewController and
  NSItemProvider.loadFileRepresentation, bypassing its earlier
  PhotosPickerItem.loadTransferable path. It retains the selected providers in
  the editor model, preserves ordered selection, and copies each temporary file
  synchronously before the provider callback returns. Only the owned, nonempty
  file URL enters metadata review and staged append. New Project's existing
  picker/transfer implementation is unchanged.
- 2026-11-05 instability follow-up (still in #68): after device reports of
  Photos selection hanging at a single global spinner, loading is now parallel
  within a bounded window of three concurrent providers, every Photos selection
  registers a row immediately (Files/Photos share one ordered list), and each
  row reports its own loading, copying, checking or failed stage. Failed rows
  keep one Retry/Remove pair inline. The picker runs full screen because a
  nested page-sheet presentation behaved unreliably. Representation mode is
  .automatic so the system can substitute a complete compatible file instead of
  stalling on the absolute original. This entry's single 250 ms type re-check
  and received-callback-only loadItem fallback are superseded by the
  2026-11-06 acquisition follow-up below.
- 2026-11-06 acquisition follow-up (branch
  fix/import-videos-from-photos-app, stacked on #68): provider acquisition is
  bounded per attempt instead of trusting one callback. Registered movie
  identifiers are polled for up to 1.6 s; concrete movie types are preferred
  (at most three), and each type is requested through the file representation
  first, then raw item acquisition. The first attempt has a 30 s stall watchdog
  and later attempts 15 s, all inside the unchanged 120 s overall deadline. A
  stalled attempt cancels its Progress handle when the representation provides
  one, rejects late callbacks by an attempt generation and advances to the next
  representation; an owned copy made before a finish is still removed. Rows
  report Retrying Photos access between attempts. Exhausting every attempt
  reports the last native error or a no-response failure instead of leaving the
  row loading. The synchronous owned copy remains inside the provider callback.
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
| Photos picker and transfer | Native PHPicker, videos filter, ordered selection and .automatic representation, presented full screen. Selected NSItemProviders survive dismissal; direct file representation copy finishes inside the callback, with bounded type polling, concrete-type file-representation attempts, a raw item fallback and a per-attempt stall watchdog. No PHAsset lookup, library-read permission or whole-video Data loading. |
| Preparation ownership | Editor-owned observable model, separate photo/review/add tasks with a three-wide bounded concurrent load window, no Add-screen onDisappear cleanup. Picker request and selection IDs reject late delegate results. |
| Completion and cancellation | Photo completion uses generation-guarded defer cleanup; explicit cancellation resets busy state synchronously and registers unfinished items for retry. Old completion cannot clear a newer task's state. |
| Selection lifetime | Cancel/success/navigation pop and Clips sheet onDismiss end the selection. Captured IDs reject stale picker delegate results, Files results and append navigation callbacks. Late successful photo copies are removed. |
| Transfer completion | Provider error, missing/empty/non-file data, copy failure, cancellation and 120-second expiry complete once per request. A silent attempt expires after 30 s (first) or 15 s (later), cancels its progress handle when there is one, and moves to the next representation; late success from any stale attempt is removed. Failures retain their provider for Retry. Row-level stages report loading, retrying, copying, checking and the native failure text. |
| Files and metadata | Video-only filter plus inspected-kind checks at review and copied-original preparation. Already validated selections are not rechecked on every removal/addition. |
| Thumbnail completion | MainActor-owned generator/continuation, balanced security scope, completion/cancel/deadline resume once; late callbacks ignored. No thumbnail dependency in Add readiness. |
| Save/cancel/failure | Existing staging and revision-checked atomic append retained. Preparation remains cancellable; save failure stays on the selection screen. |
| Selection/preview | Callback runs after saved document adoption. seekToClip stores the new time while preview preparation is pending; preparePreview seeks that time when attaching. |
| Captions handoff | Parent editor handles the intent in the Clips sheet onDismiss, guarded against leaving/missing project/another presentation. No automatic transcription. |
| Scope | Existing New Project thumbnail default/picker/Photos bridge, Music, storage/schema, exports and Mac source unchanged. Existing compiled files contain new helpers; no project membership change. |

Whitespace, call-site and remote-base/blob consistency checks are source evidence
only. No builds, typechecks, tests, CI, project generation or native/UI/device
execution were run. Compilation and device acceptance remain unverified.

Device acceptance still needed: Photos and Files selection/cancel/retry, slow or
missing thumbnail, append/save failure, repeated additions, list reveal/playhead,
Open Captions presentation and missing-range transcription preserving edits.
Include picker coverage/return while transferring, immediate Cancel preparation
followed by Retry, and closing/reopening Add clips while a provider completes late.
For the instability follow-up also cover several Photos videos at once with
per-row loading/copying rows, mixed local and iCloud-offloaded originals,
per-row failures appearing while other rows still load, and Retry of one row
inside a settled batch. For the 2026-11-06 acquisition follow-up, verify a
silent provider moves through Retrying Photos access to either a later
representation or a bounded failure, and that a stale callback cannot replace a
newer attempt or leave an owned copy behind.

The source defect was cancellation on Add-screen disappearance invalidating the
operation before the old task reached its busy-state reset. This path existed on
develop and remained in the first #68 commit. The reported device event ordering
has not been reproduced; the ownership follow-up removed that lifetime dependency.
The subsequent import-path change bypasses Transferable acquisition itself; it is
an alternate native import implementation, not proof of a diagnosed Apple defect.

## Native API contracts reviewed

- [Apple file representation documentation](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation(fortypeidentifier:completionhandler:)):
  copy before callback return; the provider's temporary URL is not durable.
- [Apple engineer guidance on video loading](https://developer.apple.com/forums/thread/652496):
  use loadFileRepresentation and current representation to avoid unnecessary
  compatibility transcoding where possible. After device stalls were reported
  with .current, Add clips keeps loadFileRepresentation but selects
  .automatic so the system may substitute a compatible representation instead
  of blocking on the absolute original.
- [Ordered selection](https://developer.apple.com/documentation/photosui/phpickerconfiguration-swift.struct/selection-swift.enum/ordered):
  selected results arrive in user selection order when confirmed.

Device acceptance additionally needs local screen recordings, camera MOV/HEVC,
iCloud-only video, mixed Files/Photos, cancellation during download/copy, Retry,
multiple selections and opening the saved clips after relaunch.
