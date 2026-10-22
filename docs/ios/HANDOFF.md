# Live v1 handoff — 2026-10-22

Current PLAN/FEATURES and P0–P7 briefs supersede the old catalog. 29 V1 items. P7 is hardening; P8–P13 retired.

Planning #22 and P0 #23 merged. P1 PR #24, feat/ios-p1-media-projects, targets develop and **stays open; no merge/auto-merge**. P1 source includes local Projects/thumbnails, Photos/Files import, offline playback, rename, duplicate/delete, storage/cache/Trash and recovery. Source-integrated, uncompiled and runtime-unverified.

## User-authorized correctness fixes

- V1.RENAME: one writer drains the newest title draft, using committed revisions returned from the repository. Save responses update document metadata without assigning the draft or reloading the view. Debounce/submit/dismiss calls coalesce; cancellation of a debounce cannot drop an already-started writer's latest draft. Relink refresh preserves dirty/newer drafts and rejects older document revisions.
- Existing URL import: replaced unrestricted completed-file download with ephemeral uncached streaming. Reject declared lengths over the existing 16 GiB cap; count actual bytes including unknown/misreported-length streams before buffering/writing. Use 64 KiB writes; cancel/invalidate the session and close/delete partial temporary output on errors/cancel. Preserve normal repository adoption and cleanup.
- These two reported findings are corrected in source, not executed/compiled. No new feature/UI layout, persistence schema, target, entitlement, Mac or shared-package change.

URL/combined/batch/advanced canvas source remains outside v1 requirements. No incoming share extension/App Group/inbox. P5 owns native outbound sharing. P2 has no transcript-search, cloud-STT or diarization obligation. P2–P7 not started.

No builds/tests, CI, project generation, model downloads or device validation. User tests afterward. Do not claim runtime release readiness.

## Continue

Current request authorized the two fixes in PR #24; it did not authorize merge or another phase. Read handoffs/P1.md and the actual diff before further work. User scenarios include rapid rename during a pending save, submit/dismiss before debounce, relink during typing, and URL oversized/unknown-length/cancel/error cleanup.

If the user requests merge, keep it a squash merge into latest develop after normal source review/conflict handling. If P2 is then requested, use one new PR from latest develop and the narrowed phase brief. State V1 IDs and short plan; preserve Mac and avoid excluded services.
